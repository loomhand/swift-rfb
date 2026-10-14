import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import RFB

// Each test encodes known pixels the way a server would, feeds them through
// the client and compares the framebuffer.
@Suite struct DecoderTests {
    let width = 128
    let height = 100

    func connect() async -> (Server, RFBClient, Events, Task<Void, any Error>) {
        let server = Server()
        var configuration = RFBClient.Configuration()
        configuration.requestsOnConsume = false
        let (client, events, task) = start(server, configuration)
        _ = await server.handshake(width: width, height: height)
        return (server, client, events, task)
    }

    func update(_ count: Int, _ body: [UInt8]) -> [UInt8] {
        var b = Bytes()
        b.u8(0); b.u8(0); b.u16(count)
        return b.data + body
    }

    @Test func raw() async throws {
        let (server, _, events, task) = await connect()
        let image = pattern(50, 30)
        var b = Bytes()
        b.rect(10, 20, 50, 30, .raw)
        image.forEach { b.pixel($0) }
        await server.send(update(1, b.data))
        let (fb, dirty) = try #require(await events.update())
        #expect(dirty == RFBRect(x: 10, y: 20, width: 50, height: 30))
        #expect(pixels(fb, dirty) == image)
        task.cancel()
    }

    @Test func copyRectOverlapping() async throws {
        let (server, _, events, task) = await connect()
        let image = pattern(width, height)
        var b = Bytes()
        b.rect(0, 0, width, height, .raw)
        image.forEach { b.pixel($0) }
        b.rect(5, 7, 40, 30, .copyRect); b.u16(0); b.u16(0)
        b.rect(60, 0, 40, 30, .copyRect); b.u16(66); b.u16(9)
        await server.send(update(3, b.data))
        let (fb, _) = try #require(await events.update())
        var expected = image
        for (src, dst) in [((0, 0), (5, 7)), ((66, 9), (60, 0))] {
            let copy = expected
            for y in 0..<30 {
                for x in 0..<40 {
                    let d = (dst.1 + y) * width + dst.0 + x
                    expected[d] = copy[(src.1 + y) * width + src.0 + x]
                }
            }
        }
        #expect(pixels(fb, fb.bounds) == expected)
        task.cancel()
    }

    @Test func hextile() async throws {
        let (server, _, events, task) = await connect()
        var b = Bytes()
        b.rect(0, 0, 40, 20, .hextile)
        let rawTile = pattern(16, 16, seed: 9)
        b.u8(1)
        rawTile.forEach { b.pixel($0) }
        b.u8(2 | 4 | 8); b.pixel(0x112233); b.pixel(0xAABBCC); b.u8(2)
        b.u8(0x12); b.u8(0x21)
        b.u8(0xF0); b.u8(0x0F)
        b.u8(8 | 16); b.u8(1); b.pixel(0x00FF00); b.u8(0x00); b.u8(0x33)
        b.u8(0)
        b.u8(2); b.pixel(0x445566)
        b.u8(0)
        await server.send(update(1, b.data))
        let (fb, _) = try #require(await events.update())
        var expected = [UInt32](repeating: 0x112233, count: 40 * 20)
        for y in 0..<16 { for x in 0..<16 { expected[y * 40 + x] = rawTile[y * 16 + x] } }
        for y in 2..<4 { for x in 17..<20 { expected[y * 40 + x] = 0xAABBCC } }
        for y in 0..<16 { expected[y * 40 + 31] = 0xAABBCC }
        for y in 0..<4 { for x in 32..<36 { expected[y * 40 + x] = 0x00FF00 } }
        for y in 16..<20 { for x in 0..<16 { expected[y * 40 + x] = 0x112233 } }
        for y in 16..<20 { for x in 16..<32 { expected[y * 40 + x] = 0x445566 } }
        for y in 16..<20 { for x in 32..<40 { expected[y * 40 + x] = 0x445566 } }
        #expect(pixels(fb, RFBRect(x: 0, y: 0, width: 40, height: 20)) == expected)
        task.cancel()
    }

