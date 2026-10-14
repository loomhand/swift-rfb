import Foundation
import RFB
import Synchronization

// rfb-bench live      HOST:PORT [--seconds N] [options] [--record FILE]
// rfb-bench replay    FILE [--iterations N]
// rfb-bench input     HOST:PORT --move X,Y [--click] [--type TEXT] [--keys 0x00,0x24 (macOS key codes)]
// rfb-bench clipboard HOST:PORT [--set TEXT] [--seconds N]
// options: --encodings tight,zrle,hextile,raw  --jpeg 0-9|off  --no-continuous  --eager  --interval MS|0  --password PW

struct Options {
    var configuration = RFBClient.Configuration()
    var seconds = 10.0
    var iterations = 5
    var record: String?
    var move: (x: Int, y: Int)?
    var click = false
    var text: String?
    var keyCodes: [UInt16]?
    var positional: [String] = []

    init(_ arguments: ArraySlice<String>) {
        configuration.requestsOnConsume = false
        configuration.collectsStatistics = true
        var args = arguments.makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--seconds": seconds = Double(args.next() ?? "") ?? seconds
            case "--iterations": iterations = Int(args.next() ?? "") ?? iterations
            case "--record": record = args.next()
            case "--click": click = true
            case "--keys": keyCodes = (args.next() ?? "").split(separator: ",").compactMap { UInt16($0.dropFirst(2), radix: 16) }
            case "--type", "--set": text = args.next()
            case "--move":
                let xy = (args.next() ?? "").split(separator: ",").compactMap { Int($0) }
                if xy.count == 2 { move = (xy[0], xy[1]) }
            case "--password": configuration.password = args.next()
            case "--no-continuous": configuration.continuousUpdates = false
            case "--eager": configuration.eagerHandshake = true
            case "--interval":
                let ms = Int(args.next() ?? "") ?? 0
                configuration.requestInterval = ms > 0 ? .milliseconds(ms) : nil
            case "--jpeg":
                let value = args.next() ?? "off"
                configuration.jpegQuality = Int(value)
            case "--encodings":
                configuration.encodings = (args.next() ?? "").split(separator: ",").compactMap(Self.encoding)
            default: positional.append(arg)
            }
        }
    }

    static func encoding(_ name: Substring) -> RFBEncoding? {
        switch name {
        case "raw": .raw
        case "copyrect": .copyRect
        case "hextile": .hextile
        case "tight": .tight
        case "zrle": .zrle
        default: nil
        }
    }

    var header: [String: String] {
        [
            "encodings": configuration.encodings.map(\.description).joined(separator: ","),
            "jpeg": configuration.jpegQuality.map(String.init) ?? "off",
            "continuous": configuration.continuousUpdates ? "1" : "0",
        ]
    }
}

final class RecordingTransport: RFBTransport {
    let inner: RFBTCPTransport
    let records: Bool
    let captured = Mutex(Data())

    init(_ inner: RFBTCPTransport, records: Bool) {
        self.inner = inner
        self.records = records
    }

    var executor: (any TaskExecutor)? { inner.executor }

    func receive(expecting count: Int) async throws -> Data? {
        let data = try await inner.receive(expecting: count)
        if records, let data { captured.withLock { $0.append(data) } }
        return data
    }

    func send(_ data: Data) { inner.send(data) }
    func close() { inner.close() }
}

final class ReplayTransport: RFBTransport {
    let data: Data
    let offset = Mutex(0)
    let chunk = 64 << 10

    init(_ data: Data) {
        self.data = data
    }

    func receive(expecting count: Int) async throws -> Data? {
        let range = offset.withLock { o -> Range<Int>? in
            guard o < data.count else { return nil }
            defer { o = min(o + chunk, data.count) }
            return o..<min(o + chunk, data.count)
        }
        guard let range else { return nil }
        return data.subdata(in: range)
    }

    func send(_ data: Data) {}
    func close() {}
}

func milliseconds(_ d: Duration) -> String {
    String(format: "%.1f", Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15)
}

