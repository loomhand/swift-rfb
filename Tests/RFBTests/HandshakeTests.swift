import Foundation
@testable import RFB
import Testing

@Suite struct HandshakeTests {
    @Test(arguments: [
        ("RFB 003.008\n", 8), ("RFB 003.007\n", 7), ("RFB 003.003\n", 3), ("RFB 003.005\n", 3),
        ("RFB 003.889\n", 8), ("RFB 004.001\n", 8),
    ])
    func version(banner: String, minor: Int) throws {
        #expect(try Handshake.minorVersion(banner) == minor)
    }

    @Test(arguments: ["RFB 002.000\n", "HTTP/1.1 200", "RFB 003.00x\n"])
    func badVersion(banner: String) {
        #expect(throws: RFBError.self) { try Handshake.minorVersion(banner) }
    }

    @Test func vncAuthenticationResponse() throws {
        let response = try Handshake.vncResponse(challenge: Array(0..<16), password: "secret")
        #expect(response.map { String(format: "%02x", $0) }.joined() == "ee22539f33a5983ec12f9c2edbc995dd")
    }

    @Test func rfb38None() async throws {
        let server = Server()
        let (_, events, task) = start(server)
        let (encodings, request) = await server.handshake(width: 64, height: 32, name: "desk")
        #expect(encodings.contains(RFBEncoding.tight.rawValue))
        #expect(encodings.contains(RFBEncoding.extendedClipboard.rawValue))
        #expect(request == [3, 0, 0, 0, 0, 0, 0, 64, 0, 32])
        let info = await events.next { if case .connected(let i) = $0 { i } else { nil } }
        #expect(info == RFBServerInfo(version: "3.8", security: 1, name: "desk", width: 64, height: 32))
        task.cancel()
    }

    @Test func rfb38VNCAuthentication() async throws {
        let server = Server()
        var configuration = RFBClient.Configuration()
        configuration.password = "secret"
        let (_, events, task) = start(server, configuration)
        await server.send(Array("RFB 003.008\n".utf8))
        #expect(await server.read(12) == Array("RFB 003.008\n".utf8))
        await server.send([2, 1, 2])
        #expect(await server.read(1) == [2])
        await server.send(Array(0..<16))
        #expect(await server.read(16) == (try Handshake.vncResponse(challenge: Array(0..<16), password: "secret")))
        await server.send([0, 0, 0, 0])
        #expect(await server.read(1) == [1])
        await server.send(Bytes.serverInit(width: 8, height: 8, name: "x"))
        let security = await events.next { (e: RFBEvent) -> UInt8? in if case .connected(let i) = e { i.security } else { nil } }
        #expect(security == 2)
        task.cancel()
    }

    @Test func rfb37NoSecurityResult() async throws {
        let server = Server()
        let (_, events, task) = start(server)
        await server.send(Array("RFB 003.007\n".utf8))
        #expect(await server.read(12) == Array("RFB 003.007\n".utf8))
        await server.send([1, 1])
        #expect(await server.read(2) == [1, 1])
        await server.send(Bytes.serverInit(width: 8, height: 8, name: "x"))
        #expect(await events.next { if case .connected(let i) = $0 { i.version } else { nil } } == "3.7")
        task.cancel()
    }

    @Test func rfb33ServerChoosesSecurity() async throws {
        let server = Server()
        let (_, events, task) = start(server)
        await server.send(Array("RFB 003.003\n".utf8))
        #expect(await server.read(12) == Array("RFB 003.003\n".utf8))
        await server.send([0, 0, 0, 1])
        #expect(await server.read(1) == [1])
        await server.send(Bytes.serverInit(width: 8, height: 8, name: "x"))
        #expect(await events.next { if case .connected(let i) = $0 { i.version } else { nil } } == "3.3")
        task.cancel()
    }

    @Test func authenticationFailureCarriesReason() async throws {
        let server = Server()
        var configuration = RFBClient.Configuration()
        configuration.password = "nope"
        let (_, _, task) = start(server, configuration)
        await server.send(Array("RFB 003.008\n".utf8) + [1, 2])
        _ = await server.read(13)
        await server.send(Array(repeating: 7, count: 16))
        _ = await server.read(16)
        var b = Bytes()
        b.u32(1); b.u32(8); b.string("bad pass")
        await server.send(b.data)
        await #expect(throws: RFBError.authenticationFailed("bad pass")) { try await task.value }
    }

    @Test func passwordRequired() async throws {
        let server = Server()
        let (_, _, task) = start(server)
        await server.send(Array("RFB 003.008\n".utf8) + [1, 2])
        await #expect(throws: RFBError.passwordRequired) { try await task.value }
    }

    @Test func unsupportedSecurity() async throws {
        let server = Server()
        let (_, _, task) = start(server)
        await server.send(Array("RFB 003.008\n".utf8) + [2, 18, 30])
        await #expect(throws: RFBError.unsupportedSecurity([18, 30])) { try await task.value }
    }

    @Test func serverRefusal() async throws {
        let server = Server()
        let (_, _, task) = start(server)
        var b = Bytes()
        b.string("RFB 003.008\n"); b.u8(0); b.u32(4); b.string("busy")
        await server.send(b.data)
        await #expect(throws: RFBError.serverRefused("busy")) { try await task.value }
    }
}