    enum ZRLETile { case raw, solid, packed, plainRLE, paletteRLE }

    static func zrleTile(_ px: [UInt32], _ w: Int, _ h: Int, _ kind: ZRLETile) -> [UInt8] {
        var b = Bytes()
        let palette = Array(Set(px)).sorted()
        switch kind {
        case .raw:
            b.u8(0); px.forEach { b.cpixel($0) }
        case .solid:
            b.u8(1); b.cpixel(px[0])
        case .packed:
            b.u8(palette.count); palette.forEach { b.cpixel($0) }
            let bits = palette.count == 2 ? 1 : palette.count <= 4 ? 2 : 4
            for y in 0..<h {
                var byte = 0, used = 0
                for x in 0..<w {
                    byte = byte << bits | palette.firstIndex(of: px[y * w + x])!
                    used += bits
                    if used == 8 { b.u8(byte); byte = 0; used = 0 }
                }
                if used > 0 { b.u8(byte << (8 - used)) }
            }
        case .plainRLE, .paletteRLE:
            b.u8(kind == .plainRLE ? 128 : 128 + palette.count)
            if kind == .paletteRLE { palette.forEach { b.cpixel($0) } }
            var i = 0
            while i < px.count {
                var run = 1
                while i + run < px.count, px[i + run] == px[i] { run += 1 }
                if kind == .plainRLE {
                    b.cpixel(px[i])
                } else {
                    b.u8(palette.firstIndex(of: px[i])! | (run > 1 ? 0x80 : 0))
                }
                if kind == .plainRLE || run > 1 {
                    var left = run - 1
                    while left >= 255 { b.u8(255); left -= 255 }
                    b.u8(left)
                }
                i += run
            }
        }
        return b.data
    }

    @Test func zrleAllSubencodings() async throws {
        let (server, _, events, task) = await connect()
        let deflater = Deflater()
        let rw = 100, rh = 70
        var image = pattern(rw, rh)
        func tile(_ tx: Int, _ ty: Int, _ fill: (Int, Int) -> UInt32) {
            for y in ty..<min(ty + 64, rh) { for x in tx..<min(tx + 64, rw) { image[y * rw + x] = fill(x, y) } }
        }
        tile(64, 0) { _, _ in 0x123456 }
        tile(0, 64) { x, _ in [0x0000FF, 0x00FF00, 0xFF0000][x % 3] }
        tile(64, 64) { x, y in (x / 7 + y) % 2 == 0 ? 0x010203 : 0x0A0B0C }
        let kinds: [ZRLETile] = [.raw, .solid, .packed, .plainRLE]
        var plain: [UInt8] = []
        var index = 0
        for ty in stride(from: 0, to: rh, by: 64) {
            for tx in stride(from: 0, to: rw, by: 64) {
                let w = min(64, rw - tx), h = min(64, rh - ty)
                var px: [UInt32] = []
                for y in ty..<(ty + h) { for x in tx..<(tx + w) { px.append(image[y * rw + x]) } }
                plain += Self.zrleTile(px, w, h, kinds[index])
                index += 1
            }
        }
        var second: [UInt32] = []
        for y in 0..<20 { for x in 0..<30 { second.append([0x111111, 0x222222, 0x333333, 0x444444, 0x555555][(x / 4 + y / 3) % 5]) } }
        let packed2: [UInt32] = (0..<(12 * 5)).map { (i: Int) -> UInt32 in i % 12 < 5 ? 0xFFFFFF : 0x000001 }
        let packed16: [UInt32] = (0..<(20 * 4)).map { (i: Int) -> UInt32 in UInt32(0x100000 * (i % 16)) }
        var b = Bytes()
        for (rect, px, kind) in [
            ((0, 0, rw, rh), image, ZRLETile?.none),
            ((0, 72, 30, 20), second, .paletteRLE),
            ((40, 72, 12, 5), packed2, .packed),
            ((60, 72, 20, 4), packed16, .packed),
        ] {
            let data = deflater.compress(kind.map { Self.zrleTile(px, rect.2, rect.3, $0) } ?? plain)
            b.rect(rect.0, rect.1, rect.2, rect.3, .zrle); b.u32(data.count); b.append(data)
        }
        await server.send(update(4, b.data))
        let (fb, _) = try #require(await events.update())
        #expect(pixels(fb, RFBRect(x: 0, y: 0, width: rw, height: rh)) == image)
        #expect(pixels(fb, RFBRect(x: 0, y: 72, width: 30, height: 20)) == second)
        #expect(pixels(fb, RFBRect(x: 40, y: 72, width: 12, height: 5)) == packed2)
        #expect(pixels(fb, RFBRect(x: 60, y: 72, width: 20, height: 4)) == packed16)
        task.cancel()
    }

