import AppKit
import RDPClientCore

public final class RDPClientView: NSView {
    public weak var session: RDPSession?

    private var trackingArea: NSTrackingArea?
    private var modifierState: Set<UInt16> = []
    private var remoteFrameSize: CGSize = .zero
    private var pendingResizeWorkItem: DispatchWorkItem?
    private var isRenderPipelineShutdown = false
    private let frameColorSpace = CGColorSpaceCreateDeviceRGB()

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

    private func configure() {
        wantsLayer = true
        let backingLayer = CALayer()
        backingLayer.backgroundColor = NSColor.black.cgColor
        backingLayer.contentsGravity = .resizeAspect
        backingLayer.masksToBounds = true
        layer = backingLayer
        registerForDraggedTypes([.fileURL])
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            return
        }
        window.makeFirstResponder(self)
        sendForcedDesktopSize()
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleDesktopSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
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
        try? session?.sendScroll(
            deltaX: Int32(event.scrollingDeltaX.rounded()),
            deltaY: Int32(event.scrollingDeltaY.rounded())
        )
    }

    public override func keyDown(with event: NSEvent) {
        if sendCommandShortcutIfNeeded(event) {
            return
        }
        sendKey(event.keyCode, pressed: true)
    }

    public override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           RDPKeyboardMapper.commandShortcutScancode(for: event.keyCode) != nil {
            return
        }
        sendKey(event.keyCode, pressed: false)
    }

    public override func flagsChanged(with event: NSEvent) {
        updateModifier(RDPKeyboardMapper.leftShift, enabled: event.modifierFlags.contains(.shift))
        updateModifier(RDPKeyboardMapper.leftControl, enabled: event.modifierFlags.contains(.control))
        updateModifier(RDPKeyboardMapper.leftAlt, enabled: event.modifierFlags.contains(.option))
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
        remoteFrameSize = CGSize(width: frame.width, height: frame.height)
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        layer?.contents = image
    }

    @discardableResult
    public func shutdownRendering(waitTimeout: TimeInterval = 1.0) -> Int {
        guard !isRenderPipelineShutdown else {
            return 0
        }
        isRenderPipelineShutdown = true
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        unregisterDraggedTypes()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        modifierState.removeAll()
        remoteFrameSize = .zero
        isHidden = true
        session = nil
        layer?.removeAllAnimations()
        layer?.contents = nil
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

    private func sendPointerMove(_ event: NSEvent) {
        try? session?.sendPointerMove(pointerLocation(for: event))
    }

    private func sendPointerButton(_ button: RDPPointerButton, event: NSEvent, pressed: Bool) {
        try? session?.sendPointerButton(button, at: pointerLocation(for: event), pressed: pressed)
    }

    private func sendKey(_ macKeyCode: UInt16, pressed: Bool) {
        guard let scancode = RDPKeyboardMapper.scancode(for: macKeyCode) else {
            return
        }
        try? session?.sendKey(keyCode: scancode, pressed: pressed)
    }

    private func sendCommandShortcutIfNeeded(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              !event.modifierFlags.contains(.control),
              let scancode = RDPKeyboardMapper.commandShortcutScancode(for: event.keyCode) else {
            return false
        }

        try? session?.sendKey(keyCode: RDPKeyboardMapper.leftControl, pressed: true)
        try? session?.sendKey(keyCode: scancode, pressed: true)
        try? session?.sendKey(keyCode: scancode, pressed: false)
        try? session?.sendKey(keyCode: RDPKeyboardMapper.leftControl, pressed: false)
        NSLog("[RDP] command shortcut forwarded as Ctrl scancode 0x%02x", scancode)
        return true
    }

    private func updateModifier(_ scancode: UInt16, enabled: Bool) {
        if enabled {
            guard modifierState.insert(scancode).inserted else {
                return
            }
            try? session?.sendKey(keyCode: scancode, pressed: true)
        } else if modifierState.remove(scancode) != nil {
            try? session?.sendKey(keyCode: scancode, pressed: false)
        }
    }

    private func pasteOfferedFilesAfterDrop() {
        window?.makeFirstResponder(self)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, let session = self.session else { return }
            try? session.sendKey(keyCode: RDPKeyboardMapper.leftControl, pressed: true)
            try? session.sendKey(keyCode: 0x2F, pressed: true)
            try? session.sendKey(keyCode: 0x2F, pressed: false)
            try? session.sendKey(keyCode: RDPKeyboardMapper.leftControl, pressed: false)
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
}
