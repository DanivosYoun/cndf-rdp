import AppKit
import CoreVideo
import os.log
import QuartzCore
import RDPClientCore

public final class RDPClientView: NSView {
    public weak var session: RDPEngineSession?
    /// When true on a `.korean` connection, mirrors macOS Korean/non-Korean input-source flips
    /// to the remote Windows session as a single Hangul toggle (design H1–H6).
    public var inputSourceFollow = false {
        didSet {
            guard inputSourceFollow != oldValue else { return }
            updateInputSourceFollowObservation()
        }
    }
    public var onRenderedFrame: ((CVPixelBuffer, CFTimeInterval) -> Void)? {
        didSet { frameTapDidChange?() }
    }
    // Lets the owning RDPConnectionView release output suppression the moment a tap attaches.
    var frameTapDidChange: (() -> Void)?

    private static let inputSourceFollowLog = OSLog(subsystem: "com.cndf.rdp", category: "input-source-follow")
    private var inputSourceFollower = RDPInputSourceFollower()
    private var inputSourceReader: RDPInputSourceReading = RDPMacInputSourceReader()
    private var inputSourceObserver = RDPMacInputSourceObserver()
    private var inputSourceClock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    private var isViewFocusedForInputSourceFollow: (() -> Bool)?
    private var switchHotkeysOverride: [RDPSwitchHotkey]?
    private var inputSourceSettleWorkItem: DispatchWorkItem?
    private var lastObservedSourceID: String?
    private var suppressedSwitchKeyCodes: Set<UInt16> = []
    private var isRawRightOptionActive = false
    private var isSuppressingRightOption = false

    private var trackingArea: NSTrackingArea?
    private var remoteFrameSize: CGSize = .zero
    private var remotePointer: RDPRemotePointer?
    // The cursor shown over this view; nil keeps the local default until the server sends one.
    private(set) var remoteCursor: NSCursor?
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var isRenderPipelineShutdown = false
    private let frameColorSpace = CGColorSpaceCreateDeviceRGB()
    private let injectedInputQueue = DispatchQueue(label: "rdp.client-view.injected-input", qos: .userInteractive)
    private var focusObservers: [NSObjectProtocol] = []
    private static let disabledLayerActions: [String: CAAction] = [
        "backgroundColor": NSNull(),
        "bounds": NSNull(),
        "contents": NSNull(),
        "contentsGravity": NSNull(),
        "contentsScale": NSNull(),
        "magnificationFilter": NSNull(),
        "onOrderIn": NSNull(),
        "onOrderOut": NSNull(),
        "position": NSNull(),
        "sublayers": NSNull()
    ]

    public override var acceptsFirstResponder: Bool {
        true
    }

    public override var isFlipped: Bool {
        true
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    deinit {
        onRenderedFrame = nil
        stopInputSourceFollow()
        removeFocusObservers()
    }

    private func configure() {
        wantsLayer = true
        let backingLayer = CALayer()
        backingLayer.backgroundColor = NSColor.black.cgColor
        backingLayer.contentsGravity = .resizeAspect
        backingLayer.masksToBounds = true
        backingLayer.actions = Self.disabledLayerActions
        layer = backingLayer
        registerForDraggedTypes([.fileURL])
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFrameLayerScale()
        observeFocus()
        guard let window else {
            return
        }
        window.makeFirstResponder(self)
        sendForcedDesktopSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateFrameLayerScale()
        scheduleDesktopSize()
        refreshRemoteCursor()
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        if let remoteCursor {
            addCursorRect(visibleRect, cursor: remoteCursor)
        }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateFrameLayerScale()
        sendForcedDesktopSize()
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        guard !isRenderPipelineShutdown else {
            trackingArea = nil
            return
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .enabledDuringMouseDrag, .inVisibleRect],
            owner: self
        )
        trackingArea = area
        addTrackingArea(area)
    }

    public override func mouseMoved(with event: NSEvent) {
        sendPointerMove(event)
    }

