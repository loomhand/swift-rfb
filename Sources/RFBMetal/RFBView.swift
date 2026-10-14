#if os(macOS)
import AppKit
import Metal
import QuartzCore
import RFB
import Synchronization

// RFBView shows an RFB session: pass eventHandler to RFBClient.run and set
// client, which carries input and the consumption that paces updates. It
// draws on the display link only after a change and asks for the next
// update once the GPU has consumed the frame.
@MainActor
public final class RFBView: NSView {
    public var client: RFBClient?
    public var onFirstFrame: (@MainActor () -> Void)?
    // onInput runs when the view sends a key or button press; onPresent
    // runs, off the main thread, when each drawn frame reaches the display.
    public var onInput: (@MainActor () -> Void)?
    public var onPresent: (@Sendable () -> Void)?
    public private(set) var framebufferSize = CGSize.zero

    // isInputEnabled forwards pointer and keyboard to the server; while
    // off, the remote cursor is drawn at the server's pointer position.
    public var isInputEnabled = false {
        didSet {
            guard isInputEnabled != oldValue else { return }
            if isInputEnabled {
                window?.makeFirstResponder(self)
            } else {
                releaseInput()
            }
            window?.invalidateCursorRects(for: self)
            requestDraw()
        }
    }

    private struct Scene {
        var surface: RFBRenderer.Surface?
        var cursor: RFBRenderer.CursorImage?
        var pointer: (x: Int, y: Int)?
    }

    private let renderer: RFBRenderer
    private let metalLayer = CAMetalLayer()
    private nonisolated let scene = Mutex(Scene())
    private nonisolated let dirty = Atomic(false)
    private nonisolated let hasContent = Atomic(false)
    private var link: CADisplayLink?
    private var presentedFirst = false
    private var remoteCursor: RFBCursor?
    private var systemCursor: NSCursor?
    private var buttons: RFBButtons = []
    private var pressed: [UInt16: UInt32] = [:]
    private var scroll = CGPoint.zero
    private var trackingArea: NSTrackingArea?
    private var observers: [any NSObjectProtocol] = []

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let renderer = RFBRenderer(device: device) else { return nil }
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.isOpaque = true
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        metalLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        metalLayer.isHidden = true
        layer?.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    // eventHandler feeds client events to the view from any thread.
    public nonisolated var eventHandler: @Sendable (RFBEvent) -> Void {
        { [self] in handle($0) }
    }

