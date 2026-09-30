import Foundation
import RFB
import Synchronization

// rfb-bench live   HOST:PORT [--seconds N] [options] [--record FILE]
// rfb-bench replay FILE [--iterations N]
// options: --encodings tight,zrle,hextile,raw  --jpeg 0-9|off  --no-continuous  --password PW

struct Options {
    var configuration = RFBClient.Configuration()
    var seconds = 10.0
    var iterations = 5
    var record: String?
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
            case "--password": configuration.password = args.next()
            case "--no-continuous": configuration.continuousUpdates = false
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
    let captured = Mutex(Data())

    init(_ inner: RFBTCPTransport) {
        self.inner = inner
    }

    func receive() async throws -> Data? {
        let data = try await inner.receive()
        if let data { captured.withLock { $0.append(data) } }
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

    func receive() async throws -> Data? {
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

func report(_ stats: RFBStatistics, seconds: Double, label: String) {
    print("== \(label): \(stats.updates) updates in \(String(format: "%.2f", seconds)) s = \(String(format: "%.1f", Double(stats.updates) / seconds)) updates/s, wire \(String(format: "%.2f", Double(stats.bytes) / 1e6)) MB, continuous=\(stats.continuousUpdates) fences=\(stats.fences)")
    for (encoding, e) in stats.encodings.sorted(by: { $0.value.pixels > $1.value.pixels }) {
        let decodeSeconds = Double(e.nanoseconds) / 1e9
        if e.pixels == 0 {
            print("   \(encoding): \(e.rects) rects")
            continue
        }
        print(String(
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
    let recorder = RecordingTransport(tcp)
    let client = RFBClient(transport: recorder, configuration: options.configuration)
    let started = ContinuousClock.now
    try await tcp.connect()
    let firstUpdate = Mutex<Duration?>(nil)
    let session = Task {
        try await client.run { event in
            if case .updated = event {
                firstUpdate.withLock { if $0 == nil { $0 = ContinuousClock.now - started } }
            }
        }
    }
    try? await Task.sleep(for: .seconds(options.seconds))
    session.cancel()
    _ = await session.result
    let elapsed = ContinuousClock.now - started
    if let first = firstUpdate.withLock({ $0 }) {
        print("first_update_ms=\(String(format: "%.1f", Double(first.components.attoseconds) / 1e15 + Double(first.components.seconds) * 1e3))")
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
    var args: [String] = ["--encodings", header["encodings"] ?? "", "--jpeg", header["jpeg"] ?? "off"]
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
        report(stats, seconds: seconds, label: "replay \(path) #\(iteration) (\(String(format: "%.0f", Double(stats.updates) / seconds)) frames/s, \(String(format: "%.0f", Double(stream.count) / 1e6 / seconds)) MB/s)")
    }
}

let arguments = CommandLine.arguments.dropFirst()
let command = arguments.first ?? ""
let options = Options(arguments.dropFirst())
do {
    switch command {
    case "live": try await live(options)
    case "replay": try await replay(options)
    default:
        print("usage: rfb-bench live HOST:PORT [--seconds N] [--encodings list] [--jpeg Q|off] [--no-continuous] [--record FILE]\n       rfb-bench replay FILE [--iterations N]")
        exit(2)
    }
} catch {
    print("error: \(error)")
    exit(1)
}
