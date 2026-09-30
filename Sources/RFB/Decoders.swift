import Foundation

protocol RectDecoder: AnyObject {
    func decode(_ rect: RFBRect, from reader: Reader, into framebuffer: RFBFramebuffer) async throws
}

final class RawDecoder: RectDecoder {
    func decode(_ rect: RFBRect, from reader: Reader, into framebuffer: RFBFramebuffer) async throws {
        let rowBytes = rect.width * 4
        let rowsPerRead = max(1, (256 << 10) / max(rowBytes, 1))
        var y = 0
        while y < rect.height {
            let rows = min(rowsPerRead, rect.height - y)
            try await reader.need(rows * rowBytes)
            let src = reader.bytes(rows * rowBytes)
            for r in 0..<rows {
                memcpy(framebuffer.row(rect.y + y + r, x: rect.x), src.baseAddress! + r * rowBytes, rowBytes)
            }
            y += rows
        }
    }
}

final class CopyRectDecoder: RectDecoder {
    func decode(_ rect: RFBRect, from reader: Reader, into framebuffer: RFBFramebuffer) async throws {
        try await reader.need(4)
        let source = RFBRect(x: Int(reader.u16()), y: Int(reader.u16()), width: rect.width, height: rect.height)
        guard source.x + source.width <= framebuffer.width, source.y + source.height <= framebuffer.height else {
            throw RFBError.protocolViolation("copyrect source \(source) outside framebuffer")
        }
        framebuffer.copy(from: source, toX: rect.x, y: rect.y)
    }
}

final class HextileDecoder: RectDecoder {
    private static let raw: UInt8 = 1
    private static let backgroundSpecified: UInt8 = 2
    private static let foregroundSpecified: UInt8 = 4
    private static let anySubrects: UInt8 = 8
    private static let subrectsColoured: UInt8 = 16

    func decode(_ rect: RFBRect, from reader: Reader, into framebuffer: RFBFramebuffer) async throws {
        var background: UInt32 = 0
        var foreground: UInt32 = 0
        for ty in stride(from: 0, to: rect.height, by: 16) {
            for tx in stride(from: 0, to: rect.width, by: 16) {
                let tile = RFBRect(x: rect.x + tx, y: rect.y + ty, width: min(16, rect.width - tx), height: min(16, rect.height - ty))
                let flags = try await reader.readU8()
                if flags & Self.raw != 0 {
                    try await reader.need(tile.width * tile.height * 4)
                    let src = reader.bytes(tile.width * tile.height * 4)
                    for r in 0..<tile.height {
                        memcpy(framebuffer.row(tile.y + r, x: tile.x), src.baseAddress! + r * tile.width * 4, tile.width * 4)
                    }
                    continue
                }
                let header = (flags & Self.backgroundSpecified != 0 ? 4 : 0) + (flags & Self.foregroundSpecified != 0 ? 4 : 0) + (flags & Self.anySubrects != 0 ? 1 : 0)
                try await reader.need(header)
                if flags & Self.backgroundSpecified != 0 { background = reader.pixel() }
                if flags & Self.foregroundSpecified != 0 { foreground = reader.pixel() }
                framebuffer.fill(tile, background)
                guard flags & Self.anySubrects != 0 else { continue }
                let count = Int(reader.u8())
                let coloured = flags & Self.subrectsColoured != 0
                try await reader.need(count * (coloured ? 6 : 2))
                for _ in 0..<count {
                    let pixel = coloured ? reader.pixel() : foreground
                    let xy = reader.u8()
                    let wh = reader.u8()
                    let sub = RFBRect(x: tile.x + Int(xy >> 4), y: tile.y + Int(xy & 15), width: Int(wh >> 4) + 1, height: Int(wh & 15) + 1)
                    guard sub.x + sub.width <= tile.x + tile.width, sub.y + sub.height <= tile.y + tile.height else {
                        throw RFBError.protocolViolation("hextile subrect \(sub) outside tile \(tile)")
                    }
                    framebuffer.fill(sub, pixel)
                }
            }
        }
    }
}

// Palette holds up to 128 decoded colours for ZRLE and Tight.
final class Palette {
    let colors = UnsafeMutablePointer<UInt32>.allocate(capacity: 256)

    deinit {
        colors.deallocate()
    }
}

final class ZRLEDecoder: RectDecoder {
    private let inflater: Inflater
    private var scratch = Scratch(capacity: 1 << 20)
    private let palette = Palette()

    init() throws {
        inflater = try Inflater()
    }

    func decode(_ rect: RFBRect, from reader: Reader, into framebuffer: RFBFramebuffer) async throws {
        let length = Int(try await reader.readU32())
        try await reader.need(length)
        let produced = try inflater.inflate(reader.bytes(length), into: &scratch)
        scratch.reserve(produced + 4, keeping: produced)
        try tiles(UnsafeRawBufferPointer(start: scratch.base, count: produced), rect, framebuffer)
    }

