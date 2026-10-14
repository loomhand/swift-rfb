import Foundation

// Session owns the reading side of one connection: it runs on the task
// that called RFBClient.run and is never shared.
final class Session {
    private let client: RFBClient
    private let events: @Sendable (RFBEvent) -> Void
    private let reader: Reader
    private let decoders: [Int32: any RectDecoder]
    private let collects: Bool
    private var framebuffer: RFBFramebuffer?
    private var clipboard = ExtendedClipboard()

    init(client: RFBClient, events: @escaping @Sendable (RFBEvent) -> Void) throws {
        self.client = client
        self.events = events
        reader = Reader(transport: client.transport)
        collects = client.configuration.collectsStatistics
        decoders = [
            RFBEncoding.raw.rawValue: RawDecoder(),
            RFBEncoding.copyRect.rawValue: CopyRectDecoder(),
            RFBEncoding.hextile.rawValue: HextileDecoder(),
            RFBEncoding.zrle.rawValue: try ZRLEDecoder(),
            RFBEncoding.tight.rawValue: try TightDecoder(),
        ]
    }

    func run() async throws {
        let configuration = client.configuration
        // the first request predates ServerInit, so it asks for the largest
        // rectangle and the server clips it to the framebuffer.
        let opening =
            Message.setPixelFormat().bytes + Message.setEncodings(configuration.advertised).bytes
            + Message.updateRequest(incremental: false, RFBRect(x: 0, y: 0, width: 0xFFFF, height: 0xFFFF)).bytes
        let info = try await Handshake.negotiate(
            reader, transport: client.transport, password: configuration.password, shared: configuration.shared, eager: configuration.eagerHandshake, opening: opening)
        let framebuffer = try RFBFramebuffer(width: info.width, height: info.height)
        self.framebuffer = framebuffer
        client.shared.withLock { s in
            s.ready = true
            s.width = info.width
            s.height = info.height
        }
        events(.connected(info))
        events(.resized(framebuffer))
        while true {
            let type = try await reader.readU8()
            switch type {
            case 0: try await update()
            case 1: try await colourMap()
            case 2: events(.bell)
            case 3: try await cutText()
            case 150: continuousUpdatesEnded()
            case 248: try await fence()
            default: throw RFBError.protocolViolation("server message \(type)")
            }
        }
    }

    private func update() async throws {
        try await reader.need(3)
        _ = reader.u8()
        let count = Int(reader.u16())
        var dirty = RFBRect(x: 0, y: 0, width: 0, height: 0)
        let startBytes = reader.consumed
        for _ in 0..<count {
            try await reader.need(12)
            let rect = RFBRect(x: Int(reader.u16()), y: Int(reader.u16()), width: Int(reader.u16()), height: Int(reader.u16()))
            let encoding = RFBEncoding(rawValue: Int32(bitPattern: reader.u32()))
            if encoding == .lastRect { break }
            if let decoder = decoders[encoding.rawValue] {
                guard let framebuffer, rect.x + rect.width <= framebuffer.width, rect.y + rect.height <= framebuffer.height else {
                    throw RFBError.protocolViolation("\(encoding) rect \(rect) outside framebuffer")
                }
                if collects {
                    let before = reader.consumed
                    let clock = ContinuousClock.now
                    try await decoder.decode(rect, from: reader, into: framebuffer)
                    let elapsed = ContinuousClock.now - clock
                    let bytes = reader.consumed - before
                    client.shared.withLock { s in
                        s.statistics.encodings[encoding, default: .init()].record(rect: rect, bytes: bytes, elapsed: elapsed)
                    }
                } else {
                    try await decoder.decode(rect, from: reader, into: framebuffer)
                }
                dirty = dirty.union(rect)
            } else {
                if encoding == .desktopSize || encoding == .extendedDesktopSize { dirty = RFBRect(x: 0, y: 0, width: 0, height: 0) }
                try await pseudo(encoding, rect)
                if collects {
                    client.shared.withLock { $0.statistics.encodings[encoding, default: .init()].rects += 1 }
                }
            }
        }
        let wire = reader.consumed - startBytes + 4
        client.shared.withLock { s in
            s.statistics.updates += 1
            s.statistics.bytes += wire
        }
        client.answered(drawn: client.configuration.requestsOnConsume && !dirty.isEmpty)
        if let framebuffer, !dirty.isEmpty {
            events(.updated(framebuffer, dirty: dirty))
        }
    }