    static func gradient(_ px: [UInt32], _ w: Int, _ h: Int) -> [UInt8] {
        var out: [UInt8] = []
        func c(_ x: Int, _ y: Int, _ ch: Int) -> Int {
            guard x >= 0, y >= 0 else { return 0 }
            return Int(px[y * w + x] >> UInt32(16 - ch * 8) & 0xFF)
        }
        for y in 0..<h {
            for x in 0..<w {
                for ch in 0..<3 {
                    let estimate = min(max(c(x - 1, y, ch) + c(x, y - 1, ch) - c(x - 1, y - 1, ch), 0), 255)
                    out.append(UInt8((c(x, y, ch) - estimate) & 0xFF))
                }
            }
        }
        return out
    }

    @Test func tightAllModes() async throws {
        let (server, _, events, task) = await connect()
        var streams = [Deflater(), Deflater(), Deflater(), Deflater()]
        var b = Bytes()
        var checks: [(RFBRect, [UInt32])] = []
        func add(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ px: [UInt32], _ body: [UInt8]) {
            b.rect(x, y, w, h, .tight); b.append(body)
            checks.append((RFBRect(x: x, y: y, width: w, height: h), px))
        }
        func compressed(_ stream: Int, _ data: [UInt8]) -> [UInt8] {
            var d = Bytes()
            if data.count < 12 { return data }
            let z = streams[stream].compress(data)
            d.compact(z.count); d.append(z)
            return d.data
        }

        var fill = Bytes(); fill.u8(0x80); fill.tpixel(0x345678)
        add(0, 0, 10, 10, [UInt32](repeating: 0x345678, count: 100), fill.data)

        let copy = pattern(60, 40, seed: 4)
        var copyBody = Bytes(); copyBody.u8(0x00)
        var tp = Bytes(); copy.forEach { tp.tpixel($0) }
        copyBody.append(compressed(0, tp.data))
        add(10, 0, 60, 40, copy, copyBody.data)

        let tiny = [UInt32](arrayLiteral: 0x010101, 0x020202, 0x030303)
        var tinyBody = Bytes(); tinyBody.u8(0x10)
        var tt = Bytes(); tiny.forEach { tt.tpixel($0) }
        tinyBody.append(tt.data)
        add(0, 12, 3, 1, tiny, tinyBody.data)

        let mono: [UInt32] = (0..<(21 * 9)).map { (i: Int) -> UInt32 in (i % 21) % 3 == 0 ? 0xFF00FF : 0x00FF00 }
        var monoBody = Bytes(); monoBody.u8(0x40 | 0x10); monoBody.u8(1); monoBody.u8(1); monoBody.tpixel(0x00FF00); monoBody.tpixel(0xFF00FF)
        var bits: [UInt8] = []
        for y in 0..<9 {
            var byte = 0
            for x in 0..<21 {
                byte = byte << 1 | (mono[y * 21 + x] == 0xFF00FF ? 1 : 0)
                if x % 8 == 7 { bits.append(UInt8(byte)); byte = 0 }
            }
            bits.append(UInt8(byte << 3))
        }
        monoBody.append(compressed(1, bits))
        add(70, 0, 21, 9, mono, monoBody.data)

        let colours: [UInt32] = [0x100000, 0x200000, 0x300000, 0x400000, 0x500000]
        let indexed: [UInt32] = (0..<(30 * 20)).map { (i: Int) -> UInt32 in colours[(i / 7) % 5] }
        var indexedBody = Bytes(); indexedBody.u8(0x40 | 0x20); indexedBody.u8(1); indexedBody.u8(4)
        colours.forEach { indexedBody.tpixel($0) }
        indexedBody.append(compressed(2, indexed.map { UInt8(colours.firstIndex(of: $0)!) }))
        add(0, 40, 30, 20, indexed, indexedBody.data)

        let smooth: [UInt32] = (0..<(40 * 30)).map { (i: Int) -> UInt32 in
            let r = UInt32((i % 40) * 6), g = UInt32((i / 40) * 8), b = UInt32(200 - i % 40)
            return r << 16 | g << 8 | b
        }
        var gradientBody = Bytes(); gradientBody.u8(0x40 | 0x30); gradientBody.u8(2)
        gradientBody.append(compressed(3, Self.gradient(smooth, 40, 30)))
        add(40, 40, 40, 30, smooth, gradientBody.data)

        let copy2 = pattern(20, 10, seed: 11)
        var resetBody = Bytes(); resetBody.u8(0x01)
        streams[0] = Deflater()
        var tp2 = Bytes(); copy2.forEach { tp2.tpixel($0) }
        resetBody.append(compressed(0, tp2.data))
        add(90, 40, 20, 10, copy2, resetBody.data)

        await server.send(update(checks.count, b.data))
        let (fb, _) = try #require(await events.update())
        for (rect, expected) in checks {
            #expect(pixels(fb, rect) == expected, "rect \(rect)")
        }
        task.cancel()
    }