func report(_ stats: RFBStatistics, seconds: Double, label: String) {
    print(
        "== \(label): \(stats.updates) updates in \(String(format: "%.2f", seconds)) s = \(String(format: "%.1f", Double(stats.updates) / seconds)) updates/s, wire \(String(format: "%.2f", Double(stats.bytes) / 1e6)) MB, continuous=\(stats.continuousUpdates) fences=\(stats.fences) extclipboard=\(stats.extendedClipboard)"
    )
    for (encoding, e) in stats.encodings.sorted(by: { $0.value.pixels > $1.value.pixels }) {
        let decodeSeconds = Double(e.nanoseconds) / 1e9
        if e.pixels == 0 {
            print("   \(encoding): \(e.rects) rects")
            continue
        }
        print(
            String(
                format: "   %@: %d rects, %.1f Mpx, %.2f MB wire, decode %.1f ms = %.0f MB/s wire, %.0f Mpx/s",
                encoding.description, e.rects, Double(e.pixels) / 1e6, Double(e.bytes) / 1e6, decodeSeconds * 1e3,
                Double(e.bytes) / 1e6 / max(decodeSeconds, 1e-9), Double(e.pixels) / 1e6 / max(decodeSeconds, 1e-9)
            ))
    }
}

func live(_ options: Options) async throws {
    guard let target = options.positional.first, let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) else {
        throw RFBError.transport("usage: rfb-bench live HOST:PORT")
    }
    let tcp = RFBTCPTransport(host: String(target[..<colon]), port: port)
    let recorder = RecordingTransport(tcp, records: options.record != nil)
    let client = RFBClient(transport: recorder, configuration: options.configuration)
    let started = ContinuousClock.now
    try await tcp.connect()
    let firstUpdate = Mutex<Duration?>(nil)
    let connected = Mutex<Duration?>(nil)
    let firstBytes = Mutex<Int?>(nil)
    let session = Task {
        try await client.run { event in
            switch event {
            case .connected:
                connected.withLock { $0 = ContinuousClock.now - started }
            case .updated:
                firstUpdate.withLock { if $0 == nil { $0 = ContinuousClock.now - started } }
                firstBytes.withLock { if $0 == nil { $0 = client.statistics.bytes } }
            default:
                break
            }
        }
    }
    try? await Task.sleep(for: .seconds(options.seconds))
    session.cancel()
    if case .failure(let error) = await session.result, !(error is CancellationError), error as? RFBError != .connectionClosed {
        print("error: \(error)")
    }
    let elapsed = ContinuousClock.now - started
    if let first = firstUpdate.withLock({ $0 }), let serverInit = connected.withLock({ $0 }) {
        print("server_init_ms=\(milliseconds(serverInit)) first_update_ms=\(milliseconds(first)) first_update_bytes=\(firstBytes.withLock { $0 } ?? 0)")
    }
    report(client.statistics, seconds: Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18, label: "live \(target)")
    if let path = options.record {
        let header = try JSONSerialization.data(withJSONObject: options.header, options: [.sortedKeys])
        var file = Data("RFBR".utf8)
        withUnsafeBytes(of: UInt32(header.count).bigEndian) { file.append(contentsOf: $0) }
        file.append(header)
        file.append(recorder.captured.withLock { $0 })
        try file.write(to: URL(fileURLWithPath: path))
        print("recorded \(file.count) bytes to \(path)")
    }
}

func loadRecording(_ path: String) throws -> (Options, Data) {
    let file = try Data(contentsOf: URL(fileURLWithPath: path))
    guard file.prefix(4) == Data("RFBR".utf8) else { throw RFBError.protocolViolation("not a recording") }
    let length = file[4..<8].reduce(0) { $0 << 8 | Int($1) }
    let header = try JSONSerialization.jsonObject(with: file[8..<(8 + length)]) as? [String: String] ?? [:]
    var args: [String] = ["--encodings", header["encodings"] ?? "", "--jpeg", header["jpeg"] ?? "off", "--password", "replay"]
    if header["continuous"] == "0" { args.append("--no-continuous") }
    return (Options(args[...]), file.subdata(in: (8 + length)..<file.count))
}

