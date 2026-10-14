import CoreGraphics
import Foundation
import ImageIO

enum JPEG {
    nonisolated(unsafe) private static let options = [kCGImageSourceTypeIdentifierHint: "public.jpeg", kCGImageSourceShouldCache: false] as CFDictionary
    private static let deviceRGB = CGColorSpaceCreateDeviceRGB()

    // decode draws the JPEG straight into the framebuffer rectangle.
    static func decode(_ bytes: UnsafeRawBufferPointer, into framebuffer: RFBFramebuffer, rect: RFBRect) throws {
        guard let base = bytes.baseAddress,
            let data = CFDataCreateWithBytesNoCopy(nil, base.assumingMemoryBound(to: UInt8.self), bytes.count, kCFAllocatorNull),
            let source = CGImageSourceCreateWithData(data, options),
            let image = CGImageSourceCreateImageAtIndex(source, 0, options)
        else { throw RFBError.protocolViolation("undecodable JPEG in \(rect)") }
        guard image.width == rect.width, image.height == rect.height else {
            throw RFBError.protocolViolation("JPEG \(image.width)x\(image.height) in \(rect)")
        }
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? deviceRGB
        guard
            let context = CGContext(
                data: framebuffer.row(rect.y, x: rect.x), width: rect.width, height: rect.height, bitsPerComponent: 8,
                bytesPerRow: framebuffer.bytesPerRow, space: space,
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
        else { throw RFBError.protocolViolation("JPEG context for \(rect)") }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    }
}
