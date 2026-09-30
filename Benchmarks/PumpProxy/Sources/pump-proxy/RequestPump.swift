// A client-side request pump of the kind an embedding app ran in front of a
// client that asks for one update per round trip; the baseline for the pacing
// A/B in docs/benchmarks.md. It reads an extended ClientCutText's negative
// length as the payload size.
import Foundation
import Synchronization

// ClientMessageTap follows the client-to-server RFB byte stream and forwards it in
// whole messages, so extra messages can be spliced in between them. It keeps
// the client's last FramebufferUpdateRequest in incremental form.
public struct ClientMessageTap: Sendable {
    enum Stage: Sendable {
        case version
        case security
        case vncAuth
        case clientInit
        case messages
        case opaque
    }

    var stage = Stage.version
    var pending: [UInt8] = []
    public private(set) var request: Data?

    public init() {}

    public var atBoundary: Bool {
        stage == .messages && pending.isEmpty
    }

    // feed returns the bytes that may be forwarded now.
    public mutating func feed(_ chunk: Data) -> Data {
        if stage == .opaque { return chunk }
        pending.append(contentsOf: chunk)
        var ready = 0
        while let length = nextLength(at: ready) {
            if stage == .messages, pending[ready] == 3 {
                var incremental = Array(pending[ready..<ready + 10])
                incremental[1] = 1
                request = Data(incremental)
            }
            advance(at: ready)
            ready += length
            if stage == .opaque {
                ready = pending.count
                break
            }
        }
        let out = Data(pending[..<ready])
        pending.removeFirst(ready)
        return out
    }

    private func nextLength(at offset: Int) -> Int? {
        let available = pending.count - offset
        guard available > 0 else { return nil }
        let length: Int
        switch stage {
        case .version: length = 12
        case .security, .clientInit: length = 1
        case .vncAuth: length = 16
        case .opaque: return nil
        case .messages:
            switch pending[offset] {
            case 0: length = 20
            case 2:
                guard available >= 4 else { return nil }
                length = 4 + 4 * (Int(pending[offset + 2]) << 8 | Int(pending[offset + 3]))
            case 3, 150: length = 10
            case 4: length = 8
            case 5: length = 6
            case 6:
                guard available >= 8 else { return nil }
                let text = Int(pending[offset + 4]) << 24 | Int(pending[offset + 5]) << 16 | Int(pending[offset + 6]) << 8 | Int(pending[offset + 7])
                length = 8 + Int(Int32(truncatingIfNeeded: text).magnitude)
            default:
                return available
            }
        }
        return available >= length ? length : nil
    }

    private mutating func advance(at offset: Int) {
        switch stage {
        case .version:
            stage = .security
        case .security:
            switch pending[offset] {
            case 1: stage = .clientInit
            case 2: stage = .vncAuth
            default: stage = .opaque
            }
        case .vncAuth:
            stage = .clientInit
        case .clientInit:
            stage = .messages
        case .messages:
            if ![0, 2, 3, 4, 5, 6, 150].contains(pending[offset]) { stage = .opaque }
        case .opaque:
            break
        }
    }
}

// RequestPump keeps an incremental update request outstanding at the server
// while the screen is changing. RFB servers answer one request with one
// update, so without it the frame rate is capped at one per network round
// trip. It repeats the client's own last request between client messages and
// stops `linger` after the server goes quiet, so an idle screen costs nothing.
final class RequestPump: Sendable {
    private struct State {
        var tap = ClientMessageTap()
        var lastActivity = ContinuousClock.now
        var running = false
        var finished = false
    }

    private let interval: Duration
    private let linger: Duration
    private let continuation: AsyncStream<Data>.Continuation
    private let state = Mutex(State())
    private let injected: @Sendable () -> Void
    let stream: AsyncStream<Data>

    init(interval: Duration = .milliseconds(33), linger: Duration = .seconds(1), injected: @escaping @Sendable () -> Void = {}) {
        self.interval = interval
        self.linger = linger
        self.injected = injected
        (stream, continuation) = AsyncStream<Data>.makeStream()
    }

    // forward drains the client's stream through the tap into `stream`.
    func forward(_ outbound: AsyncStream<Data>) async {
        for await chunk in outbound {
            state.withLock { s in
                let ready = s.tap.feed(chunk)
                if !ready.isEmpty { continuation.yield(ready) }
            }
        }
        state.withLock { $0.finished = true }
        continuation.finish()
    }

    func serverActivity() {
        let start = state.withLock { s -> Bool in
            s.lastActivity = ContinuousClock.now
            guard !s.running, !s.finished, s.tap.request != nil else { return false }
            s.running = true
            return true
        }
        guard start else { return }
        Task { [self] in
            while true {
                try? await Task.sleep(for: interval)
                let keepGoing = state.withLock { s -> Bool in
                    guard !s.finished, ContinuousClock.now - s.lastActivity < linger else {
                        s.running = false
                        return false
                    }
                    if s.tap.atBoundary, let request = s.tap.request {
                        continuation.yield(request)
                        injected()
                    }
                    return true
                }
                if !keepGoing { return }
            }
        }
    }
}
