import Foundation
import Synchronization

public enum RFBEvent: Sendable {
    case connected(RFBServerInfo)
    // resized carries a new framebuffer; the previous one is no longer written.
    case resized(RFBFramebuffer)
    // updated follows each FramebufferUpdate; dirty bounds its rectangles.
    case updated(RFBFramebuffer, dirty: RFBRect)
    case cursor(RFBCursor?)
    case pointer(x: Int, y: Int)
    case clipboard(String)
    case desktopName(String)
    case bell
}

public struct RFBCursor: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var hotspotX: Int
    public var hotspotY: Int
    // pixels is premultiplied BGRA, width * height * 4 bytes.
    public var pixels: [UInt8]
}

public struct RFBStatistics: Sendable, Equatable {
    public struct Encoding: Sendable, Equatable {
        public var rects = 0
        public var pixels = 0
        public var bytes = 0
        public var nanoseconds: UInt64 = 0
    }

    public var updates = 0
    public var bytes = 0
    public var fences = 0
    public var continuousUpdates = false
    public var extendedClipboard = false
    public var encodings: [RFBEncoding: Encoding] = [:]
}

public final class RFBClient: Sendable {
    public struct Configuration: Sendable {
        public var password: String?
        public var shared = true
        public var encodings: [RFBEncoding] = [.tight, .zrle, .hextile, .copyRect, .raw]
        // jpegQuality 0-9 lets Tight send JPEG; nil keeps Tight lossless.
        public var jpegQuality: Int? = 8
        public var compressionLevel: Int?
        public var continuousUpdates = true
        // requestsOnConsume stops asking for updates while maxUndrawn
        // delivered updates wait for framebufferConsumed, so a view that
        // stops drawing stops the server; otherwise requests follow updates.
        public var requestsOnConsume = true
        public var maxUndrawn = 2
        // requestInterval, without continuous updates, keeps incremental
        // requests going at this pace while updates arrive, so the server can
        // answer more than one per round trip; it stops a second after the
        // last update, and nil turns it off.
        public var requestInterval: Duration? = .milliseconds(33)
        public var collectsStatistics = false
        // eagerHandshake writes the whole client side of the handshake at
        // once, saving the version round trip; only for servers known to
        // speak RFB 3.8 and offer security None.
        public var eagerHandshake = false

        public init() {}

        var advertised: [RFBEncoding] {
            var list = encodings
            if let jpegQuality { list.append(.jpegQuality(jpegQuality)) }
            if let compressionLevel { list.append(.compressionLevel(compressionLevel)) }
            list += [.extendedDesktopSize, .desktopSize, .lastRect, .cursor, .pointerPosition, .desktopName, .qemuExtendedKeyEvent, .fence, .extendedClipboard]
            if continuousUpdates { list.append(.continuousUpdates) }
            return list
        }
    }

    struct Shared {
        var ready = false
        var width = 0
        var height = 0
        var undrawn = 0
        var owed = false
        var pacing = false
        var lastUpdate: ContinuousClock.Instant?
        var nextIncremental = true
        var continuous = false
        var qemuKeys = false
        var clipboardCaps: UInt32?
        var localClipboard: String?
        var statistics = RFBStatistics()
    }

    public let configuration: Configuration
    let transport: any RFBTransport
    let shared = Mutex(Shared())
    private let pacerQueue = DispatchQueue(label: "rfb.pacer", qos: .userInteractive)

    public init(transport: any RFBTransport, configuration: Configuration = Configuration()) {
        self.transport = transport
        self.configuration = configuration
    }

    // run performs the handshake and processes server messages until the
    // connection ends or the task is cancelled; events arrive on its task.
    public func run(_ events: @escaping @Sendable (RFBEvent) -> Void) async throws {
        try await withTaskCancellationHandler {
            defer {
                shared.withLock { $0.ready = false }
                transport.close()
            }
            let session = try Session(client: self, events: events)
            try await withTaskExecutorPreference(transport.executor) {
                try await session.run()
            }
        } onCancel: {
            transport.close()
        }
    }

    public func close() {
        transport.close()
    }

    public var statistics: RFBStatistics {
        shared.withLock { $0.statistics }
    }

