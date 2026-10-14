import Foundation
import Testing

@testable import RFB

// The fixtures are the server side of real sessions (docker/, 320x200 static
// scene) recorded by rfb-bench; every lossless encoding must rebuild the
// same framebuffer as raw.
@Suite struct FixtureTests {
    @Test(arguments: ["x11vnc", "tigervnc"])
    func losslessEncodingsAgree(server: String) async throws {
        let (rawFB, _) = try await Recording(fixture: "\(server)-raw").replay()
        let reference = try #require(rawFB).copyPixels()
        for encoding in ["hextile", "zrle", "tight"] {
            let (fb, stats) = try await Recording(fixture: "\(server)-\(encoding)").replay()
            let decoded = try #require(fb)
            #expect(decoded.width == 320 && decoded.height == 200)
            #expect(stats.encodings.keys.contains { $0.description == encoding }, "\(server) \(encoding) negotiated \(stats.encodings.keys)")
            #expect(Self.differingPixels(decoded.copyPixels(), reference) == 0, "\(server) \(encoding)")
        }
    }

    @Test(arguments: ["x11vnc", "tigervnc"])
    func jpegStaysClose(server: String) async throws {
        let reference = try #require(try await Recording(fixture: "\(server)-raw").replay().0).copyPixels()
        let (fb, stats) = try await Recording(fixture: "\(server)-tight-jpeg").replay()
        let decoded = try #require(fb).copyPixels()
        #expect(stats.encodings[.tight]?.rects ?? 0 > 0)
        var error = 0
        for i in stride(from: 0, to: decoded.count, by: 4) {
            for c in 0..<3 { error += abs(Int(decoded[i + c]) - Int(reference[i + c])) }
        }
        #expect(Double(error) / Double(decoded.count / 4 * 3) < 8)
    }

    static func differingPixels(_ a: [UInt8], _ b: [UInt8]) -> Int {
        guard a.count == b.count else { return max(a.count, b.count) }
        var count = 0
        for i in stride(from: 0, to: a.count, by: 4) where a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] {
            count += 1
        }
        return count
    }
}
