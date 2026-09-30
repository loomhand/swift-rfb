import Foundation

// Reader buffers transport chunks so decoders can work on contiguous bytes.
// Accessors after need(n) are unchecked within those n bytes; a pointer
// from bytes(n) stays valid until the next need.
final class Reader {
    private let transport: any RFBTransport
    private var storage: UnsafeMutableRawPointer
    private var capacity: Int
    private var start = 0
    private var end = 0
    private(set) var consumed = 0

    init(transport: any RFBTransport, capacity: Int = 256 << 10) {
        self.transport = transport
        self.capacity = capacity
        storage = .allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        storage.deallocate()
    }

    var available: Int { end - start }

    func need(_ count: Int) async throws {
        guard count <= 256 << 20 else { throw RFBError.protocolViolation("\(count) byte message") }
        while end - start < count {
            guard let chunk = try await transport.receive() else { throw RFBError.connectionClosed }
            append(chunk, reserving: count)
        }
    }

    private func append(_ chunk: Data, reserving count: Int) {
        let pending = end - start
        let required = max(count, pending + chunk.count)
        if required > capacity {
            var size = capacity
            while size < required { size *= 2 }
            let grown = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
            grown.copyMemory(from: storage + start, byteCount: pending)
            storage.deallocate()
            storage = grown
            capacity = size
            start = 0
            end = pending
        } else if capacity - end < chunk.count {
            memmove(storage, storage + start, pending)
            start = 0
            end = pending
        }
        chunk.copyBytes(to: (storage + end).assumingMemoryBound(to: UInt8.self), count: chunk.count)
        end += chunk.count
    }

    @inline(__always)
    func u8() -> UInt8 {
        let value = storage.load(fromByteOffset: start, as: UInt8.self)
        start += 1
        consumed += 1
        return value
    }

    @inline(__always)
    func u16() -> UInt16 {
        UInt16(u8()) << 8 | UInt16(u8())
    }

    @inline(__always)
    func u32() -> UInt32 {
        UInt32(u16()) << 16 | UInt32(u16())
    }

    @inline(__always)
    func pixel() -> UInt32 {
        let value = storage.loadUnaligned(fromByteOffset: start, as: UInt32.self)
        start += 4
        consumed += 4
        return UInt32(littleEndian: value)
    }

    func bytes(_ count: Int) -> UnsafeRawBufferPointer {
        let buffer = UnsafeRawBufferPointer(start: storage + start, count: count)
        start += count
        consumed += count
        return buffer
    }

    func skip(_ count: Int) async throws {
        var left = count
        while left > 0 {
            if available == 0 { try await need(1) }
            let step = min(left, available)
            start += step
            consumed += step
            left -= step
        }
    }

    func readU8() async throws -> UInt8 {
        try await need(1)
        return u8()
    }

    func readU16() async throws -> UInt16 {
        try await need(2)
        return u16()
    }

    func readU32() async throws -> UInt32 {
        try await need(4)
        return u32()
    }

    func readData(_ count: Int) async throws -> Data {
        try await need(count)
        return Data(bytes(count))
    }

    func readString(_ count: Int) async throws -> String {
        let data = try await readData(count)
        return String(decoding: data, as: UTF8.self)
    }
}