    public nonisolated func handle(_ event: RFBEvent) {
        switch event {
        case .connected:
            hasContent.store(false, ordering: .relaxed)
            DispatchQueue.main.async { [weak self] in
                self?.presentedFirst = false
            }
        case .resized(let framebuffer):
            let surface = renderer.makeSurface(framebuffer)
            scene.withLock { $0.surface = surface }
            dirty.store(true, ordering: .releasing)
            let size = CGSize(width: framebuffer.width, height: framebuffer.height)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                framebufferSize = size
                needsLayout = true
                wake()
            }
        case .updated:
            hasContent.store(true, ordering: .relaxed)
            markDirty()
        case .cursor(let cursor):
            let image = cursor.flatMap(renderer.makeCursor)
            scene.withLock { $0.cursor = image }
            markDirty()
            DispatchQueue.main.async { [weak self] in
                self?.remoteCursor = cursor
                self?.updateSystemCursor()
            }
        case .pointer(let x, let y):
            let visible = scene.withLock { s in
                s.pointer = (x, y)
                return s.cursor != nil
            }
            if visible { markDirty() }
        default:
            break
        }
    }

    public var contentRect: CGRect {
        guard framebufferSize.width > 0, framebufferSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / framebufferSize.width, bounds.height / framebufferSize.height)
        let size = CGSize(width: (framebufferSize.width * scale).rounded(), height: (framebufferSize.height * scale).rounded())
        return CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
    }

    public func framebufferPoint(_ point: CGPoint) -> (x: Int, y: Int)? {
        let rect = contentRect
        guard rect.width > 0, rect.contains(point) else { return nil }
        let x = Int((point.x - rect.minX) / rect.width * framebufferSize.width)
        let y = Int((rect.maxY - point.y) / rect.height * framebufferSize.height)
        return (min(x, Int(framebufferSize.width) - 1), min(y, Int(framebufferSize.height) - 1))
    }

    public func viewPoint(framebufferX x: Int, y: Int) -> CGPoint? {
        let rect = contentRect
        guard rect.width > 0 else { return nil }
        return CGPoint(
            x: rect.minX + (CGFloat(x) + 0.5) / framebufferSize.width * rect.width,
            y: rect.maxY - (CGFloat(y) + 0.5) / framebufferSize.height * rect.height
        )
    }

    public func snapshot() -> CGImage? {
        scene.withLock { $0.surface?.framebuffer }?.makeImage()
    }

    // MARK: drawing

    private nonisolated func markDirty() {
        guard !dirty.exchange(true, ordering: .acquiringAndReleasing) else { return }
        DispatchQueue.main.async { [weak self] in
            self?.wake()
        }
    }

    private func requestDraw() {
        dirty.store(true, ordering: .releasing)
        wake()
    }

    private func wake() {
        link?.isPaused = false
    }

    fileprivate func tick(_ link: CADisplayLink) {
        link.isPaused = true
        guard window?.occlusionState.contains(.visible) == true else { return }
        guard dirty.exchange(false, ordering: .acquiringAndReleasing) else { return }
        let (surface, cursor, pointer) = scene.withLock { ($0.surface, $0.cursor, $0.pointer) }
        guard let surface, !metalLayer.isHidden, hasContent.load(ordering: .relaxed) else { return }
        let overlay = !isInputEnabled ? cursor.flatMap { c in pointer.map { (c, $0.x, $0.y) } } : nil
        let client = client
        let first = !presentedFirst
        var presented = onPresent
        if first {
            let each = onPresent
            presented = { [weak self] in
                each?()
                Task { @MainActor in self?.onFirstFrame?() }
            }
        }
        if renderer.draw(surface, cursor: overlay, in: metalLayer, presented: presented, completed: { client?.framebufferConsumed() }) {
            presentedFirst = presentedFirst || first
        } else {
            requestDraw()
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let window else { return }
        let link = displayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick(_:)))
        link.isPaused = true
        link.add(to: .main, forMode: .common)
        self.link = link
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            },
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.releaseInput() }
            },
        ]
        needsLayout = true
    }

    public override func layout() {
        super.layout()
        let rect = contentRect
        metalLayer.isHidden = rect.isEmpty
        guard !rect.isEmpty else { return }
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.frame = rect
        metalLayer.contentsScale = scale
        var size = CGSize(width: rect.width * scale, height: rect.height * scale)
        if size.width > framebufferSize.width {
            size = framebufferSize
        }
        if metalLayer.drawableSize != size {
            metalLayer.drawableSize = size
        }
        updateSystemCursor()
        window?.invalidateCursorRects(for: self)
        requestDraw()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    // MARK: cursor

    private func updateSystemCursor() {
        systemCursor = nil
        if let cursor = remoteCursor, cursor.width > 0, framebufferSize.width > 0 {
            let points = contentRect.width / framebufferSize.width
            if let image = Self.image(cursor) {
                let size = NSSize(width: CGFloat(cursor.width) * points, height: CGFloat(cursor.height) * points)
                systemCursor = NSCursor(image: NSImage(cgImage: image, size: size), hotSpot: NSPoint(x: CGFloat(cursor.hotspotX) * points, y: CGFloat(cursor.hotspotY) * points))
            }
        } else if remoteCursor != nil {
            systemCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)
        }
        window?.invalidateCursorRects(for: self)
    }

    private static func image(_ cursor: RFBCursor) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(cursor.pixels) as CFData) else { return nil }
        return CGImage(
            width: cursor.width, height: cursor.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cursor.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    public override func resetCursorRects() {
        addCursorRect(contentRect, cursor: isInputEnabled ? (systemCursor ?? .arrow) : .arrow)
    }

    // MARK: input

    public override var acceptsFirstResponder: Bool { isInputEnabled }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { isInputEnabled }

    public override func resignFirstResponder() -> Bool {
        releaseInput()
        return super.resignFirstResponder()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseMoved(with event: NSEvent) { pointer(event) }
    public override func mouseDragged(with event: NSEvent) { pointer(event) }
    public override func rightMouseDragged(with event: NSEvent) { pointer(event) }
    public override func otherMouseDragged(with event: NSEvent) { pointer(event) }
    public override func mouseDown(with event: NSEvent) { pointer(event, .left, down: true) }
    public override func mouseUp(with event: NSEvent) { pointer(event, .left, down: false) }
    public override func rightMouseDown(with event: NSEvent) { pointer(event, .right, down: true) }
    public override func rightMouseUp(with event: NSEvent) { pointer(event, .right, down: false) }
    public override func otherMouseDown(with event: NSEvent) { pointer(event, event.buttonNumber == 2 ? .middle : [], down: true) }
    public override func otherMouseUp(with event: NSEvent) { pointer(event, event.buttonNumber == 2 ? .middle : [], down: false) }

    // pointer drops presses and moves outside the framebuffer but clamps the
    // rest, so a drag released in the letterbox still releases remotely.
    private func pointer(_ event: NSEvent, _ button: RFBButtons = [], down: Bool = false) {
        guard isInputEnabled, let client else { return }
        let location = convert(event.locationInWindow, from: nil)
        let rect = contentRect
        let inside = framebufferPoint(location) != nil
        guard inside || (!down && !buttons.isEmpty) else { return }
        let clamped = CGPoint(x: min(max(location.x, rect.minX), rect.maxX - 0.5), y: min(max(location.y, rect.minY), rect.maxY - 0.5))
        guard let point = framebufferPoint(clamped) else { return }
        if down {
            onInput?()
            buttons.insert(button)
            window?.makeFirstResponder(self)
        } else {
            buttons.remove(button)
        }
        client.pointer(x: point.x, y: point.y, buttons: buttons)
    }

    public override func scrollWheel(with event: NSEvent) {
        guard isInputEnabled, let client, let point = framebufferPoint(convert(event.locationInWindow, from: nil)) else { return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
        scroll.x += event.scrollingDeltaX
        scroll.y += event.scrollingDeltaY
        let vertical = Int(scroll.y / step)
        let horizontal = Int(scroll.x / step)
        scroll.x -= CGFloat(horizontal) * step
        scroll.y -= CGFloat(vertical) * step
        for (count, wheel) in [(vertical, vertical > 0 ? RFBButtons.wheelUp : .wheelDown), (horizontal, horizontal > 0 ? RFBButtons.wheelLeft : .wheelRight)] {
            for _ in 0..<abs(count) {
                client.pointer(x: point.x, y: point.y, buttons: buttons.union(wheel))
                client.pointer(x: point.x, y: point.y, buttons: buttons)
            }
        }
    }

    public override func keyDown(with event: NSEvent) {
        guard isInputEnabled, let client else { return super.keyDown(with: event) }
        let keysym =
            pressed[event.keyCode]
            ?? RFBKeyMap.keysym(
                keyCode: event.keyCode, characters: event.charactersIgnoringModifiers, deadKey: event.characters?.isEmpty == true
            )
        guard let keysym else { return }
        pressed[event.keyCode] = keysym
        onInput?()
        client.key(keysym, down: true, scancode: RFBKeyMap.scancode(keyCode: event.keyCode))
    }

    public override func keyUp(with event: NSEvent) {
        guard isInputEnabled, let client else { return super.keyUp(with: event) }
        guard let keysym = pressed.removeValue(forKey: event.keyCode) else { return }
        client.key(keysym, down: false, scancode: RFBKeyMap.scancode(keyCode: event.keyCode))
    }

    public override func flagsChanged(with event: NSEvent) {
        guard isInputEnabled, let client, let keysym = RFBKeyMap.keysym(keyCode: event.keyCode, characters: nil),
            let flag = Self.modifierFlag(event.keyCode)
        else { return super.flagsChanged(with: event) }
        let scancode = RFBKeyMap.scancode(keyCode: event.keyCode)
        if flag == .capsLock {
            client.key(keysym, down: true, scancode: scancode)
            client.key(keysym, down: false, scancode: scancode)
            return
        }
        let down = event.modifierFlags.contains(flag) && pressed[event.keyCode] == nil
        if flag == .command, !down {
            releaseKeys { Self.modifierFlag($0) == nil }
        }
        if down {
            pressed[event.keyCode] = keysym
        } else {
            pressed[event.keyCode] = nil
        }
        client.key(keysym, down: down, scancode: scancode)
    }

    // typeText sends text as key presses while input is enabled.
    public func typeText(_ text: String) {
        guard isInputEnabled else { return }
        client?.type(text)
    }

    // releaseKeys lifts held keys: AppKit sends no keyUp for keys released
    // while Command is down, nor any key event once the window loses focus.
    private func releaseKeys(where matches: (UInt16) -> Bool = { _ in true }) {
        for (keyCode, keysym) in pressed where matches(keyCode) {
            client?.key(keysym, down: false, scancode: RFBKeyMap.scancode(keyCode: keyCode))
            pressed[keyCode] = nil
        }
    }

    private func releaseInput() {
        guard let client else { return }
        releaseKeys()
        if !buttons.isEmpty {
            buttons = []
            if let point = window.flatMap({ framebufferPoint(convert($0.mouseLocationOutsideOfEventStream, from: nil)) }) {
                client.pointer(x: point.x, y: point.y, buttons: [])
            }
        }
    }

    private static func modifierFlag(_ keyCode: UInt16) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 0x38, 0x3C: .shift
        case 0x3B, 0x3E: .control
        case 0x3A, 0x3D: .option
        case 0x37, 0x36: .command
        case 0x39: .capsLock
        default: nil
        }
    }
}
// LinkTarget keeps the display link from retaining the view.
@MainActor
private final class LinkTarget: NSObject {
    weak var view: RFBView?

    init(_ view: RFBView) {
        self.view = view
    }

    @objc func tick(_ link: CADisplayLink) {
        guard let view else { return link.invalidate() }
        view.tick(link)
    }
}
#endif
