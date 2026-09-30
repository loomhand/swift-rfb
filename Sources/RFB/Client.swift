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
        // requestsOnConsume holds each incremental update request until
        // framebufferConsumed; otherwise requests follow each update.
        public var requestsOnConsume = true
        public var collectsStatistics = false

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
        var owesRequest = false
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
            try await session.run()
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

    // framebufferConsumed tells the client the last update is on screen, so
    // it may ask for the next one.
    public func framebufferConsumed() {
        let request = shared.withLock { s -> Message? in
            guard s.ready, s.owesRequest, !s.continuous else { return nil }
            s.owesRequest = false
            defer { s.nextIncremental = true }
            return .updateRequest(incremental: s.nextIncremental, RFBRect(x: 0, y: 0, width: s.width, height: s.height))
        }
        if let request { transport.send(request.data) }
    }

    // refresh asks for the whole framebuffer again.
    public func refresh() {
        let request = shared.withLock { s -> Message? in
            guard s.ready else { return nil }
            s.owesRequest = false
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
            guard let caps = s.clipboardCaps else { return .cutText(latin1: text) }
            if caps & Clipboard.notify != 0 { return .extendedCutText(flags: Clipboard.notify | Clipboard.text, payload: []) }
            return ExtendedClipboard.provide(text)
        }
        if let message { transport.send(message.data) }
    }

    func send(_ message: Message) {
        transport.send(message.data)
    }
}
