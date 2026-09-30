import Foundation
import zlib

// ExtendedClipboard speaks the UTF-8 clipboard extension: caps, notify,
// request and provide for the text format only.
struct ExtendedClipboard {
    struct Outcome {
        var serverCaps: UInt32?
        var replies: [Message] = []
        var text: String?
    }

    private static let maxText: UInt32 = 16 << 20

    func receive(flags: UInt32, payload: Data, local: String?) throws -> Outcome {
        var outcome = Outcome()
        if flags & Clipboard.caps != 0 {
            outcome.serverCaps = flags
            var caps = Message()
            caps.u32(Self.maxText)
            outcome.replies.append(.extendedCutText(
                flags: Clipboard.caps | Clipboard.request | Clipboard.peek | Clipboard.notify | Clipboard.provide | Clipboard.text,
                payload: caps.bytes
            ))
            return outcome
        }
        let text = flags & Clipboard.text != 0
        if flags & Clipboard.provide != 0, text {
            outcome.text = try Self.unpack(payload)
        } else if flags & Clipboard.notify != 0, text {
            outcome.replies.append(.extendedCutText(flags: Clipboard.request | Clipboard.text, payload: []))
        } else if flags & Clipboard.request != 0, text, let local {
            outcome.replies.append(Self.provide(local))
        } else if flags & Clipboard.peek != 0 {
            outcome.replies.append(.extendedCutText(flags: Clipboard.notify | (local == nil ? 0 : Clipboard.text), payload: []))
        }
        return outcome
    }

    // provide packs text as the extension wants it: CRLF line ends, NUL
    // terminated, length-prefixed, zlib-compressed.
    static func provide(_ text: String) -> Message {
        var body = Array(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
        body.append(0)
        var plain = Message()
        plain.u32(UInt32(body.count))
        plain.append(body)
        var packed = [UInt8](repeating: 0, count: Int(compressBound(uLong(plain.bytes.count))))
        var packedLength = uLongf(packed.count)
        _ = compress(&packed, &packedLength, plain.bytes, uLong(plain.bytes.count))
        return .extendedCutText(flags: Clipboard.provide | Clipboard.text, payload: Array(packed.prefix(Int(packedLength))))
    }

    static func unpack(_ payload: Data) throws -> String {
        let inflater = try Inflater()
        var scratch = Scratch(capacity: max(4096, payload.count * 4))
        let produced = try payload.withUnsafeBytes { try inflater.inflate($0, into: &scratch) }
        guard produced >= 4 else { throw RFBError.protocolViolation("clipboard provide of \(produced) bytes") }
        let bytes = UnsafeRawBufferPointer(start: scratch.base, count: produced)
        let length = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        guard length <= produced - 4 else { throw RFBError.protocolViolation("clipboard text of \(length) bytes") }
        var text = bytes[4..<(4 + length)]
        if text.last == 0 { text = text.dropLast() }
        return String(decoding: text, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
    }
}