    // framebufferConsumed tells the client every delivered update is on
    // screen, so it may ask for more.
    public func framebufferConsumed() {
        let request = shared.withLock { s -> Message? in
            s.undrawn = 0
            guard s.owed else { return nil }
            return s.request(maxUndrawn: configuration.maxUndrawn)
        }
        if let request { transport.send(request.data) }
    }

    // answered records an update and asks for the next one.
    func answered(drawn: Bool) {
        let now = ContinuousClock.now
        let (request, pace) = shared.withLock { s -> (Message?, Bool) in
            s.lastUpdate = now
            if drawn { s.undrawn += 1 }
            let pace = configuration.requestInterval != nil && !s.pacing && !s.continuous
            if pace { s.pacing = true }
            return (s.request(maxUndrawn: configuration.maxUndrawn), pace)
        }
        if let request { transport.send(request.data) }
        if pace, let interval = configuration.requestInterval { startPacer(interval) }
    }

    private func startPacer(_ interval: Duration) {
        let nanoseconds = Int(interval.components.seconds) * 1_000_000_000 + Int(interval.components.attoseconds / 1_000_000_000)
        let timer = DispatchSource.makeTimerSource(queue: pacerQueue)
        timer.schedule(deadline: .now() + .nanoseconds(nanoseconds), repeating: .nanoseconds(nanoseconds), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            guard let self else { return timer.cancel() }
            let request = shared.withLock { s -> Message?? in
                guard s.ready, !s.continuous, let last = s.lastUpdate, ContinuousClock.now - last < .seconds(1) else {
                    s.pacing = false
                    return .none
                }
                return s.undrawn < configuration.maxUndrawn ? .some(s.request(maxUndrawn: configuration.maxUndrawn)) : .some(nil)
            }
            switch request {
            case .none: timer.cancel()
            case .some(let message?): transport.send(message.data)
            case .some(nil): break
            }
        }
        timer.resume()
    }

    // refresh asks for the whole framebuffer again.
    public func refresh() {
        let request = shared.withLock { s -> Message? in
            guard s.ready else { return nil }
            return .updateRequest(incremental: false, RFBRect(x: 0, y: 0, width: s.width, height: s.height))
        }
        if let request { transport.send(request.data) }
    }

    public func pointer(x: Int, y: Int, buttons: RFBButtons) {
        let message = shared.withLock { s -> Message? in
            guard s.ready else { return nil }
            return .pointer(x: min(x, s.width - 1), y: min(y, s.height - 1), buttons: buttons)
        }
        if let message { transport.send(message.data) }
    }

    // key sends a keysym; with a scancode it uses QEMU's extended key event
    // when the server offers it.
    public func key(_ keysym: UInt32, down: Bool, scancode: UInt32? = nil) {
        let message = shared.withLock { s -> Message? in
            guard s.ready else { return nil }
            if s.qemuKeys, let scancode { return .qemuKey(keysym, scancode: scancode, down: down) }
            return .key(keysym, down: down)
        }
        if let message { transport.send(message.data) }
    }

    // type presses and releases a key for each character of text.
    public func type(_ text: String) {
        for scalar in text.unicodeScalars {
            guard let keysym = RFBKeyMap.keysym(for: scalar) else { continue }
            key(keysym, down: true)
            key(keysym, down: false)
        }
    }

    public func setClipboard(_ text: String) {
        let message = shared.withLock { s -> Message? in
            s.localClipboard = text
            guard s.ready else { return nil }
            // libvncserver 0.9.14 offers no notify and drops the client on an
            // unsolicited provide, so only notify-capable servers get UTF-8.
            guard let caps = s.clipboardCaps, caps & Clipboard.notify != 0 else { return .cutText(latin1: text) }
            return .extendedCutText(flags: Clipboard.notify | Clipboard.text, payload: [])
        }
        if let message { transport.send(message.data) }
    }

    func send(_ message: Message) {
        transport.send(message.data)
    }
}

extension RFBClient.Shared {
    // request asks for an update unless maxUndrawn updates wait for drawing,
    // in which case the request is owed until framebufferConsumed.
    mutating func request(maxUndrawn: Int) -> Message? {
        guard ready, !continuous else { return nil }
        guard undrawn < maxUndrawn else {
            owed = true
            return nil
        }
        owed = false
        defer { nextIncremental = true }
        return .updateRequest(incremental: nextIncremental, RFBRect(x: 0, y: 0, width: width, height: height))
    }
}
