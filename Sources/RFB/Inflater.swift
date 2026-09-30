import Foundation
import zlib

// Inflater is one persistent zlib stream, as ZRLE and Tight keep across
// rectangles.
final class Inflater {
    private let stream: UnsafeMutablePointer<z_stream>

    init() throws {
        stream = .allocate(capacity: 1)
        stream.initialize(to: z_stream())
        let status = inflateInit_(stream, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
        guard status == Z_OK else {
            stream.deallocate()
            throw RFBError.protocolViolation("inflateInit \(status)")
        }
    }

    deinit {
        inflateEnd(stream)
        stream.deallocate()
    }

    func reset() {
        inflateReset(stream)
    }

    // inflate feeds all of input and returns the bytes written to output,
    // growing it as needed; exact, when given, must match that count.
    func inflate(_ input: UnsafeRawBufferPointer, into output: inout Scratch, exact: Int? = nil) throws -> Int {
        if let exact { output.reserve(exact + 1) }
        stream.pointee.next_in = UnsafeMutablePointer(mutating: input.baseAddress?.assumingMemoryBound(to: Bytef.self))
        stream.pointee.avail_in = uInt(input.count)
        var produced = 0
        repeat {
            if produced == output.capacity {
                if let exact, produced > exact { break }
                output.reserve(output.capacity * 2, keeping: produced)
            }
            let room = output.capacity - produced
            stream.pointee.next_out = (output.base + produced).assumingMemoryBound(to: Bytef.self)
            stream.pointee.avail_out = uInt(room)
            let status = zlib.inflate(stream, Z_SYNC_FLUSH)
            produced += room - Int(stream.pointee.avail_out)
            if status == Z_BUF_ERROR { break }
            guard status == Z_OK || status == Z_STREAM_END else {
                throw RFBError.protocolViolation("inflate \(status)")
            }
        } while stream.pointee.avail_in > 0 || stream.pointee.avail_out == 0
        if let exact, produced != exact {
            throw RFBError.protocolViolation("zlib produced \(produced) bytes, expected \(exact)")
        }
        return produced
    }
}

// Scratch is a reusable byte buffer that only grows.
struct Scratch: ~Copyable {
    private(set) var base: UnsafeMutableRawPointer
    private(set) var capacity: Int

    init(capacity: Int = 64 << 10) {
        self.capacity = capacity
        base = .allocate(byteCount: capacity, alignment: 16)
    }

    deinit {
        base.deallocate()
    }

    mutating func reserve(_ size: Int, keeping: Int = 0) {
        guard size > capacity else { return }
        var grown = capacity
        while grown < size { grown *= 2 }
        let next = UnsafeMutableRawPointer.allocate(byteCount: grown, alignment: 16)
        if keeping > 0 { next.copyMemory(from: base, byteCount: keeping) }
        base.deallocate()
        base = next
        capacity = grown
    }
}