    @Test func tightJPEG() async throws {
        let (server, _, events, task) = await connect()
        let w = 64, h = 32
        let image: [UInt32] = (0..<(w * h)).map { (i: Int) -> UInt32 in
            let r = UInt32((i % w) * 4), g = UInt32((i / w) * 8)
            return r << 16 | g << 8 | 0x40
        }
        let jpeg = try #require(Self.jpeg(image, w, h))
        var b = Bytes()
        b.rect(8, 8, w, h, .tight); b.u8(0x90); b.compact(jpeg.count); b.append(jpeg)
        await server.send(update(1, b.data))
        let (fb, _) = try #require(await events.update())
        let got = pixels(fb, RFBRect(x: 8, y: 8, width: w, height: h))
        var total = 0
        for (a, e) in zip(got, image) {
            for shift in [0, 8, 16] {
                total += abs(Int(a >> UInt32(shift) & 0xFF) - Int(e >> UInt32(shift) & 0xFF))
            }
        }
        let error = total / (w * h * 3)
        #expect(error < 6)
        task.cancel()
    }

    static func jpeg(_ px: [UInt32], _ w: Int, _ h: Int) -> [UInt8]? {
        var bytes = px
        let data = NSMutableData()
        guard
            let context = CGContext(
                data: &bytes, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            let image = context.makeImage(),
            let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return Array(data as Data)
    }

    @Test func richCursorAndPseudoRects() async throws {
        let (server, _, events, task) = await connect()
        var b = Bytes()
        b.rect(1, 2, 3, 2, .cursor)
        for i in 0..<6 { b.pixel(UInt32(0x102030 * (i + 1))) }
        b.u8(0b1010_0000); b.u8(0b0100_0000)
        b.rect(33, 44, 0, 0, .pointerPosition)
        b.rect(0, 0, 0, 0, .desktopName); b.u32(4); b.string("desk")
        b.rect(0, 0, 0, 0, .lastRect)
        await server.send(update(0xFFFF, b.data))
        let cursor = try #require(await events.next { if case .cursor(let c) = $0 { c } else { nil } })
        #expect(cursor.width == 3 && cursor.height == 2 && cursor.hotspotX == 1 && cursor.hotspotY == 2)
        #expect(cursor.pixels.enumerated().filter { $0.offset % 4 == 3 }.map(\.element) == [255, 0, 255, 0, 255, 0])
        #expect(Array(cursor.pixels[0..<3]) == [0x30, 0x20, 0x10])
        let pointer = await events.next { if case .pointer(let x, let y) = $0 { (x, y) } else { nil } }
        #expect(pointer?.0 == 33 && pointer?.1 == 44)
        #expect(await events.next { if case .desktopName(let n) = $0 { n } else { nil } } == "desk")
        task.cancel()
    }

    @Test func desktopResize() async throws {
        let (server, _, events, task) = await connect()
        _ = await events.next { if case .resized = $0 { true } else { nil } }
        var b = Bytes()
        b.rect(0, 0, 200, 100, .desktopSize)
        b.rect(0, 0, 4, 1, .raw); (0..<4).forEach { b.pixel(UInt32($0)) }
        await server.send(update(2, b.data))
        let fb = try #require(await events.next { if case .resized(let f) = $0 { f } else { nil } })
        #expect(fb.width == 200 && fb.height == 100 && fb.bytesPerRow % RFBFramebuffer.rowAlignment == 0)
        #expect(await server.read(10) == [3, 0, 0, 0, 0, 0, 0, 200, 0, 100])
        task.cancel()
    }

    @Test func emptyZRLERectKeepsStreamAligned() async throws {
        let (server, _, events, task) = await connect()
        let deflater = Deflater()
        var b = Bytes()
        let empty = deflater.compress([])
        b.rect(0, 0, 0, 0, .zrle); b.u32(empty.count); b.append(empty)
        let solid = deflater.compress([1, 0x11, 0x22, 0x33])
        b.rect(2, 2, 3, 3, .zrle); b.u32(solid.count); b.append(solid)
        await server.send(update(2, b.data))
        let (fb, _) = try #require(await events.update())
        #expect(pixels(fb, RFBRect(x: 2, y: 2, width: 3, height: 3)) == [UInt32](repeating: 0x332211, count: 9))
        task.cancel()
    }

    @Test func zlibStreamEndWithTrailingBytesTerminates() async throws {
        let (server, _, events, task) = await connect()
        var finished = Array(try #require(Data(base64Encoded: "eJxjZGRiBgAAEgAI")))
        finished += [0xAB, 0xCD]
        var b = Bytes()
        b.rect(0, 0, 1, 1, .zrle); b.u32(finished.count); b.append(finished)
        await server.send(update(1, b.data))
        let (fb, _) = try #require(await events.update())
        #expect(pixels(fb, RFBRect(x: 0, y: 0, width: 1, height: 1)) == [0x030201])
        task.cancel()
    }

    @Test func minimumCutTextLengthIsRejected() async throws {
        let (server, _, _, task) = await connect()
        var b = Bytes()
        b.u8(3); b.append([0, 0, 0]); b.u32(0x8000_0000); b.u32(Int(Clipboard.provide | Clipboard.text))
        await server.send(b.data)
        await #expect(throws: RFBError.self) { try await task.value }
    }

    @Test func rectOutsideFramebufferIsRejected() async throws {
        let (server, _, _, task) = await connect()
        var b = Bytes()
        b.rect(120, 0, 16, 1, .raw)
        await server.send(update(1, b.data))
        await #expect(throws: RFBError.self) { try await task.value }
    }
}
