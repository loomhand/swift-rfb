import AppKit
import RFB
import RFBMetal
import Synchronization

// rfb-view HOST:PORT [--password PW] [--control] [--encodings tight,zrle,...]
//         [--jpeg 0-9|off] [--no-continuous] [--seconds N] [--exit-after-first-frame]

@MainActor
final class Viewer: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let host: String
    let port: UInt16
    let configuration: RFBClient.Configuration
    let seconds: Double?
    let exitAfterFirstFrame: Bool
    let startControl: Bool
    let started = ContinuousClock.now
    var connectStarted = ContinuousClock.now
    var window: NSWindow?
    var view: RFBView?
    var client: RFBClient?
    var session: Task<Void, Never>?
    var pasteboardCount = NSPasteboard.general.changeCount

    init(arguments: [String]) {
        var configuration = RFBClient.Configuration()
        var positional: [String] = []
        var seconds: Double?
        var exitAfterFirstFrame = false
        var control = false
        var args = arguments.makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--password": configuration.password = args.next()
            case "--control": control = true
            case "--no-continuous": configuration.continuousUpdates = false
            case "--jpeg": configuration.jpegQuality = Int(args.next() ?? "off")
            case "--seconds": seconds = Double(args.next() ?? "")
            case "--exit-after-first-frame": exitAfterFirstFrame = true
            case "--encodings":
                configuration.encodings = (args.next() ?? "").split(separator: ",").compactMap { name in
                    ["raw": RFBEncoding.raw, "copyrect": .copyRect, "hextile": .hextile, "tight": .tight, "zrle": .zrle][String(name)]
                }
            default: positional.append(arg)
            }
        }
        let target = positional.first ?? "127.0.0.1:5900"
        let colon = target.lastIndex(of: ":")
        host = colon.map { String(target[..<$0]) } ?? target
        port = colon.flatMap { UInt16(target[target.index(after: $0)...]) } ?? 5900
        self.configuration = configuration
        self.seconds = seconds
        self.exitAfterFirstFrame = exitAfterFirstFrame
        startControl = control
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        guard let view = RFBView() else {
            print("error: Metal unavailable")
            exit(1)
        }
        view.isInputEnabled = startControl
        view.onFirstFrame = { [weak self] in
            guard let self else { return }
            let now = ContinuousClock.now
            print("first_frame_ms=\(Self.ms(now - started)) since_connect_ms=\(Self.ms(now - connectStarted))")
            if exitAfterFirstFrame { NSApp.terminate(nil) }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        self.view = view
        updateTitle()
        NSApp.activate(ignoringOtherApps: true)
        connect()
        if let seconds {
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { NSApp.terminate(nil) }
        }
    }

    func connect() {
        let transport = RFBTCPTransport(host: host, port: port)
        let client = RFBClient(transport: transport, configuration: configuration)
        self.client = client
        view?.client = client
        let handler = view?.eventHandler
        let firstUpdate = Mutex(false)
        connectStarted = ContinuousClock.now
        let connectStarted = connectStarted
        session = Task { [weak self] in
            do {
                try await transport.connect()
                try await client.run { event in
                    handler?(event)
                    switch event {
                    case .connected(let info):
                        Task { @MainActor in self?.connected(info) }
                    case .clipboard(let text):
                        Task { @MainActor in self?.remoteClipboard(text) }
                    case .updated:
                        if firstUpdate.withLock({ f in defer { f = true }; return !f }) {
                            print("first_update_since_connect_ms=\(Viewer.ms(ContinuousClock.now - connectStarted))")
                        }
                    default:
                        break
                    }
                }
            } catch {
                print("disconnected: \(error)")
            }
            await MainActor.run { NSApp.terminate(nil) }
        }
    }

    func connected(_ info: RFBServerInfo) {
        print("connected_ms=\(Self.ms(ContinuousClock.now - started)) server=\"\(info.name)\" \(info.width)x\(info.height) rfb=\(info.version)")
    }

    func remoteClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        pasteboardCount = NSPasteboard.general.changeCount
    }

    func windowDidBecomeKey(_ notification: Notification) {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardCount else { return }
        pasteboardCount = pasteboard.changeCount
        if let text = pasteboard.string(forType: .string) { client?.setClipboard(text) }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.cancel()
    }

    @objc func toggleControl(_ sender: NSMenuItem) {
        view?.isInputEnabled.toggle()
        sender.state = view?.isInputEnabled == true ? .on : .off
        updateTitle()
    }

    func updateTitle() {
        window?.title = "\(host):\(port) — \(view?.isInputEnabled == true ? "control" : "view only")"
    }

    func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit rfb-view", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let control = viewMenu.addItem(withTitle: "Control", action: #selector(toggleControl(_:)), keyEquivalent: "C")
        control.keyEquivalentModifierMask = [.command, .shift]
        control.target = self
        control.state = startControl ? .on : .off
        viewItem.submenu = viewMenu
        main.addItem(viewItem)
        NSApp.mainMenu = main
    }

    nonisolated static func ms(_ d: Duration) -> String {
        String(format: "%.1f", Double(d.components.seconds) * 1e3 + Double(d.components.attoseconds) / 1e15)
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let viewer = Viewer(arguments: Array(CommandLine.arguments.dropFirst()))
app.delegate = viewer
app.run()
