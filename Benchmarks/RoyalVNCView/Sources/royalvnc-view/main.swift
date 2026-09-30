import AppKit
import RoyalVNCKit

// royalvnc-view HOST:PORT [--encodings tight,zrle,...] [--seconds N] [--exit-after-first-frame]

final class Viewer: NSObject, NSApplicationDelegate, VNCConnectionDelegate {
    var connection: VNCConnection!
    var window: NSWindow!
    var view: VNCCAFramebufferView?
    var seconds: Double?
    var exitAfterFirstFrame = false
    var firstUpdate = false
    let started = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        var positional: [String] = []
        var encodings: [VNCFrameEncodingType] = [.tight, .zrle, .zlib, .hextile]
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--seconds": seconds = Double(args.next() ?? "")
            case "--exit-after-first-frame": exitAfterFirstFrame = true
            case "--encodings":
                let map: [String: VNCFrameEncodingType] = ["tight": .tight, "zrle": .zrle, "zlib": .zlib, "hextile": .hextile, "raw": .raw]
                encodings = (args.next() ?? "").split(separator: ",").compactMap { map[String($0)] }
            default: positional.append(arg)
            }
        }
        let target = positional.first ?? "127.0.0.1:5900"
        let colon = target.lastIndex(of: ":")!
        let settings = VNCConnection.Settings(
            isDebugLoggingEnabled: false, hostname: String(target[..<colon]), port: UInt16(target[target.index(after: colon)...])!,
            isShared: true, isScalingEnabled: true, useDisplayLink: false, inputMode: .forwardKeyboardShortcutsIfNotInUseLocally,
            isClipboardRedirectionEnabled: false, colorDepth: .depth24Bit, frameEncodings: encodings
        )
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "royalvnc-view \(target)"
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        connection = VNCConnection(settings: settings)
        connection.delegate = self
        connection.connect()
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    func connection(_ connection: VNCConnection, stateDidChange connectionState: VNCConnection.ConnectionState) {
        if case .disconnected = connectionState.status {
            print("disconnected: \(String(describing: connectionState.error))")
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    func connection(_ connection: VNCConnection, credentialFor authenticationType: VNCAuthenticationType, completion: @escaping (VNCCredential?) -> Void) {
        completion(nil)
    }

    func connection(_ connection: VNCConnection, didCreateFramebuffer framebuffer: VNCFramebuffer) {
        DispatchQueue.main.async { [self] in
            let view = VNCCAFramebufferView(frame: window.contentView!.bounds, framebuffer: framebuffer, connection: connection, connectionDelegate: self)
            view.autoresizingMask = [.width, .height]
            window.contentView = view
            self.view = view
            connection.delegate = self
        }
    }

    func connection(_ connection: VNCConnection, didResizeFramebuffer framebuffer: VNCFramebuffer) {}

    // The view takes over the connection delegate; this viewer takes it back
    // and forwards, to time the first update the view renders.
    func connection(_ connection: VNCConnection, didUpdateFramebuffer framebuffer: VNCFramebuffer, x: UInt16, y: UInt16, width: UInt16, height: UInt16) {
        guard let view else { return }
        view.connection(connection, didUpdateFramebuffer: framebuffer, x: x, y: y, width: width, height: height)
        guard !firstUpdate else { return }
        firstUpdate = true
        DispatchQueue.main.async { [self] in
            print(String(format: "first_frame_ms=%.1f", Date().timeIntervalSince(started) * 1000))
            if exitAfterFirstFrame { NSApp.terminate(nil) }
        }
    }

    func connection(_ connection: VNCConnection, didUpdateCursor cursor: VNCCursor) {
        view?.connection(connection, didUpdateCursor: cursor)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let viewer = Viewer()
app.delegate = viewer
app.run()
