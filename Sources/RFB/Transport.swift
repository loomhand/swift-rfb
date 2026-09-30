import Foundation
import Network
import Synchronization

public enum RFBError: Error, Equatable, CustomStringConvertible {
    case connectionClosed
    case transport(String)
    case unsupportedVersion(String)
    case unsupportedSecurity([UInt8])
    case passwordRequired
    case authenticationFailed(String)
    case serverRefused(String)
    case protocolViolation(String)

    public var description: String {
        switch self {
        case .connectionClosed: "connection closed"
        case .transport(let reason): "transport: \(reason)"
        case .unsupportedVersion(let version): "unsupported protocol version \(version)"
        case .unsupportedSecurity(let types): "no supported security type in \(types)"
        case .passwordRequired: "server requires a password"
        case .authenticationFailed(let reason): "authentication failed: \(reason)"
        case .serverRefused(let reason): "server refused the connection: \(reason)"
        case .protocolViolation(let reason): "protocol violation: \(reason)"
        }
    }
}

// RFBTransport is the byte stream under one RFB session. receive is called
// by one reader at a time, may wait for up to `expecting` bytes and returns
// nil at end of stream; send never blocks and keeps call order; close fails
// a pending receive.
public protocol RFBTransport: Sendable {
    func receive(expecting count: Int) async throws -> Data?
    func send(_ data: Data)
    func close()
    // executor, when set, runs the session where receive completes, saving
    // a thread hop per read.
    var executor: (any TaskExecutor)? { get }
}

extension RFBTransport {
    public var executor: (any TaskExecutor)? { nil }
}

final class QueueExecutor: TaskExecutor {
    let queue: DispatchQueue

    init(_ queue: DispatchQueue) {
        self.queue = queue
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.async { job.runSynchronously(on: executor) }
    }
}

public final class RFBTCPTransport: RFBTransport {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "rfb.tcp", qos: .userInteractive)
    public let executor: (any TaskExecutor)?
    private let waiter = Mutex<CheckedContinuation<Void, any Error>?>(nil)

    public init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port) ?? 5900, using: NWParameters(tls: nil, tcp: tcp))
        executor = QueueExecutor(queue)
    }

    deinit {
        connection.cancel()
    }

    // connect resolves once the connection is established.
    public func connect() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waiter.withLock { $0 = continuation }
                connection.stateUpdateHandler = { [weak self] state in
                    let outcome: Result<Void, any Error>
                    switch state {
                    case .ready: outcome = .success(())
                    case .failed(let error), .waiting(let error):
                        self?.connection.cancel()
                        outcome = .failure(RFBError.transport("\(error)"))
                    case .cancelled: outcome = .failure(RFBError.connectionClosed)
                    default: return
                    }
                    self?.waiter.withLock { w in
                        defer { w = nil }
                        return w
                    }?.resume(with: outcome)
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    public func receive(expecting count: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: min(max(count, 1), 1 << 20), maximumLength: max(count, 1 << 20)) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if case .posix(.ECANCELED) = error {
                    continuation.resume(throwing: RFBError.connectionClosed)
                } else if let error {
                    continuation.resume(throwing: RFBError.transport("\(error)"))
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    public func send(_ data: Data) {
        connection.send(content: data, completion: .idempotent)
    }

    public func close() {
        connection.cancel()
    }
}

// RFBPipe carries a session over any other byte stream: feed server bytes
// with deliver (it suspends while the client is behind), end them with
// finish, and forward `outbound` to the server.
public final class RFBPipe: RFBTransport {
    public let outbound: AsyncStream<Data>
    private let output: AsyncStream<Data>.Continuation
    private let state = Mutex(PipeState())
    private let limit: Int

    private enum Ending {
        case endOfStream
        case failed(RFBError)
    }

    private struct PipeState {
        var chunks: [Data] = []
        var head = 0
        var buffered = 0
        var ending: Ending?
        var reader: CheckedContinuation<Data?, any Error>?
        var writers: [CheckedContinuation<Void, Never>] = []
    }

    public init(bufferLimit: Int = 4 << 20) {
        (outbound, output) = AsyncStream<Data>.makeStream()
        limit = bufferLimit
    }

    public func deliver(_ data: Data) async {
        guard !data.isEmpty else { return }
        await withCheckedContinuation { (writer: CheckedContinuation<Void, Never>) in
            let (reader, blocked) = state.withLock { s -> (CheckedContinuation<Data?, any Error>?, Bool) in
                if s.ending != nil { return (nil, false) }
                if let reader = s.reader {
                    s.reader = nil
                    return (reader, false)
                }
                s.chunks.append(data)
                s.buffered += data.count
                guard s.buffered >= limit else { return (nil, false) }
                s.writers.append(writer)
                return (nil, true)
            }
            reader?.resume(returning: data)
            if !blocked { writer.resume() }
        }
    }

    public func finish(throwing error: RFBError? = nil) {
        end(error.map { .failed($0) } ?? .endOfStream)
    }

    public func receive(expecting count: Int = 1) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            let (outcome, writers) = state.withLock { s -> (Result<Data?, any Error>?, [CheckedContinuation<Void, Never>]) in
                if s.head < s.chunks.count {
                    let data = s.chunks[s.head]
                    s.head += 1
                    s.buffered -= data.count
                    if s.head == s.chunks.count {
                        s.chunks.removeAll(keepingCapacity: true)
                        s.head = 0
                    }
                    var writers: [CheckedContinuation<Void, Never>] = []
                    if s.buffered < limit { swap(&writers, &s.writers) }
                    return (.success(data), writers)
                }
                switch s.ending {
                case .endOfStream: return (.success(nil), [])
                case .failed(let error): return (.failure(error), [])
                case nil:
                    s.reader = continuation
                    return (nil, [])
                }
            }
            writers.forEach { $0.resume() }
            if let outcome { continuation.resume(with: outcome) }
        }
    }

    public func send(_ data: Data) {
        output.yield(data)
    }

    public func close() {
        end(.failed(.connectionClosed))
        output.finish()
    }

    private func end(_ ending: Ending) {
        let (reader, writers) = state.withLock { s -> (CheckedContinuation<Data?, any Error>?, [CheckedContinuation<Void, Never>]) in
            guard s.ending == nil else { return (nil, []) }
            s.ending = ending
            if case .failed = ending {
                s.chunks = []
                s.head = 0
                s.buffered = 0
            }
            defer { s.reader = nil; s.writers = [] }
            return (s.reader, s.writers)
        }
        writers.forEach { $0.resume() }
        switch ending {
        case .endOfStream: reader?.resume(returning: nil)
        case .failed(let error): reader?.resume(throwing: error)
        }
    }
}
