import Foundation
@testable import RFB
import Synchronization
import zlib

struct Bytes {
    var data: [UInt8] = []

    mutating func u8(_ v: Int) { data.append(UInt8(truncatingIfNeeded: v)) }
    mutating func u16(_ v: Int) { u8(v >> 8); u8(v) }
    mutating func u32(_ v: Int) { u16(v >> 16); u16(v) }
    mutating func s32(_ v: Int32) { u32(Int(UInt32(bitPattern: v))) }
    mutating func append(_ bytes: [UInt8]) { data += bytes }
    mutating func string(_ s: String) { data += Array(s.utf8) }
    mutating func pixel(_ p: UInt32) { u8(Int(p & 0xFF)); u8(Int(p >> 8 & 0xFF)); u8(Int(p >> 16 & 0xFF)); u8(0) }
    mutating func cpixel(_ p: UInt32) { u8(Int(p & 0xFF)); u8(Int(p >> 8 & 0xFF)); u8(Int(p >> 16 & 0xFF)) }
    mutating func tpixel(_ p: UInt32) { u8(Int(p >> 16 & 0xFF)); u8(Int(p >> 8 & 0xFF)); u8(Int(p & 0xFF)) }

    mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ encoding: RFBEncoding) {
        u16(x); u16(y); u16(w); u16(h); s32(encoding.rawValue)
    }

    mutating func compact(_ length: Int) {
        if length < 0x80 {
            u8(length)
        } else if length < 0x4000 {
            u8(length & 0x7F | 0x80); u8(length >> 7)
        } else {
            u8(length & 0x7F | 0x80); u8(length >> 7 & 0x7F | 0x80); u8(length >> 14)
        }
    }

    static func serverInit(width: Int, height: Int, name: String) -> [UInt8] {
        var b = Bytes()
        b.u16(width); b.u16(height)
        b.append([32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0])
        b.u32(name.utf8.count); b.string(name)
        return b.data
    }
}

// Deflater is one persistent zlib stream flushed per message, as servers do.
final class Deflater {
    private var stream = z_stream()

    init() {
        deflateInit_(&stream, Z_DEFAULT_COMPRESSION, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    }

    deinit {
        deflateEnd(&stream)
    }

    func compress(_ input: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(input.count))) + 64)
        var input = input
        let produced = input.withUnsafeMutableBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                stream.next_in = src.baseAddress
                stream.avail_in = uInt(src.count)
                stream.next_out = dst.baseAddress
                stream.avail_out = uInt(dst.count)
                deflate(&stream, Z_SYNC_FLUSH)
                return dst.count - Int(stream.avail_out)
            }
        }
        return Array(out.prefix(produced))
    }
}

// Server scripts one RFB server over an RFBPipe.
final class Server: @unchecked Sendable {
    let pipe = RFBPipe()
    private var pending: [UInt8] = []
    private var iterator: AsyncStream<Data>.Iterator

    init() {
        iterator = pipe.outbound.makeAsyncIterator()
    }

    func send(_ bytes: [UInt8]) async {
        await pipe.deliver(Data(bytes))
    }

    // read returns the next count bytes the client sent.
    func read(_ count: Int) async -> [UInt8] {
        while pending.count < count {
            guard let chunk = await iterator.next() else { break }
            pending += chunk
        }
        let n = min(count, pending.count)
        defer { pending.removeFirst(n) }
        return Array(pending.prefix(n))
    }

    // handshake runs RFB 3.8 with no security and returns what the client
    // sent after ServerInit: SetPixelFormat, SetEncodings, update request.
    func handshake(width: Int, height: Int, name: String = "test") async -> (encodings: [Int32], request: [UInt8]) {
        await send(Array("RFB 003.008\n".utf8))
        _ = await read(12)
        await send([1, 1])
        _ = await read(1)
        await send([0, 0, 0, 0])
        _ = await read(1)
        await send(Bytes.serverInit(width: width, height: height, name: name))
        _ = await read(20)
        let header = await read(4)
        let count = Int(header[2]) << 8 | Int(header[3])
        let list = await read(count * 4)
        let encodings = stride(from: 0, to: list.count, by: 4).map {
            Int32(bitPattern: UInt32(list[$0]) << 24 | UInt32(list[$0 + 1]) << 16 | UInt32(list[$0 + 2]) << 8 | UInt32(list[$0 + 3]))
        }
        return (encodings, await read(10))
    }
}