    private func tiles(_ data: UnsafeRawBufferPointer, _ rect: RFBRect, _ framebuffer: RFBFramebuffer) throws {
        let src = data.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let count = data.count
        var at = 0
        func need(_ n: Int) throws {
            guard at + n <= count else { throw RFBError.protocolViolation("ZRLE tile data truncated") }
        }
        @inline(__always) func cpixel(_ p: UnsafePointer<UInt8>) -> UInt32 {
            UInt32(p[0]) | UInt32(p[1]) << 8 | UInt32(p[2]) << 16
        }
        func runLength() throws -> Int {
            var length = 1
            while true {
                try need(1)
                let byte = src[at]
                at += 1
                length += Int(byte)
                if byte != 255 { return length }
            }
        }
        let colors = palette.colors
        for ty in stride(from: 0, to: rect.height, by: 64) {
            for tx in stride(from: 0, to: rect.width, by: 64) {
                let x0 = rect.x + tx
                let y0 = rect.y + ty
                let tw = min(64, rect.width - tx)
                let th = min(64, rect.height - ty)
                try need(1)
                let sub = src[at]
                at += 1
                switch sub {
                case 0:
                    try need(tw * th * 3)
                    var p = UnsafeRawPointer(src + at)
                    for y in 0..<th {
                        let row = framebuffer.row(y0 + y, x: x0)
                        for x in 0..<tw {
                            row[x] = UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)) & 0x00FF_FFFF
                            p += 3
                        }
                    }
                    at += tw * th * 3
                case 1:
                    try need(3)
                    framebuffer.fill(RFBRect(x: x0, y: y0, width: tw, height: th), cpixel(src + at))
                    at += 3
                case 2...16:
                    let size = Int(sub)
                    try need(size * 3)
                    for i in 0..<size {
                        colors[i] = cpixel(src + at)
                        at += 3
                    }
                    let bits = size == 2 ? 1 : size <= 4 ? 2 : 4
                    let rowBytes = (tw * bits + 7) / 8
                    try need(rowBytes * th)
                    let mask = UInt8((1 << bits) - 1)
                    for y in 0..<th {
                        let row = framebuffer.row(y0 + y, x: x0)
                        let packed = src + at
                        for x in 0..<tw {
                            let bit = x * bits
                            let index = Int((packed[bit >> 3] >> UInt8(8 - bits - (bit & 7))) & mask)
                            guard index < size else { throw RFBError.protocolViolation("ZRLE palette index \(index) of \(size)") }
                            row[x] = colors[index]
                        }
                        at += rowBytes
                    }
                case 128, 130...255:
                    let size = sub == 128 ? 0 : Int(sub) - 128
                    try need(size * 3)
                    for i in 0..<size {
                        colors[i] = cpixel(src + at)
                        at += 3
                    }
                    var x = 0
                    var y = 0
                    var remaining = tw * th
                    while remaining > 0 {
                        let pixel: UInt32
                        var run = 1
                        if size == 0 {
                            try need(3)
                            pixel = cpixel(src + at)
                            at += 3
                            run = try runLength()
                        } else {
                            try need(1)
                            let index = Int(src[at] & 0x7F)
                            let isRun = src[at] & 0x80 != 0
                            at += 1
                            guard index < size else { throw RFBError.protocolViolation("ZRLE palette index \(index) of \(size)") }
                            pixel = colors[index]
                            if isRun { run = try runLength() }
                        }
                        guard run <= remaining else { throw RFBError.protocolViolation("ZRLE run \(run) exceeds tile") }
                        remaining -= run
                        while run > 0 {
                            let span = min(run, tw - x)
                            framebuffer.row(y0 + y, x: x0 + x).update(repeating: pixel, count: span)
                            run -= span
                            x += span
                            if x == tw {
                                x = 0
                                y += 1
                            }
                        }
                    }
                default:
                    throw RFBError.protocolViolation("ZRLE subencoding \(sub)")
                }
            }
        }
    }
}

final class TightDecoder: RectDecoder {
    private var streams: [Inflater]
    private var scratch = Scratch(capacity: 1 << 20)
    private let palette = Palette()
    private var gradientRow: [Int] = []

    init() throws {
        streams = try (0..<4).map { _ in try Inflater() }
    }

    func decode(_ rect: RFBRect, from reader: Reader, into framebuffer: RFBFramebuffer) async throws {
        let control = try await reader.readU8()
        for i in 0..<4 where control & (1 << i) != 0 {
            streams[i].reset()
        }
        let kind = control >> 4
        switch kind {
        case 8:
            try await reader.need(3)
            let p = reader.bytes(3)
            framebuffer.fill(rect, Self.tpixel(p.baseAddress!.assumingMemoryBound(to: UInt8.self)))
        case 9:
            let length = try await compactLength(reader)
            try await reader.need(length)
            try JPEG.decode(reader.bytes(length), into: framebuffer, rect: rect)
        case 0...7:
            try await basic(kind, rect, reader, framebuffer)
        default:
            throw RFBError.protocolViolation("tight compression \(kind)")
        }
    }

