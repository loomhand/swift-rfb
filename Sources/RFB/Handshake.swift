import CommonCrypto
import Foundation

public struct RFBServerInfo: Sendable, Equatable {
    public var version: String
    public var security: UInt8
    public var name: String
    public var width: Int
    public var height: Int
}

enum Handshake {
    static let securityNone: UInt8 = 1
    static let securityVNC: UInt8 = 2

    // negotiate runs version, security and init, and returns the server's
    // announcement; the reader is positioned at the first server message.
    static func negotiate(_ reader: Reader, transport: any RFBTransport, password: String?, shared: Bool) async throws -> RFBServerInfo {
        try await reader.need(12)
        let banner = String(decoding: reader.bytes(12), as: UTF8.self)
        let minor = try minorVersion(banner)
        transport.send(Data(String(format: "RFB 003.%03d\n", minor).utf8))

        let security = try await chooseSecurity(reader, transport: transport, minor: minor, password: password)
        if security == securityVNC {
            guard let password else { throw RFBError.passwordRequired }
            try await reader.need(16)
            let challenge = Array(reader.bytes(16))
            transport.send(Data(try vncResponse(challenge: challenge, password: password)))
        }
        if security == securityVNC || minor >= 8 {
            let result = try await reader.readU32()
            if result != 0 {
                throw RFBError.authenticationFailed(minor >= 8 ? try await reason(reader) : "security result \(result)")
            }
        }

        transport.send(Data([shared ? 1 : 0]))
        try await reader.need(24)
        let width = Int(reader.u16())
        let height = Int(reader.u16())
        _ = reader.bytes(16)
        let nameLength = Int(reader.u32())
        let name = try await reader.readString(nameLength)
        return RFBServerInfo(version: "3.\(minor)", security: security, name: name, width: width, height: height)
    }

    static func minorVersion(_ banner: String) throws -> Int {
        let parts = banner.dropFirst(4).dropLast().split(separator: ".")
        guard banner.hasPrefix("RFB "), banner.hasSuffix("\n"), parts.count == 2,
              let major = Int(parts[0]), let minor = Int(parts[1]), major >= 3
        else { throw RFBError.unsupportedVersion(banner) }
        if major > 3 || minor >= 8 { return 8 }
        if minor == 7 { return 7 }
        return 3
    }

    private static func chooseSecurity(_ reader: Reader, transport: any RFBTransport, minor: Int, password: String?) async throws -> UInt8 {
        if minor == 3 {
            let type = try await reader.readU32()
            if type == 0 { throw RFBError.serverRefused(try await reason(reader)) }
            guard type == UInt32(securityNone) || type == UInt32(securityVNC) else {
                throw RFBError.unsupportedSecurity([UInt8(truncatingIfNeeded: type)])
            }
            return UInt8(type)
        }
        let count = Int(try await reader.readU8())
        if count == 0 { throw RFBError.serverRefused(try await reason(reader)) }
        try await reader.need(count)
        let offered = Array(reader.bytes(count))
        let choice: UInt8
        if offered.contains(securityVNC), password != nil {
            choice = securityVNC
        } else if offered.contains(securityNone) {
            choice = securityNone
        } else if offered.contains(securityVNC) {
            throw RFBError.passwordRequired
        } else {
            throw RFBError.unsupportedSecurity(offered)
        }
        transport.send(Data([choice]))
        return choice
    }

    private static func reason(_ reader: Reader) async throws -> String {
        let length = Int(try await reader.readU32())
        return try await reader.readString(length)
    }

    // vncResponse encrypts the challenge with DES keyed by the password,
    // each key byte bit-reversed as VNC Authentication requires.
    static func vncResponse(challenge: [UInt8], password: String) throws -> [UInt8] {
        var key = [UInt8](repeating: 0, count: kCCKeySizeDES)
        for (i, byte) in password.utf8.prefix(8).enumerated() {
            var reversed: UInt8 = 0
            for bit in 0..<8 where byte & (1 << bit) != 0 {
                reversed |= 0x80 >> bit
            }
            key[i] = reversed
        }
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmDES), CCOptions(kCCOptionECBMode),
                             key, kCCKeySizeDES, nil, challenge, 16, &out, 16, &moved)
        guard status == kCCSuccess, moved == 16 else { throw RFBError.authenticationFailed("DES status \(status)") }
        return out
    }
}