    public override func mouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    public override func rightMouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    public override func otherMouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(.left, event: event, pressed: true)
    }

    public override func mouseUp(with event: NSEvent) {
        sendPointerButton(.left, event: event, pressed: false)
    }

    public override func rightMouseDown(with event: NSEvent) {
        sendPointerButton(.right, event: event, pressed: true)
    }

    public override func rightMouseUp(with event: NSEvent) {
        sendPointerButton(.right, event: event, pressed: false)
    }

    public override func otherMouseDown(with event: NSEvent) {
        sendPointerButton(.middle, event: event, pressed: true)
    }

    public override func otherMouseUp(with event: NSEvent) {
        sendPointerButton(.middle, event: event, pressed: false)
    }

    public override func scrollWheel(with event: NSEvent) {
        let rotation = wheelQuantizer.quantize(event)
        guard rotation.x != 0 || rotation.y != 0 else { return }
        inputExecutor()?.hostScroll(
            at: pointerLocation(for: event),
            deltaX: rdpHorizontalWheelRotation(rotation.x),
            deltaY: rotation.y
        )
    }

    /// RDP wheel rotation (WHEEL_DELTA units, 120 = one notch) from AppKit's `deltaX`/`deltaY`,
    /// which are line-scaled for a mouse wheel and a trackpad alike (`scrollingDelta*` would be
    /// pixels on a trackpad) — the rule FreeRDP's own macOS client uses. The shared viewer runs the
    /// same quantizer, so fractions accumulate the same way locally and through a share.
    var wheelQuantizer = RDPWheelQuantizer()

    // Mac numeric-keypad digit (0-9) and decimal keycodes. Their RDP keypad scancodes
    // (0x47-0x53) are NumLock-dependent, so on hosts that ignore the connect-time
    // lock-sync (e.g. xrdp) they register as navigation keys instead of digits. We send
    // these as NumLock-independent Unicode keyboard events instead — but only when bare
    // (no ⌘/⌃/⌥), so shortcut combos and paste keep the scancode path.
    private static let numpadUnicodeKeyCodes: Set<UInt16> = [82, 83, 84, 85, 86, 87, 88, 89, 91, 92, 65]
    // Tracks keycodes whose keyDown was sent as Unicode, so the matching keyUp is sent
    // the same way (symmetric down/up; never a Unicode-down paired with a scancode-up).
    private var unicodeNumpadDown: [UInt16: UInt16] = [:]

    private func unicodeForBareNumpad(_ event: NSEvent) -> UInt16? {
        guard Self.numpadUnicodeKeyCodes.contains(event.keyCode) else { return nil }
        let mods = event.modifierFlags
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            return nil
        }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
              scalar.value != 0, scalar.value <= 0xFFFF else { return nil }
        return UInt16(scalar.value)
    }

    public override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            syncHostModifiers()
            handleInputSourceFocusGained()
        }
        return accepted
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            releaseHostInput()
        }
        return resigned
    }

    public override func keyDown(with event: NSEvent) {
        let preCheck = evaluateInputSourceChange(cause: .async, fromNotification: false)
        if inputSourceFollow {
            if suppressedSwitchKeyCodes.contains(event.keyCode) {
                return
            }
            if preCheck.sourceChanged && isSwitchHotkeyCandidate(event) {
                suppressedSwitchKeyCodes.insert(event.keyCode)
                return
            }
        }
        // Han/Yeong and Hanja are toggles: one tap per press, auto-repeat ignored (design I11).
        if let profile = session?.keyboardProfile,
           RDPKeyboardMapper.imeToggleScancodes(for: profile) != nil,
           let toggle = RDPKeyboardMapper.imeToggle(forMacKeyCode: event.keyCode) {
            if !event.isARepeat {
                if toggle == .hangul && isInputSourceFollowEligible && inputSourceFollower.isFocused {
                    let now = inputSourceClock()
                    if inputSourceFollower.shouldSuppressRawToggle(at: now) {
                        return
                    }
                    inputSourceFollower.rawToggleBegan(at: now)
                    inputExecutor()?.hostIMETap(toggle)
                    inputSourceFollower.rawToggleEnded(at: now)
                } else {
                    inputExecutor()?.hostIMETap(toggle)
                }
            }
            return
        }
        if sendCommandShortcutIfNeeded(event) {
            return
        }
        if let code = unicodeForBareNumpad(event) {
            unicodeNumpadDown[event.keyCode] = code
            inputExecutor()?.hostUnicode(code: code, pressed: true)
            return
        }
        sendKey(event.keyCode, pressed: true)
    }

    public override func keyUp(with event: NSEvent) {
        _ = evaluateInputSourceChange(cause: .async, fromNotification: false)
        if suppressedSwitchKeyCodes.remove(event.keyCode) != nil {
            return
        }
        if event.modifierFlags.contains(.command),
           RDPKeyboardMapper.commandShortcutScancode(for: event.keyCode) != nil {
            return
        }
        if let code = unicodeNumpadDown.removeValue(forKey: event.keyCode) {
            inputExecutor()?.hostUnicode(code: code, pressed: false)
            return
        }
        sendKey(event.keyCode, pressed: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        _ = evaluateInputSourceChange(cause: .async, fromNotification: false)
        var scancodes = RDPKeyboardMapper.modifierScancodes(for: event.modifierFlags)
        if isInputSourceFollowEligible && inputSourceFollower.isFocused {
            let now = inputSourceClock()
            let isRightOptionNow = RDPKeyboardMapper.isRightOptionOnly(event.modifierFlags)
            if isRightOptionNow {
                if !isRawRightOptionActive && !isSuppressingRightOption {
                    if inputSourceFollower.shouldSuppressRawToggle(at: now) {
                        isSuppressingRightOption = true
                    } else {
                        isRawRightOptionActive = true
                        inputSourceFollower.rawToggleBegan(at: now)
                    }
                }
                if isSuppressingRightOption {
                    scancodes.removeAll { $0 == RDPKeyboardMapper.rightAlt }
                }
            } else {
                if isRawRightOptionActive {
                    isRawRightOptionActive = false
                    inputSourceFollower.rawToggleEnded(at: now)
                }
                if isSuppressingRightOption {
                    isSuppressingRightOption = false
                }
            }
        }
        inputExecutor()?.hostModifiers(scancodes)
    }

    /// Releases every key, modifier and button the local view holds, so nothing stays down on
    /// the server while key events go elsewhere (design D6). Share owners keep theirs.
    func releaseHostInput() {
        handleInputSourceFocusLost()
        unicodeNumpadDown.removeAll()
        inputExecutor()?.hostReleaseAll()
    }

    private func syncHostModifiers() {
        inputExecutor()?.hostModifiers(RDPKeyboardMapper.modifierScancodes(for: NSEvent.modifierFlags))
    }

    private func observeFocus() {
        removeFocusObservers()
        guard let window else {
            return
        }
        let center = NotificationCenter.default
        focusObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.releaseHostInput()
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.releaseHostInput()
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                guard let self, self.window?.firstResponder === self else { return }
                self.syncHostModifiers()
                self.handleInputSourceFocusGained()
            },
            center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.window?.isKeyWindow == true, self.window?.firstResponder === self else { return }
                self.handleInputSourceFocusGained()
            }
        ]
    }

    private func removeFocusObservers() {
        focusObservers.forEach(NotificationCenter.default.removeObserver)
        focusObservers = []
    }

    public override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    public override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else {
            return false
        }

        do {
            try session?.sendLocalFiles(urls)
            pasteOfferedFilesAfterDrop()
            return true
        } catch {
            NSLog("[RDP] local file drag failed: \(String(describing: error))")
            return false
        }
    }

    public func sendForcedDesktopSize() {
        guard !isRenderPipelineShutdown else { return }
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        sendDesktopSize(force: true)
    }

    public func display(_ frame: RDPFrame) {
        guard !isRenderPipelineShutdown else { return }
        guard let image = makeImage(from: frame) else { return }
        let frameSize = CGSize(width: frame.width, height: frame.height)
        let frameSizeChanged = frameSize != remoteFrameSize
        remoteFrameSize = frameSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if frameSizeChanged {
            updateFrameLayerScale()
        }
        layer?.contents = image
        CATransaction.commit()
        if let onRenderedFrame, let pixelBuffer = makePixelBuffer(from: frame) {
            onRenderedFrame(pixelBuffer, CACurrentMediaTime())
        }
        if frameSizeChanged {
            refreshRemoteCursor()
        }
    }

    /// Shows the server's pointer shape as the cursor over this view. Ignored after shutdown.
    public func updateRemotePointer(_ pointer: RDPRemotePointer) {
        guard !isRenderPipelineShutdown else { return }
        remotePointer = pointer
        refreshRemoteCursor()
    }

    public func injectMouse(x: Int32, y: Int32, button: RDPMouseButton?, flags: RDPMouseFlags) {
        inputExecutor()?.hostMouse(x: x, y: y, button: button, flags: flags)
    }

    public func injectKey(virtualKeyCode: UInt16, scanCode: UInt16, flags: RDPKeyFlags) {
        inputExecutor()?.hostInjectKey(scanCode: scanCode, flags: flags)
    }

    public func injectScroll(x: Int32, y: Int32, deltaY: Int32, deltaX: Int32) {
        inputExecutor()?.hostScroll(
            at: RDPPointerLocation(clampingX: x, y: y),
            deltaX: deltaX,
            deltaY: deltaY
        )
    }

    /// A new input handle bound to the current native connection. It starts inactive; a view
    /// without a usable connection returns a handle that can never activate.
    @MainActor
    public func makeSharedInputSession() -> RDPSharedInputSession {
        guard let executor = inputExecutor() else {
            return RDPSharedInputSession.unavailable()
        }
        return executor.makeSharedSession()
    }

    @discardableResult
    public func shutdownRendering(waitTimeout: TimeInterval = 1.0) -> Int {
        guard !isRenderPipelineShutdown else {
            return 0
        }
        isRenderPipelineShutdown = true
        stopInputSourceFollow()
        removeFocusObservers()
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        unregisterDraggedTypes()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        remoteFrameSize = .zero
        remotePointer = nil
        remoteCursor = nil
        window?.invalidateCursorRects(for: self)
        isHidden = true
        session = nil
        onRenderedFrame = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.removeAllAnimations()
        layer?.contents = nil
        CATransaction.commit()
        removeFromSuperview()
        return 0
    }

    private func makeImage(from frame: RDPFrame) -> CGImage? {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4 else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        )
        guard let provider = CGDataProvider(data: frame.bgra as CFData) else {
            return nil
        }
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.stride,
            space: frameColorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    private func refreshRemoteCursor() {
        guard !isRenderPipelineShutdown, let remotePointer else { return }
        switch remotePointer {
        case .image(let image):
            remoteCursor = makeCursor(from: image) ?? NSCursor.arrow
        case .hidden:
            remoteCursor = Self.hiddenCursor
        case .systemDefault:
            remoteCursor = NSCursor.arrow
        }
        guard let window else { return }
        window.invalidateCursorRects(for: self)
        // Cursor rects only apply on the next mouse move; show the new shape now if the
        // mouse is already over the view.
        let mouse = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if window.isKeyWindow, visibleRect.contains(mouse) {
            remoteCursor?.set()
        }
    }

    private func updateFrameLayerScale() {
        guard let layer else { return }
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        layer.contentsScale = backingScale
        layer.magnificationFilter = Self.magnificationFilter(for: pointsPerRemotePixel * backingScale)
    }

    private static func magnificationFilter(for scale: CGFloat) -> CALayerContentsFilter {
        let integralScale = scale.rounded()
        return integralScale > 1 && abs(scale - integralScale) <= 0.000_001 ? .nearest : .linear
    }

    // Remote view points per remote desktop pixel, as the frame is currently displayed.
    private var pointsPerRemotePixel: CGFloat {
        guard remoteFrameSize.width > 0, remoteFrameSize.height > 0 else {
            return 1 / (window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)
        }
        let displayRect = remoteDisplayRect(targetWidth: remoteFrameSize.width, targetHeight: remoteFrameSize.height)
        return displayRect.width / remoteFrameSize.width
    }

    private func makeCursor(from pointer: RDPPointerImage) -> NSCursor? {
        guard pointer.width > 0, pointer.height > 0, pointer.stride >= pointer.width * 4,
              let provider = CGDataProvider(data: pointer.bgra as CFData) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.first.rawValue)
        )
        guard let image = CGImage(
            width: pointer.width,
            height: pointer.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: pointer.stride,
            space: frameColorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            return nil
        }
        let geometry = RDPCursorGeometry(
            pixelWidth: pointer.width,
            pixelHeight: pointer.height,
            hotSpotX: pointer.hotSpotX,
            hotSpotY: pointer.hotSpotY,
            pointsPerRemotePixel: pointsPerRemotePixel
        )
        return NSCursor(image: NSImage(cgImage: image, size: geometry.size), hotSpot: geometry.hotSpot)
    }

    // A transparent 1x1 cursor for a hidden server pointer; NSCursor.hide is a global
    // counter and is never used.
    private static let hiddenCursor = NSCursor(
        image: NSImage(size: NSSize(width: 1, height: 1), flipped: false) { _ in true },
        hotSpot: .zero
    )

    private func makePixelBuffer(from frame: RDPFrame) -> CVPixelBuffer? {
        guard frame.width > 0, frame.height > 0, frame.stride >= frame.width * 4 else {
            return nil
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            frame.width,
            frame.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        }
        guard let destinationBaseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerRowToCopy = min(frame.width * 4, frame.stride, destinationStride)
        frame.bgra.withUnsafeBytes { sourceBuffer in
            guard let sourceBaseAddress = sourceBuffer.baseAddress else {
                return
            }
            for row in 0..<frame.height {
                memcpy(
                    destinationBaseAddress.advanced(by: row * destinationStride),
                    sourceBaseAddress.advanced(by: row * frame.stride),
                    bytesPerRowToCopy
                )
            }
        }
        return pixelBuffer
    }

    // Bound to the session and its connection generation; a reconnect gets a fresh executor so
    // nothing recorded on the old connection is released onto the new one.
    private func inputExecutor() -> RDPInputExecutor? {
        guard !isRenderPipelineShutdown, let session else {
            return nil
        }
        let queue = injectedInputQueue
        return RDPInputExecutorRegistry.executor(for: session, schedule: { work in
            queue.async { work() }
        })
    }

    private func sendPointerMove(_ event: NSEvent) {
        inputExecutor()?.hostPointerMove(pointerLocation(for: event))
    }

    private func sendPointerButton(_ button: RDPPointerButton, event: NSEvent, pressed: Bool) {
        inputExecutor()?.hostPointerButton(button, at: pointerLocation(for: event), pressed: pressed)
    }

    private func sendKey(_ macKeyCode: UInt16, pressed: Bool) {
        guard let scancode = RDPKeyboardMapper.scancode(for: macKeyCode) else {
            return
        }
        inputExecutor()?.hostKey(scanCode: scancode, pressed: pressed)
    }

    private func sendCommandShortcutIfNeeded(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              let scancode = RDPKeyboardMapper.commandShortcutScancode(for: event.keyCode) else {
            return false
        }

        inputExecutor()?.hostChord([RDPKeyboardMapper.leftControl, scancode])
        NSLog("[RDP] command shortcut forwarded as Ctrl scancode 0x%02x", scancode)
        return true
    }

    private func pasteOfferedFilesAfterDrop() {
        window?.makeFirstResponder(self)
        guard let executor = inputExecutor() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            executor.hostChord([RDPKeyboardMapper.leftControl, 0x2F])
            NSLog("[RDP] local file drag forwarded as Ctrl+V.")
        }
    }

    private func pointerLocation(for event: NSEvent) -> RDPPointerLocation {
        let point = convert(event.locationInWindow, from: nil)
        let targetWidth = remoteFrameSize.width > 0 ? remoteFrameSize.width : bounds.width
        let targetHeight = remoteFrameSize.height > 0 ? remoteFrameSize.height : bounds.height
        let displayRect = remoteDisplayRect(targetWidth: targetWidth, targetHeight: targetHeight)
        let clampedX = max(displayRect.minX, min(displayRect.maxX, point.x))
        let clampedY = max(displayRect.minY, min(displayRect.maxY, point.y))
        let xRatio = displayRect.width > 0 ? (clampedX - displayRect.minX) / displayRect.width : 0
        let yRatio = displayRect.height > 0 ? (clampedY - displayRect.minY) / displayRect.height : 0
        let x = UInt32(max(0, min(targetWidth - 1, xRatio * targetWidth)).rounded(.toNearestOrAwayFromZero))
        let y = UInt32(max(0, min(targetHeight - 1, yRatio * targetHeight)).rounded(.toNearestOrAwayFromZero))
        return RDPPointerLocation(pixelX: x, pixelY: y)
    }

    private func sendDesktopSize(force: Bool) {
        guard !isRenderPipelineShutdown else { return }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0
        try? session?.updateDesktopSize(
            pointWidth: Double(bounds.width),
            pointHeight: Double(bounds.height),
            scale: scale,
            force: force
        )
    }

    private func remoteDisplayRect(targetWidth: CGFloat, targetHeight: CGFloat) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, targetWidth > 0, targetHeight > 0 else {
            return bounds
        }

        let xScale = bounds.width / targetWidth
        let yScale = bounds.height / targetHeight
        let scale = min(xScale, yScale)
        let width = targetWidth * scale
        let height = targetHeight * scale
        return CGRect(
            x: bounds.minX + (bounds.width - width) / 2,
            y: bounds.minY + (bounds.height - height) / 2,
            width: width,
            height: height
        )
    }

    private func scheduleDesktopSize() {
        guard !isRenderPipelineShutdown else { return }
        pendingResizeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.sendDesktopSize(force: false)
        }
        pendingResizeWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: workItem)
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] ?? []
    }

    // MARK: - Input-source follow (design H1–H6)

    func configureInputSourceFollowForTesting(
        reader: RDPInputSourceReading,
        observer: RDPMacInputSourceObserver,
        clock: @escaping () -> TimeInterval,
        isFocused: @escaping () -> Bool,
        switchHotkeys: [RDPSwitchHotkey]? = nil
    ) {
        inputSourceObserver.stop()
        inputSourceReader = reader
        inputSourceObserver = observer
        inputSourceClock = clock
        isViewFocusedForInputSourceFollow = isFocused
        switchHotkeysOverride = switchHotkeys
        if inputSourceFollow {
            updateInputSourceFollowObservation()
        }
    }

    private var isInputSourceFollowEligible: Bool {
        inputSourceFollow
            && !isRenderPipelineShutdown
            && session?.keyboardProfile == .korean
            && session?.isConnected == true
    }

    private func isEffectivelyFocusedForInputSourceFollow() -> Bool {
        if let override = isViewFocusedForInputSourceFollow {
            return override()
        }
        return NSApp.isActive
            && (window?.isKeyWindow ?? false)
            && window?.firstResponder === self
    }

    private func updateInputSourceFollowObservation() {
        if inputSourceFollow && !isRenderPipelineShutdown {
            inputSourceObserver.start { [weak self] in
                self?.evaluateInputSourceChange(cause: .async, fromNotification: true)
            }
            handleInputSourceFocusGained()
        } else {
            stopInputSourceFollow()
        }
    }

    private func stopInputSourceFollow() {
        inputSourceObserver.stop()
        handleInputSourceFocusLost()
    }

    func handleInputSourceFocusGained() {
        inputSourceSettleWorkItem?.cancel()
        inputSourceSettleWorkItem = nil
        guard isInputSourceFollowEligible, isEffectivelyFocusedForInputSourceFollow() else {
            return
        }
        let now = inputSourceClock()
        let language = inputSourceReader.currentLanguage()
        lastObservedSourceID = inputSourceReader.currentSourceID()
        inputSourceFollower.focusGained(at: now, language: language)
        let workItem = DispatchWorkItem { [weak self] in
            self?.handleInputSourceSettleElapsed()
        }
        inputSourceSettleWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + inputSourceFollower.settleInterval, execute: workItem)
    }

    func handleInputSourceSettleElapsed() {
        inputSourceSettleWorkItem?.cancel()
        inputSourceSettleWorkItem = nil
        guard isInputSourceFollowEligible,
              isEffectivelyFocusedForInputSourceFollow(),
              inputSourceFollower.isFocused else {
            return
        }
        let now = inputSourceClock()
        let language = inputSourceReader.currentLanguage()
        lastObservedSourceID = inputSourceReader.currentSourceID()
        inputSourceFollower.settleElapsed(at: now, language: language)
    }

    func handleInputSourceFocusLost() {
        inputSourceSettleWorkItem?.cancel()
        inputSourceSettleWorkItem = nil
        suppressedSwitchKeyCodes.removeAll()
        isRawRightOptionActive = false
        isSuppressingRightOption = false
        lastObservedSourceID = nil
        inputSourceFollower.focusLost()
    }

    @discardableResult
    private func evaluateInputSourceChange(
        cause: RDPInputSourceObservationCause,
        fromNotification: Bool
    ) -> (decision: RDPInputSourceFollowDecision, sourceChanged: Bool) {
        guard inputSourceFollow, !isRenderPipelineShutdown else {
            return (.none(.unfocused), false)
        }
        guard isInputSourceFollowEligible, isEffectivelyFocusedForInputSourceFollow() else {
            if inputSourceFollower.isFocused {
                handleInputSourceFocusLost()
            }
            return (.none(.unfocused), false)
        }
        if !inputSourceFollower.isFocused {
            handleInputSourceFocusGained()
            return (.none(.settling), false)
        }

        let language = inputSourceReader.currentLanguage()
        let sourceID = inputSourceReader.currentSourceID()
        let sourceChanged: Bool
        if let sourceID, let previousID = lastObservedSourceID {
            sourceChanged = (sourceID != previousID)
        } else {
            sourceChanged = (language != inputSourceFollower.baseline)
        }
        lastObservedSourceID = sourceID

        let decision = inputSourceFollower.observe(language, at: inputSourceClock(), cause: cause)
        if fromNotification || sourceChanged || decision != .none(.unchanged) {
            logInputSourceDecision(decision, language: language, cause: cause)
        }
        if case .sendToggle = decision {
            inputExecutor()?.hostIMETap(.hangul)
        }
        return (decision, sourceChanged)
    }

    private func isSwitchHotkeyCandidate(_ event: NSEvent) -> Bool {
        let hotkeys = switchHotkeysOverride ?? RDPSymbolicHotKeys.readEnabledSwitchHotkeys()
        return hotkeys.contains { $0.matches(keyCode: event.keyCode, modifierFlags: event.modifierFlags) }
    }

    private func logInputSourceDecision(
        _ decision: RDPInputSourceFollowDecision,
        language: RDPInputLanguage,
        cause: RDPInputSourceObservationCause
    ) {
        let line = "RDP input-source follow: \(decision.reason.rawValue) lang=\(language.rawValue) cause=\(cause.rawValue) sent=\(decision.sentLogValue)"
        if let session, let delegate = session.delegate {
            delegate.rdpSession(session, didLog: line)
        } else {
            os_log("%{public}@", log: Self.inputSourceFollowLog, type: .info, line)
        }
    }
}