    private func pseudo(_ encoding: RFBEncoding, _ rect: RFBRect) async throws {
        switch encoding {
        case .desktopSize:
            try resize(width: rect.width, height: rect.height)
        case .extendedDesktopSize:
            try await reader.need(4)
            let screens = Int(reader.u8())
            try await reader.skip(3 + screens * 16)
            if rect.y == 0 { try resize(width: rect.width, height: rect.height) }
        case .cursor:
            try await cursor(rect)
        case .pointerPosition:
            events(.pointer(x: rect.x, y: rect.y))
        case .desktopName:
            let length = Int(try await reader.readU32())
            events(.desktopName(try await reader.readString(length)))
        case .qemuExtendedKeyEvent:
            client.shared.withLock { $0.qemuKeys = true }
        default:
            throw RFBError.protocolViolation("unexpected encoding \(encoding) for \(rect)")
        }
    }

    private func resize(width: Int, height: Int) throws {
        if let framebuffer, framebuffer.width == width, framebuffer.height == height { return }
        let next = try RFBFramebuffer(width: width, height: height)
        framebuffer = next
        let enable = client.shared.withLock { s -> Bool in
            s.width = width
            s.height = height
            s.nextIncremental = false
            return s.continuous
        }
        if enable { client.send(.enableContinuousUpdates(true, next.bounds)) }
        events(.resized(next))
    }

    private func cursor(_ rect: RFBRect) async throws {
        guard rect.width <= 1024, rect.height <= 1024 else { throw RFBError.protocolViolation("cursor \(rect)") }
        let maskRow = (rect.width + 7) / 8
        let count = rect.width * rect.height
        try await reader.need(count * 4 + maskRow * rect.height)
        guard count > 0 else {
            events(.cursor(nil))
            return
        }
        let colours = reader.bytes(count * 4)
        let mask = reader.bytes(maskRow * rect.height)
        var pixels = [UInt8](repeating: 0, count: count * 4)
        for y in 0..<rect.height {
            for x in 0..<rect.width where mask[y * maskRow + (x >> 3)] & (0x80 >> UInt8(x & 7)) != 0 {
                let i = (y * rect.width + x) * 4
                pixels[i] = colours[i]
                pixels[i + 1] = colours[i + 1]
                pixels[i + 2] = colours[i + 2]
                pixels[i + 3] = 255
            }
        }
        events(.cursor(RFBCursor(width: rect.width, height: rect.height, hotspotX: rect.x, hotspotY: rect.y, pixels: pixels)))
    }

    private func colourMap() async throws {
        try await reader.need(5)
        _ = reader.bytes(3)
        try await reader.skip(Int(reader.u16()) * 6)
    }

    private func cutText() async throws {
        try await reader.need(7)
        _ = reader.bytes(3)
        let length = Int32(bitPattern: reader.u32())
        if length >= 0 {
            let data = try await reader.readData(Int(length))
            events(.clipboard(String(data: data, encoding: .isoLatin1) ?? ""))
            return
        }
        let size = -Int(length)
        guard size >= 4 else { throw RFBError.protocolViolation("extended clipboard length \(size)") }
        let flags = try await reader.readU32()
        let payload = try await reader.readData(size - 4)
        let local = client.shared.withLock { $0.localClipboard }
        let outcome = try clipboard.receive(flags: flags, payload: payload, local: local)
        if let caps = outcome.serverCaps {
            client.shared.withLock { s in
                s.clipboardCaps = caps
                s.statistics.extendedClipboard = true
            }
        }
        outcome.replies.forEach(client.send)
        if let text = outcome.text { events(.clipboard(text)) }
    }

    private func continuousUpdatesEnded() {
        guard client.configuration.continuousUpdates, let framebuffer else { return }
        let enable = client.shared.withLock { s -> Bool in
            guard !s.continuous else { return false }
            s.continuous = true
            s.statistics.continuousUpdates = true
            return true
        }
        if enable { client.send(.enableContinuousUpdates(true, framebuffer.bounds)) }
    }

    private func fence() async throws {
        try await reader.need(8)
        _ = reader.bytes(3)
        let flags = reader.u32()
        let length = Int(reader.u8())
        guard length <= 64 else { throw RFBError.protocolViolation("fence payload \(length)") }
        let payload = Array(try await reader.readData(length))
        client.shared.withLock { $0.statistics.fences += 1 }
        guard flags & Fence.request != 0 else { return }
        client.send(.fence(flags: flags & (Fence.blockBefore | Fence.blockAfter | Fence.syncNext), payload: payload))
    }
}

extension RFBStatistics.Encoding {
    mutating func record(rect: RFBRect, bytes: Int, elapsed: Duration) {
        rects += 1
        pixels += rect.width * rect.height
        self.bytes += bytes + 12
        nanoseconds += UInt64(elapsed.components.seconds) * 1_000_000_000 + UInt64(elapsed.components.attoseconds / 1_000_000_000)
    }
}
