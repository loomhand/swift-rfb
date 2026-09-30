import CoreGraphics
import Foundation

public struct RFBRect: Sendable, Equatable, CustomStringConvertible {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isEmpty: Bool { width <= 0 || height <= 0 }

    public var description: String { "\(width)x\(height)+\(x)+\(y)" }

    public func union(_ other: RFBRect) -> RFBRect {
        if isEmpty { return other }
        if other.isEmpty { return self }
        let minX = min(x, other.x)
        let minY = min(y, other.y)
        let maxX = max(x + width, other.x + other.width)
        let maxY = max(y + height, other.y + other.height)
        return RFBRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// RFBFramebuffer is 32bpp BGRX memory the decoders write into. The base
// address is page aligned, the length a page multiple and rows 256-byte
// aligned, so a GPU can alias it without a copy.
public final class RFBFramebuffer: @unchecked Sendable {
    public static let rowAlignment = 256

    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let baseAddress: UnsafeMutableRawPointer
    public let length: Int

    init(width: Int, height: Int) throws(RFBError) {
        guard width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw .protocolViolation("framebuffer size \(width)x\(height)")
        }
        let page = Int(getpagesize())
        let align = Self.rowAlignment
        bytesPerRow = (width * 4 + align - 1) / align * align
        length = (bytesPerRow * height + page - 1) / page * page
        guard let memory = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0), memory != MAP_FAILED else {
            throw .protocolViolation("cannot map \(length) byte framebuffer")
        }
        self.width = width
        self.height = height
        baseAddress = memory
    }

    deinit {
        munmap(baseAddress, length)
    }

    public var bounds: RFBRect { RFBRect(x: 0, y: 0, width: width, height: height) }

    @inline(__always)
    func row(_ y: Int, x: Int = 0) -> UnsafeMutablePointer<UInt32> {
        (baseAddress + y * bytesPerRow + x * 4).assumingMemoryBound(to: UInt32.self)
    }

    func fill(_ rect: RFBRect, _ pixel: UInt32) {
        for y in rect.y..<(rect.y + rect.height) {
            row(y, x: rect.x).update(repeating: pixel, count: rect.width)
        }
    }

    func copy(from source: RFBRect, toX x: Int, y: Int) {
        let bytes = source.width * 4
        let downward = source.y < y
        for i in 0..<source.height {
            let r = downward ? source.height - 1 - i : i
            memmove(row(y + r, x: x), row(source.y + r, x: source.x), bytes)
        }
    }

    // copyPixels copies the framebuffer into tightly packed BGRX rows.
    public func copyPixels() -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 4)
        out.withUnsafeMutableBytes { dst in
            for y in 0..<height {
                memcpy(dst.baseAddress! + y * width * 4, baseAddress + y * bytesPerRow, width * 4)
            }
        }
        return out
    }
}

extension RFBFramebuffer {
    // makeImage copies the framebuffer into a CGImage.
    public func makeImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes: baseAddress, count: bytesPerRow * height) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }
}