// Events collects client events and waits for them.
final class Events: @unchecked Sendable {
    let stream: AsyncStream<RFBEvent>
    let continuation: AsyncStream<RFBEvent>.Continuation
    private var iterator: AsyncStream<RFBEvent>.Iterator

    init() {
        (stream, continuation) = AsyncStream<RFBEvent>.makeStream()
        iterator = stream.makeAsyncIterator()
    }

    var handler: @Sendable (RFBEvent) -> Void {
        { [continuation] in continuation.yield($0) }
    }

    func next<T>(_ match: (RFBEvent) -> T?) async -> T? {
        while let event = await iterator.next() {
            if let value = match(event) { return value }
        }
        return nil
    }

    func update() async -> (RFBFramebuffer, RFBRect)? {
        await next { if case .updated(let fb, let dirty) = $0 { (fb, dirty) } else { nil } }
    }
}

func start(_ server: Server, _ configuration: RFBClient.Configuration = RFBClient.Configuration()) -> (RFBClient, Events, Task<Void, any Error>) {
    let client = RFBClient(transport: server.pipe, configuration: configuration)
    let events = Events()
    let task = Task { try await client.run(events.handler) }
    return (client, events, task)
}

func pattern(_ width: Int, _ height: Int, seed: UInt32 = 1) -> [UInt32] {
    (0..<(width * height)).map { i in
        let x = UInt32(i % width), y = UInt32(i / width)
        return ((x &* 7 &+ seed) & 0xFF) << 16 | ((y &* 5 &+ seed &* 3) & 0xFF) << 8 | ((x ^ y) & 0xFF)
    }
}

func pixels(_ fb: RFBFramebuffer, _ rect: RFBRect) -> [UInt32] {
    var out: [UInt32] = []
    for y in rect.y..<(rect.y + rect.height) {
        let row = fb.row(y, x: rect.x)
        for x in 0..<rect.width { out.append(row[x] & 0x00FF_FFFF) }
    }
    return out
}

struct Recording {
    var configuration = RFBClient.Configuration()
    var stream: Data

    init(fixture name: String) throws {
        let url = Bundle.module.url(forResource: name, withExtension: "rfbrec", subdirectory: "Fixtures")!
        let file = try Data(contentsOf: url)
        let length = file[4..<8].reduce(0) { $0 << 8 | Int($1) }
        let header = try JSONSerialization.jsonObject(with: file[8..<(8 + length)]) as? [String: String] ?? [:]
        let names: [String: RFBEncoding] = ["raw": .raw, "hextile": .hextile, "zrle": .zrle, "tight": .tight, "copyrect": .copyRect]
        configuration.encodings = (header["encodings"] ?? "").split(separator: ",").compactMap { names[String($0)] }
        configuration.jpegQuality = header["jpeg"].flatMap(Int.init)
        configuration.continuousUpdates = header["continuous"] != "0"
        configuration.requestsOnConsume = false
        stream = file.subdata(in: (8 + length)..<file.count)
    }

    // replay runs the client over the recording and returns the final
    // framebuffer contents.
    func replay() async throws -> (RFBFramebuffer?, RFBStatistics) {
        let transport = Replay(stream)
        var configuration = configuration
        configuration.collectsStatistics = true
        let client = RFBClient(transport: transport, configuration: configuration)
        let last = Mutex<RFBFramebuffer?>(nil)
        do {
            try await client.run { event in
                if case .resized(let fb) = event { last.withLock { $0 = fb } }
            }
        } catch RFBError.connectionClosed {
        }
        return (last.withLock { $0 }, client.statistics)
    }
}

final class Replay: RFBTransport {
    let data: Data
    let offset = Mutex(0)

    init(_ data: Data) {
        self.data = data
    }

    func receive(expecting count: Int) async throws -> Data? {
        offset.withLock { o -> Data? in
            guard o < data.count else { return nil }
            let end = min(o + 4096, data.count)
            defer { o = end }
            return data.subdata(in: o..<end)
        }
    }

    func send(_ data: Data) {}
    func close() {}
}