func replay(_ options: Options) async throws {
    guard let path = options.positional.first else { throw RFBError.transport("usage: rfb-bench replay FILE") }
    let (recorded, stream) = try loadRecording(path)
    for iteration in 1...options.iterations {
        let client = RFBClient(transport: ReplayTransport(stream), configuration: recorded.configuration)
        let started = ContinuousClock.now
        do {
            try await client.run { _ in }
        } catch RFBError.connectionClosed {
        }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let stats = client.statistics
        report(
            stats, seconds: seconds,
            label: "replay \(path) #\(iteration) (\(String(format: "%.0f", Double(stats.updates) / seconds)) frames/s, \(String(format: "%.0f", Double(stream.count) / 1e6 / seconds)) MB/s)")
    }
}

func target(_ options: Options) throws -> RFBTCPTransport {
    guard let target = options.positional.first, let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]) else {
        throw RFBError.transport("missing HOST:PORT")
    }
    return RFBTCPTransport(host: String(target[..<colon]), port: port)
}

// interact connects, waits for the first update, runs act, then keeps the
// session for the remaining seconds while printing clipboard events.
func interact(_ options: Options, act: @escaping @Sendable (RFBClient) -> Void) async throws {
    let tcp = try target(options)
    let client = RFBClient(transport: tcp, configuration: options.configuration)
    try await tcp.connect()
    let acted = Mutex(false)
    let session = Task {
        try await client.run { event in
            switch event {
            case .updated:
                guard
                    acted.withLock({ a in
                        defer { a = true }; return !a
                    })
                else { return }
                act(client)
            case .clipboard(let text):
                print("clipboard: \(text.debugDescription)")
            default:
                break
            }
        }
    }
    try? await Task.sleep(for: .seconds(options.seconds))
    session.cancel()
    if case .failure(let error) = await session.result, !(error is CancellationError), error as? RFBError != .connectionClosed {
        print("error: \(error)")
    }
}

// usLetters is the US layout for the key codes --keys accepts.
let usLetters: [UInt16: Unicode.Scalar] = [0x00: "a", 0x0B: "b", 0x08: "c", 0x02: "d", 0x0E: "e", 0x12: "1", 0x31: " "]

func input(_ options: Options) async throws {
    let move = options.move
    let click = options.click
    let text = options.text
    let options = options
    try await interact(options) { client in
        if let move {
            client.pointer(x: move.x, y: move.y, buttons: [])
            if click {
                client.pointer(x: move.x, y: move.y, buttons: .left)
                client.pointer(x: move.x, y: move.y, buttons: [])
            }
        }
        if let text { client.type(text) }
        if let keys = options.keyCodes {
            for keyCode in keys {
                guard let keysym = RFBKeyMap.keysym(keyCode: keyCode, characters: nil) ?? usLetters[keyCode].flatMap(RFBKeyMap.keysym(for:)) else { continue }
                client.key(keysym, down: true, scancode: RFBKeyMap.scancode(keyCode: keyCode))
                client.key(keysym, down: false, scancode: RFBKeyMap.scancode(keyCode: keyCode))
            }
        }
        print("sent input")
    }
}

func clipboard(_ options: Options) async throws {
    let text = options.text
    try await interact(options) { client in
        if let text {
            client.setClipboard(text)
            print("set clipboard \(text.debugDescription)")
        }
    }
}

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? ""
let options = Options(arguments.dropFirst())
do {
    switch command {
    case "live": try await live(options)
    case "replay": try await replay(options)
    case "input": try await input(options)
    case "clipboard": try await clipboard(options)
    default:
        print("usage: rfb-bench live HOST:PORT [--seconds N] [--encodings list] [--jpeg Q|off] [--no-continuous] [--record FILE]\n       rfb-bench replay FILE [--iterations N]")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