    private func basic(_ kind: UInt8, _ rect: RFBRect, _ reader: Reader, _ framebuffer: RFBFramebuffer) async throws {
        let filter = kind & 4 != 0 ? try await reader.readU8() : 0
        var colours = 0
        let size: Int
        switch filter {
        case 0, 2:
            size = rect.width * rect.height * 3
        case 1:
            colours = Int(try await reader.readU8()) + 1
            try await reader.need(colours * 3)
            let p = reader.bytes(colours * 3).baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<colours {
                palette.colors[i] = Self.tpixel(p + i * 3)
            }
            size = colours == 2 ? (rect.width + 7) / 8 * rect.height : rect.width * rect.height
        default:
            throw RFBError.protocolViolation("tight filter \(filter)")
        }
        let data: UnsafePointer<UInt8>
        if size < 12 {
            try await reader.need(size)
            data = reader.bytes(size).baseAddress!.assumingMemoryBound(to: UInt8.self)
        } else {
            let length = try await compactLength(reader)
            try await reader.need(length)
            _ = try streams[Int(kind & 3)].inflate(reader.bytes(length), into: &scratch, exact: size)
            scratch.reserve(size + 4, keeping: size)
            data = UnsafePointer(scratch.base.assumingMemoryBound(to: UInt8.self))
        }
        switch filter {
        case 0 where size < 12:
            for y in 0..<rect.height {
                let row = framebuffer.row(rect.y + y, x: rect.x)
                for x in 0..<rect.width {
                    row[x] = Self.tpixel(data + (y * rect.width + x) * 3)
                }
            }
        case 0:
            var p = UnsafeRawPointer(data)
            for y in 0..<rect.height {
                let row = framebuffer.row(rect.y + y, x: rect.x)
                for x in 0..<rect.width {
                    row[x] = UInt32(littleEndian: p.loadUnaligned(as: UInt32.self)).byteSwapped >> 8
                    p += 3
                }
            }
        case 1 where colours == 2:
            let rowBytes = (rect.width + 7) / 8
            let colors = palette.colors
            for y in 0..<rect.height {
                let row = framebuffer.row(rect.y + y, x: rect.x)
                let bits = data + y * rowBytes
                for x in 0..<rect.width {
                    row[x] = colors[Int(bits[x >> 3] >> UInt8(7 - (x & 7)) & 1)]
                }
            }
        case 1:
            let colors = palette.colors
            for y in 0..<rect.height {
                let row = framebuffer.row(rect.y + y, x: rect.x)
                let src = data + y * rect.width
                for x in 0..<rect.width {
                    let index = Int(src[x])
                    guard index < colours else { throw RFBError.protocolViolation("tight palette index \(index) of \(colours)") }
                    row[x] = colors[index]
                }
            }
        default:
            gradient(data, rect, framebuffer)
        }
    }

    private func gradient(_ data: UnsafePointer<UInt8>, _ rect: RFBRect, _ framebuffer: RFBFramebuffer) {
        let stride = rect.width * 3
        if gradientRow.count < stride * 2 {
            gradientRow = [Int](repeating: 0, count: stride * 2)
        }
        gradientRow.withUnsafeMutableBufferPointer { rows in
            let previous = rows.baseAddress!
            let current = previous + stride
            previous.update(repeating: 0, count: stride)
            for y in 0..<rect.height {
                let src = data + y * stride
                let row = framebuffer.row(rect.y + y, x: rect.x)
                for x in 0..<rect.width {
                    for c in 0..<3 {
                        let i = x * 3 + c
                        let left = x > 0 ? current[i - 3] : 0
                        let upLeft = x > 0 ? previous[i - 3] : 0
                        let estimate = min(max(left + previous[i] - upLeft, 0), 255)
                        current[i] = (estimate + Int(src[i])) & 0xFF
                    }
                    row[x] = UInt32(current[x * 3]) << 16 | UInt32(current[x * 3 + 1]) << 8 | UInt32(current[x * 3 + 2])
                }
                previous.update(from: current, count: stride)
            }
        }
    }

    private func compactLength(_ reader: Reader) async throws -> Int {
        var length = 0
        for i in 0..<3 {
            let byte = Int(try await reader.readU8())
            if i == 2 {
                return length | byte << 14
            }
            length |= (byte & 0x7F) << (7 * i)
            if byte & 0x80 == 0 { break }
        }
        return length
    }

    @inline(__always)
    private static func tpixel(_ p: UnsafePointer<UInt8>) -> UInt32 {
        UInt32(p[0]) << 16 | UInt32(p[1]) << 8 | UInt32(p[2])
    }
}
