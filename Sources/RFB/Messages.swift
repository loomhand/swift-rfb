import Foundation

public struct RFBEncoding: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: Int32

    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }

    public static let raw = RFBEncoding(rawValue: 0)
    public static let copyRect = RFBEncoding(rawValue: 1)
    public static let hextile = RFBEncoding(rawValue: 5)
    public static let tight = RFBEncoding(rawValue: 7)
    public static let zrle = RFBEncoding(rawValue: 16)
    public static let h264 = RFBEncoding(rawValue: 50)

    public static let cursor = RFBEncoding(rawValue: -239)
    public static let desktopSize = RFBEncoding(rawValue: -223)
    public static let lastRect = RFBEncoding(rawValue: -224)
    public static let pointerPosition = RFBEncoding(rawValue: -232)
    public static let qemuExtendedKeyEvent = RFBEncoding(rawValue: -258)
    public static let desktopName = RFBEncoding(rawValue: -307)
    public static let extendedDesktopSize = RFBEncoding(rawValue: -308)
    public static let fence = RFBEncoding(rawValue: -312)
    public static let continuousUpdates = RFBEncoding(rawValue: -313)
    public static let extendedClipboard = RFBEncoding(rawValue: Int32(bitPattern: 0xC0A1_E5CE))

    public static func jpegQuality(_ level: Int) -> RFBEncoding {
        RFBEncoding(rawValue: -32 + Int32(min(max(level, 0), 9)))
    }

    public static func compressionLevel(_ level: Int) -> RFBEncoding {
        RFBEncoding(rawValue: -256 + Int32(min(max(level, 0), 9)))
    }

    public var description: String {
        switch self {
        case .raw: "raw"
        case .copyRect: "copyrect"
        case .hextile: "hextile"
        case .tight: "tight"
        case .zrle: "zrle"
        case .h264: "h264"
        case .cursor: "cursor"
        case .desktopSize: "desktopsize"
        case .lastRect: "lastrect"
        case .pointerPosition: "pointerpos"
        case .qemuExtendedKeyEvent: "qemu-extkey"
        case .desktopName: "desktopname"
        case .extendedDesktopSize: "extdesktopsize"
        case .fence: "fence"
        case .continuousUpdates: "continuousupdates"
        case .extendedClipboard: "extclipboard"
        default: "enc\(rawValue)"
        }
    }
}

public struct RFBButtons: OptionSet, Sendable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let left = RFBButtons(rawValue: 1 << 0)
    public static let middle = RFBButtons(rawValue: 1 << 1)
    public static let right = RFBButtons(rawValue: 1 << 2)
    public static let wheelUp = RFBButtons(rawValue: 1 << 3)
    public static let wheelDown = RFBButtons(rawValue: 1 << 4)
    public static let wheelLeft = RFBButtons(rawValue: 1 << 5)
    public static let wheelRight = RFBButtons(rawValue: 1 << 6)
}

enum Fence {
    static let blockBefore: UInt32 = 1 << 0
    static let blockAfter: UInt32 = 1 << 1
    static let syncNext: UInt32 = 1 << 2
    static let request: UInt32 = 1 << 31
}

enum Clipboard {
    static let text: UInt32 = 1 << 0
    static let caps: UInt32 = 1 << 24
    static let request: UInt32 = 1 << 25
    static let peek: UInt32 = 1 << 26
    static let notify: UInt32 = 1 << 27
    static let provide: UInt32 = 1 << 28
}

// Message builds one client-to-server message.
struct Message {
    private(set) var bytes: [UInt8]

    init(type: UInt8, capacity: Int = 16) {
        bytes = []
        bytes.reserveCapacity(capacity)
        bytes.append(type)
    }

    init() {
        bytes = []
    }

    var data: Data { Data(bytes) }

    mutating func u8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(value >> 8))
        bytes.append(UInt8(value & 0xFF))
    }

    mutating func u32(_ value: UInt32) {
        u16(UInt16(value >> 16))
        u16(UInt16(value & 0xFFFF))
    }

    mutating func pad(_ count: Int) {
        bytes.append(contentsOf: repeatElement(0, count: count))
    }

    mutating func append<S: Sequence>(_ data: S) where S.Element == UInt8 {
        bytes.append(contentsOf: data)
    }

    // setPixelFormat asks for 32bpp little-endian true colour, red in bits
    // 16-23: BGRX in memory.
    static func setPixelFormat() -> Message {
        var m = Message(type: 0, capacity: 20)
        m.pad(3)
        m.append([32, 24, 0, 1])
        m.u16(255)
        m.u16(255)
        m.u16(255)
        m.append([16, 8, 0])
        m.pad(3)
        return m
    }

    static func setEncodings(_ encodings: [RFBEncoding]) -> Message {
        var m = Message(type: 2, capacity: 4 + encodings.count * 4)
        m.pad(1)
        m.u16(UInt16(encodings.count))
        for encoding in encodings {
            m.u32(UInt32(bitPattern: encoding.rawValue))
        }
        return m
    }

    static func updateRequest(incremental: Bool, _ rect: RFBRect) -> Message {
        var m = Message(type: 3, capacity: 10)
        m.u8(incremental ? 1 : 0)
        m.u16(UInt16(rect.x))
        m.u16(UInt16(rect.y))
        m.u16(UInt16(rect.width))
        m.u16(UInt16(rect.height))
        return m
    }

    static func key(_ keysym: UInt32, down: Bool) -> Message {
        var m = Message(type: 4, capacity: 8)
        m.u8(down ? 1 : 0)
        m.pad(2)
        m.u32(keysym)
        return m
    }

    static func qemuKey(_ keysym: UInt32, scancode: UInt32, down: Bool) -> Message {
        var m = Message(type: 255, capacity: 12)
        m.u8(0)
        m.u16(down ? 1 : 0)
        m.u32(keysym)
        m.u32(scancode)
        return m
    }

    static func pointer(x: Int, y: Int, buttons: RFBButtons) -> Message {
        var m = Message(type: 5, capacity: 6)
        m.u8(buttons.rawValue)
        m.u16(UInt16(clamping: max(0, x)))
        m.u16(UInt16(clamping: max(0, y)))
        return m
    }

    static func cutText(latin1 text: String) -> Message {
        let bytes = text.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : UInt8(ascii: "?") }
        var m = Message(type: 6, capacity: 8 + bytes.count)
        m.pad(3)
        m.u32(UInt32(bytes.count))
        m.append(bytes)
        return m
    }

    static func extendedCutText(flags: UInt32, payload: [UInt8]) -> Message {
        var m = Message(type: 6, capacity: 12 + payload.count)
        m.pad(3)
        m.u32(UInt32(bitPattern: -Int32(4 + payload.count)))
        m.u32(flags)
        m.append(payload)
        return m
    }

    static func enableContinuousUpdates(_ enable: Bool, _ rect: RFBRect) -> Message {
        var m = Message(type: 150, capacity: 10)
        m.u8(enable ? 1 : 0)
        m.u16(UInt16(rect.x))
        m.u16(UInt16(rect.y))
        m.u16(UInt16(rect.width))
        m.u16(UInt16(rect.height))
        return m
    }

    static func fence(flags: UInt32, payload: [UInt8]) -> Message {
        var m = Message(type: 248, capacity: 9 + payload.count)
        m.pad(3)
        m.u32(flags)
        m.u8(UInt8(payload.count))
        m.append(payload)
        return m
    }
}
