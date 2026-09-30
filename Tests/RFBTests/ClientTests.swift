import Foundation
@testable import RFB
import Synchronization
import Testing

@Suite struct ClientTests {
    func emptyUpdate() -> [UInt8] {
        var b = Bytes()
        b.u8(0); b.u8(0); b.u16(1)
        b.rect(0, 0, 1, 1, .raw); b.pixel(0)
        return b.data
    }

    @Test func requestWaitsForConsumption() async throws {
        let server = Server()
        var configuration = RFBClient.Configuration()
        configuration.requestInterval = nil
        let (client, events, task) = start(server, configuration)
        _ = await server.handshake(width: 16, height: 8)
        await server.send(emptyUpdate())
        _ = await events.update()
        #expect(await server.read(10) == [3, 1, 0, 0, 0, 0, 0, 16, 0, 8])
        await server.send(emptyUpdate())
        _ = await events.update()
        client.pointer(x: 3, y: 4, buttons: .left)
        #expect(await server.read(6) == [5, 1, 0, 3, 0, 4])
        client.framebufferConsumed()
        #expect(await server.read(10) == [3, 1, 0, 0, 0, 0, 0, 16, 0, 8])
        client.framebufferConsumed()
        client.key(0x61, down: true)
        #expect(await server.read(8) == [4, 1, 0, 0, 0, 0, 0, 0x61])
        task.cancel()
    }

    @Test func pacerRequestsWhileUpdatesFlowThenStops() async throws {
        let server = Server()
        var configuration = RFBClient.Configuration()
        configuration.requestsOnConsume = false
        configuration.requestInterval = .milliseconds(20)
        let (client, events, task) = start(server, configuration)
        _ = await server.handshake(width: 16, height: 8)
        await server.send(emptyUpdate())
        _ = await events.update()
        for _ in 0..<4 {
            #expect(await server.read(10) == [3, 1, 0, 0, 0, 0, 0, 16, 0, 8])
        }
        try await Task.sleep(for: .milliseconds(1300))
        client.key(1, down: true)
        try await Task.sleep(for: .milliseconds(100))
        client.key(2, down: true)
        var types: [UInt8] = []
        while types.filter({ $0 == 4 }).count < 2 {
            let type = await server.read(1)[0]
            _ = await server.read(type == 3 ? 9 : 7)
            types.append(type)
        }
        #expect(types.suffix(2) == [4, 4])
        task.cancel()
    }

    @Test func immediateRequests() async throws {
        let server = Server()
        var configuration = RFBClient.Configuration()
        configuration.requestsOnConsume = false
        configuration.requestInterval = nil
        let (_, events, task) = start(server, configuration)
        _ = await server.handshake(width: 16, height: 8)
        await server.send(emptyUpdate())
        _ = await events.update()
        #expect(await server.read(10) == [3, 1, 0, 0, 0, 0, 0, 16, 0, 8])
        task.cancel()
    }

    @Test func fenceIsAnsweredAndContinuousUpdatesEnabled() async throws {
        let server = Server()
        let (client, events, task) = start(server)
        let (encodings, _) = await server.handshake(width: 16, height: 8)
        #expect(encodings.contains(RFBEncoding.fence.rawValue) && encodings.contains(RFBEncoding.continuousUpdates.rawValue))
        var b = Bytes()
        b.u8(248); b.append([0, 0, 0]); b.u32(Int(Fence.request | Fence.blockBefore | 0x100)); b.u8(3); b.append([9, 8, 7])
        b.u8(150)
        await server.send(b.data)
        var reply = Bytes()
        reply.u8(248); reply.append([0, 0, 0]); reply.u32(Int(Fence.blockBefore)); reply.u8(3); reply.append([9, 8, 7])
        #expect(await server.read(12) == reply.data)
        #expect(await server.read(10) == [150, 1, 0, 0, 0, 0, 0, 16, 0, 8])
        await server.send(emptyUpdate())
        _ = await events.update()
        client.framebufferConsumed()
        client.key(1, down: false)
        #expect(await server.read(8) == [4, 0, 0, 0, 0, 0, 0, 1])
        task.cancel()
    }

    @Test func qemuKeyEventOnceOffered() async throws {
        let server = Server()
        var configuration = RFBClient.Configuration()
        configuration.requestInterval = nil
        let (client, events, task) = start(server, configuration)
        _ = await server.handshake(width: 16, height: 8)
        var b = Bytes()
        b.u8(0); b.u8(0); b.u16(2)
        b.rect(0, 0, 0, 0, .qemuExtendedKeyEvent)
        b.rect(0, 0, 1, 1, .raw); b.pixel(0)
        await server.send(b.data)
        _ = await events.update()
        _ = await server.read(10)
        client.key(0x61, down: true, scancode: 0x1E)
        #expect(await server.read(12) == [255, 0, 0, 1, 0, 0, 0, 0x61, 0, 0, 0, 0x1E])
        task.cancel()
    }

