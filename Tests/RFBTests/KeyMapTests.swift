import RFB
import Testing

@Suite struct KeyMapTests {
    @Test(arguments: [
        (UInt16(0x00), "a", UInt32(0x61)), (0x00, "A", 0x41), (0x12, "1", 0x31), (0x12, "!", 0x21),
        (0x31, " ", 0x20), (0x2B, ",", 0x2C), (0x0A, "§", 0xA7),
        (0x24, "\r", 0xFF0D), (0x30, "\t", 0xFF09), (0x33, "\u{7F}", 0xFF08), (0x35, "\u{1B}", 0xFF1B),
        (0x75, "\u{F728}", 0xFFFF), (0x7B, "\u{F702}", 0xFF51), (0x7E, "\u{F700}", 0xFF52),
        (0x7C, "\u{F703}", 0xFF53), (0x7D, "\u{F701}", 0xFF54), (0x73, "\u{F729}", 0xFF50), (0x77, "\u{F72B}", 0xFF57),
        (0x74, "\u{F72C}", 0xFF55), (0x79, "\u{F72D}", 0xFF56),
        (0x7A, "\u{F704}", 0xFFBE), (0x6F, "\u{F70F}", 0xFFC9), (0x5A, "\u{F717}", 0xFFD1),
        (0x38, "", 0xFFE1), (0x3C, "", 0xFFE2), (0x3B, "", 0xFFE3), (0x3A, "", 0xFFE9), (0x37, "", 0xFFEB), (0x39, "", 0xFFE5),
        (0x52, "0", 0xFFB0), (0x5C, "9", 0xFFB9), (0x4C, "\u{3}", 0xFF8D), (0x45, "+", 0xFFAB),
        (0x08, "ç", 0xE7), (0x00, "я", 0x0100_044F), (0x00, "€", 0x0100_20AC),
    ])
    func keysym(keyCode: UInt16, characters: String, expected: UInt32) {
        #expect(RFBKeyMap.keysym(keyCode: keyCode, characters: characters) == expected)
    }

    @Test func deadKeys() {
        #expect(RFBKeyMap.keysym(keyCode: 0x18, characters: "\u{B4}", deadKey: true) == 0xFE51)
        #expect(RFBKeyMap.keysym(keyCode: 0x21, characters: "^", deadKey: true) == 0xFE52)
        #expect(RFBKeyMap.keysym(keyCode: 0x2D, characters: "~", deadKey: true) == 0xFE53)
        #expect(RFBKeyMap.keysym(keyCode: 0x27, characters: "\u{A8}", deadKey: true) == 0xFE57)
        #expect(RFBKeyMap.keysym(keyCode: 0x21, characters: "^", deadKey: false) == 0x5E)
    }

    @Test func unmapped() {
        #expect(RFBKeyMap.keysym(keyCode: 0x3F, characters: nil) == nil)
        #expect(RFBKeyMap.keysym(keyCode: 0x00, characters: "\u{F746}") == nil)
    }

    @Test func scancodes() {
        #expect(RFBKeyMap.scancode(keyCode: 0x00) == 0x1E)
        #expect(RFBKeyMap.scancode(keyCode: 0x24) == 0x1C)
        #expect(RFBKeyMap.scancode(keyCode: 0x7E) == 0xC8)
        #expect(RFBKeyMap.scancode(keyCode: 0x37) == 0xDB)
        #expect(RFBKeyMap.scancode(keyCode: 0x3F) == nil)
    }

    @Test func typedText() {
        #expect("a\nZ\t".unicodeScalars.compactMap(RFBKeyMap.keysym(for:)) == [0x61, 0xFF0D, 0x5A, 0xFF09])
    }
}
