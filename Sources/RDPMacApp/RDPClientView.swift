import AppKit
import MetalKit
import RDPClientCore

final class RDPClientView: MTKView {
    weak var session: RDPSession?

    private var trackingArea: NSTrackingArea?
    private var renderer: RDPMetalRenderer?
    private var modifierState: Set<UInt16> = []
    private var remoteFrameSize: CGSize = .zero
    private var pendingResizeWorkItem: DispatchWorkItem?

    override var acceptsFirstResponder: Bool {
        true
    }

    override var isFlipped: Bool {
        true
    }

    init(frame frameRect: NSRect) {
        super.init(frame: frameRect, device: MTLCreateSystemDefaultDevice())
        configure()
    }

    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        colorPixelFormat = .bgra8Unorm
        renderer = RDPMetalRenderer(view: self)
        registerForDraggedTypes([.fileURL])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        sendForcedDesktopSize()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleDesktopSize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .enabledDuringMouseDrag, .inVisibleRect],
            owner: self
        )
        trackingArea = area
        addTrackingArea(area)
    }

    override func mouseMoved(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func mouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func otherMouseDragged(with event: NSEvent) {
        sendPointerMove(event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        sendPointerButton(.left, event: event, pressed: true)
    }

    override func mouseUp(with event: NSEvent) {
        sendPointerButton(.left, event: event, pressed: false)
    }

    override func rightMouseDown(with event: NSEvent) {
        sendPointerButton(.right, event: event, pressed: true)
    }

    override func rightMouseUp(with event: NSEvent) {
        sendPointerButton(.right, event: event, pressed: false)
    }

    override func otherMouseDown(with event: NSEvent) {
        sendPointerButton(.middle, event: event, pressed: true)
    }

    override func otherMouseUp(with event: NSEvent) {
        sendPointerButton(.middle, event: event, pressed: false)
    }

    override func scrollWheel(with event: NSEvent) {
        try? session?.sendScroll(
            deltaX: Int32(event.scrollingDeltaX.rounded()),
            deltaY: Int32(event.scrollingDeltaY.rounded())
        )
    }

    override func keyDown(with event: NSEvent) {
        if sendCommandShortcutIfNeeded(event) {
            return
        }
        sendKey(event.keyCode, pressed: true)
    }

    override func keyUp(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           RDPKeyboardMapper.commandShortcutScancode(for: event.keyCode) != nil {
            return
        }
        sendKey(event.keyCode, pressed: false)
    }

    override func flagsChanged(with event: NSEvent) {
        updateModifier(RDPKeyboardMapper.leftShift, enabled: event.modifierFlags.contains(.shift))
        updateModifier(RDPKeyboardMapper.leftControl, enabled: event.modifierFlags.contains(.control))
        updateModifier(RDPKeyboardMapper.leftAlt, enabled: event.modifierFlags.contains(.option))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        fileURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
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

    func sendForcedDesktopSize() {
        pendingResizeWorkItem?.cancel()
        pendingResizeWorkItem = nil
        sendDesktopSize(force: true)
    }

    func display(_ frame: RDPFrame) {
        remoteFrameSize = CGSize(width: frame.width, height: frame.height)
        renderer?.update(frame: frame)
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
        let xRatio = bounds.width > 0 ? point.x / bounds.width : 0
        let yRatio = bounds.height > 0 ? point.y / bounds.height : 0
        let x = UInt32(max(0, min(targetWidth - 1, xRatio * targetWidth)).rounded(.toNearestOrAwayFromZero))
        let y = UInt32(max(0, min(targetHeight - 1, yRatio * targetHeight)).rounded(.toNearestOrAwayFromZero))
        return RDPPointerLocation(pixelX: x, pixelY: y)
    }

    private func sendDesktopSize(force: Bool) {
        try? session?.updateDesktopSize(
            pointWidth: Double(bounds.width),
            pointHeight: Double(bounds.height),
            scale: 1.0,
            force: force
        )
    }

    private func scheduleDesktopSize() {
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