    @Test func latin1Clipboard() async throws {
        let server = Server()
        let (client, events, task) = start(server)
        _ = await server.handshake(width: 16, height: 8)
        var b = Bytes()
        b.u8(3); b.append([0, 0, 0]); b.u32(3); b.append([0x63, 0xE9, 0x21])
        await server.send(b.data)
        #expect(await events.next { if case .clipboard(let t) = $0 { t } else { nil } } == "cé!")
        client.setClipboard("ü€")
        #expect(await server.read(10) == [6, 0, 0, 0, 0, 0, 0, 2, 0xFC, 0x3F])
        task.cancel()
    }

    @Test func extendedClipboard() async throws {
        let server = Server()
        let (client, events, task) = start(server)
        _ = await server.handshake(width: 16, height: 8)
        var caps = Bytes()
        caps.u8(3); caps.append([0, 0, 0]); caps.s32(-8)
        caps.u32(Int(Clipboard.caps | Clipboard.notify | Clipboard.request | Clipboard.provide | Clipboard.text)); caps.u32(1 << 20)
        await server.send(caps.data)
        let reply = await server.read(16)
        #expect(Array(reply[0..<8]) == [6, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xF8])
        #expect(Array(reply[8..<9]) == [0x1F] && reply[11] == 1)

        var notify = Bytes()
        notify.u8(3); notify.append([0, 0, 0]); notify.s32(-4); notify.u32(Int(Clipboard.notify | Clipboard.text))
        await server.send(notify.data)
        #expect(await server.read(12) == [6, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFC, 0x02, 0, 0, 1])

        let provide = ExtendedClipboard.provide("héllo\nwörld").bytes
        await server.send([3] + provide[1...])
        #expect(await events.next { if case .clipboard(let t) = $0 { t } else { nil } } == "héllo\nwörld")

        client.setClipboard("local ✓")
        #expect(await server.read(12) == [6, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFC, 0x08, 0, 0, 1])
        var request = Bytes()
        request.u8(3); request.append([0, 0, 0]); request.s32(-4); request.u32(Int(Clipboard.request | Clipboard.text))
        await server.send(request.data)
        let header = await server.read(12)
        #expect(Array(header[8..<12]) == [0x10, 0, 0, 1])
        let length = Int(-Int32(bitPattern: UInt32(header[4]) << 24 | UInt32(header[5]) << 16 | UInt32(header[6]) << 8 | UInt32(header[7])))
        let body = await server.read(length - 4)
        #expect(try ExtendedClipboard.unpack(Data(body)) == "local ✓")
        task.cancel()
    }

    @Test func libvncserverCapsKeepLegacyCutText() async throws {
        let server = Server()
        let (client, _, task) = start(server)
        _ = await server.handshake(width: 16, height: 8)
        var caps = Bytes()
        caps.u8(3); caps.append([0, 0, 0]); caps.s32(-8); caps.append([0x17, 0, 0, 1, 0, 0x10, 0, 0])
        await server.send(caps.data)
        _ = await server.read(16)
        client.setClipboard("ok")
        #expect(await server.read(10) == [6, 0, 0, 0, 0, 0, 0, 2, 0x6F, 0x6B])
        task.cancel()
    }

    @Test func pipeAppliesBackpressure() async throws {
        let pipe = RFBPipe(bufferLimit: 8)
        let delivered = Atomic(0)
        let writer = Task {
            for _ in 0..<4 {
                await pipe.deliver(Data(repeating: 1, count: 8))
                delivered.add(1, ordering: .relaxed)
            }
            pipe.finish()
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(delivered.load(ordering: .relaxed) == 0)
        var total = 0
        while let chunk = try await pipe.receive() { total += chunk.count }
        await writer.value
        #expect(total == 32 && delivered.load(ordering: .relaxed) == 4)
    }

    @Test func closeFailsPendingReceive() async throws {
        let pipe = RFBPipe()
        let reader = Task { try await pipe.receive() }
        try await Task.sleep(for: .milliseconds(20))
        pipe.close()
        await #expect(throws: RFBError.connectionClosed) { try await reader.value }
    }

    @Test func cancellationEndsRun() async throws {
        let server = Server()
        let (_, _, task) = start(server)
        _ = await server.handshake(width: 16, height: 8)
        task.cancel()
        await #expect(throws: (any Error).self) { try await task.value }
    }
}
