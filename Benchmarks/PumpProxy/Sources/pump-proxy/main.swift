import Foundation
import Network

// pump-proxy LISTEN_PORT TARGET_PORT: one session at a time; client bytes go
// through UpdatePump, server bytes straight back.

let args = CommandLine.arguments
guard args.count == 3, let listen = NWEndpoint.Port(args[1]), let target = NWEndpoint.Port(args[2]) else {
    print("usage: pump-proxy LISTEN_PORT TARGET_PORT")
    exit(2)
}
let queue = DispatchQueue(label: "pump-proxy")
let tcp = NWProtocolTCP.Options()
tcp.noDelay = true
let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: listen)

func pipe(_ from: NWConnection, _ onData: @escaping @Sendable (Data) -> Void, _ onEnd: @escaping @Sendable () -> Void) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, error in
        if let data, !data.isEmpty { onData(data) }
        if done || error != nil { return onEnd() }
        pipe(from, onData, onEnd)
    }
}

listener.newConnectionHandler = { client in
    let server = NWConnection(host: "127.0.0.1", port: target, using: NWParameters(tls: nil, tcp: tcp))
    client.start(queue: queue)
    server.start(queue: queue)
    let injected = Counter()
    let pump = UpdatePump { injected.add() }
    let (outbound, continuation) = AsyncStream<Data>.makeStream()
    let end: @Sendable () -> Void = {
        continuation.finish()
        client.cancel()
        server.cancel()
        print("session ended, injected \(injected.value) requests")
    }
    pipe(client, { continuation.yield($0) }, end)
    pipe(server, { data in
        pump.serverActivity()
        client.send(content: data, completion: .idempotent)
    }, end)
    Task { await pump.forward(outbound) }
    Task {
        for await chunk in pump.stream { server.send(content: chunk, completion: .idempotent) }
    }
}
listener.start(queue: queue)
setvbuf(stdout, nil, _IOLBF, 0)
print("pump-proxy :\(listen) -> :\(target)")
dispatchMain()

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
