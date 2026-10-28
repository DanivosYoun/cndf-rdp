import AppKit
import CoreVideo
import RDPClientCore

public protocol RDPConnectionViewDelegate: AnyObject {
    func rdpConnectionView(_ view: RDPConnectionView, didLog message: String)
    func rdpConnectionView(_ view: RDPConnectionView, didChangeConnected connected: Bool)
    func rdpConnectionView(
        _ view: RDPConnectionView,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool
    func rdpConnectionView(_ view: RDPConnectionView, didFailWith error: RDPSessionError)
    func rdpConnectionView(_ view: RDPConnectionView, didDisconnectWith reason: RDPDisconnectReason)
    func rdpConnectionView(_ view: RDPConnectionView, didReceiveRemoteText text: String)
    func rdpConnectionView(_ view: RDPConnectionView, didReceiveRemoteFiles files: [RDPRemoteFile])
}

public extension RDPConnectionViewDelegate {
    func rdpConnectionView(_ view: RDPConnectionView, didLog message: String) {}
    func rdpConnectionView(_ view: RDPConnectionView, didChangeConnected connected: Bool) {}
    func rdpConnectionView(
        _ view: RDPConnectionView,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool { false }  // fail closed: a conformer that omits this must NOT auto-trust certs
    func rdpConnectionView(_ view: RDPConnectionView, didFailWith error: RDPSessionError) {}
    func rdpConnectionView(_ view: RDPConnectionView, didDisconnectWith reason: RDPDisconnectReason) {}
    func rdpConnectionView(_ view: RDPConnectionView, didReceiveRemoteText text: String) {}
    func rdpConnectionView(_ view: RDPConnectionView, didReceiveRemoteFiles files: [RDPRemoteFile]) {}
}

public struct RDPShutdownDiagnostics: Equatable {
    public var didWaitForFreeRDPWorker: Bool
    public var pendingMainQueueTasks: Int
    public var inFlightCommandBuffers: Int
    public var freeRDPWorkerWaitDurationMs: Int
    public var metalDrainDurationMs: Int

    public init(
        didWaitForFreeRDPWorker: Bool,
        pendingMainQueueTasks: Int,
        inFlightCommandBuffers: Int,
        freeRDPWorkerWaitDurationMs: Int = 0,
        metalDrainDurationMs: Int = 0
    ) {
        self.didWaitForFreeRDPWorker = didWaitForFreeRDPWorker
        self.pendingMainQueueTasks = pendingMainQueueTasks
        self.inFlightCommandBuffers = inFlightCommandBuffers
        self.freeRDPWorkerWaitDurationMs = freeRDPWorkerWaitDurationMs
        self.metalDrainDurationMs = metalDrainDurationMs
    }
}

public final class RDPConnectionView: NSView, RDPSessionDelegate {
    public weak var delegate: RDPConnectionViewDelegate?

    public let clientView: RDPClientView
    private var session: RDPSession?
    private var clipboardTimer: Timer?
    private var isShutdown = false
    private let mainCallbackLock = NSLock()
    private var pendingMainCallbacks = 0
    // Newest frame not yet shown. A frame arriving while one waits replaces it, so main
    // only ever has one frame delivery queued and stale frames never reach it.
    private let frameSlotLock = NSLock()
    private var pendingFrame: RDPFrame?
    private let pointerSlotLock = NSLock()
    private var pendingPointer: RDPRemotePointer?
    private var outputSuppression = RDPOutputSuppressionPolicy()
    private var outputSuppressionRecheck: DispatchWorkItem?
    private var occlusionObserver: NSObjectProtocol?

    public override init(frame frameRect: NSRect) {
        self.clientView = RDPClientView(frame: frameRect)
        super.init(frame: frameRect)
        configure()
    }

    public required init?(coder: NSCoder) {
        self.clientView = RDPClientView(frame: .zero)
        super.init(coder: coder)
        configure()
    }

    deinit {
        stopObservingOcclusion()
        detachSessionForAsyncDisconnect()
        clientView.shutdownRendering()
    }

    public var isConnected: Bool {
        session?.isConnected ?? false
    }

    public var statistics: RDPConnectionStatistics? {
        session?.statistics
    }

    /// Ask the server to stop sending display updates while this view's window is not
    /// visible (occluded, minimized, on another Space, screen locked). Never while a frame
    /// tap (`onRenderedFrame`) is attached. Off by default.
    public var suppressesOutputWhenHidden = false {
        didSet { evaluateOutputSuppression() }
    }

    public var onRenderedFrame: ((CVPixelBuffer, CFTimeInterval) -> Void)? {
        get {
            clientView.onRenderedFrame
        }
        set {
            clientView.onRenderedFrame = newValue
        }
    }

    public func connect(_ options: RDPConnectionOptions) throws {
        guard !isShutdown else {
            throw RDPSessionError.configurationInvalid(reason: "RDPConnectionView has been shut down.")
        }
        disconnect()

        let session = try RDPSession()
        session.delegate = self
        self.session = session
        clientView.session = session
        outputSuppression.connectionDidReset()

        try session.connect(options, initialPointSize: clientView.bounds.size, scale: desktopScale)
        clientView.sendForcedDesktopSize()
        startClipboardPolling()
        delegate?.rdpConnectionView(self, didChangeConnected: session.isConnected)
    }

    public func disconnect() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        try? session?.disconnect()
        session = nil
        clientView.session = nil
        resetOutputSuppression()
        if !isShutdown {
            delegate?.rdpConnectionView(self, didChangeConnected: false)
        }
    }

    public func reconnect() throws {
        guard !isShutdown else {
            throw RDPSessionError.configurationInvalid(reason: "RDPConnectionView has been shut down.")
        }
        resetOutputSuppression()
        try session?.reconnect()
        clientView.sendForcedDesktopSize()
    }

    @discardableResult
    public func shutdown() -> RDPShutdownDiagnostics {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                shutdown()
            }
        }

        guard !isShutdown else {
            return RDPShutdownDiagnostics(
                didWaitForFreeRDPWorker: false,
                pendingMainQueueTasks: pendingMainCallbackCount(),
                inFlightCommandBuffers: 0
            )
        }
        isShutdown = true
        resetOutputSuppression()
        stopObservingOcclusion()
        let closeWindow = prepareWindowForClose()
        let callbackDelegate = delegate
        delegate = nil
        let renderDrainStartedAt = Date()
        let inFlightCommandBuffers = clientView.shutdownRendering(waitTimeout: 1.0)
        let renderDrainDurationMs = elapsedMilliseconds(since: renderDrainStartedAt)
        let freeRDPWorkerWait = detachSessionForSynchronousDisconnect()
        drainPendingMainCallbacks(timeout: 0.25)
        detachFromWindowContent(closeWindow)
        callbackDelegate?.rdpConnectionView(self, didChangeConnected: false)
        return RDPShutdownDiagnostics(
            didWaitForFreeRDPWorker: freeRDPWorkerWait.didWait,
            pendingMainQueueTasks: pendingMainCallbackCount(),
            inFlightCommandBuffers: inFlightCommandBuffers,
            freeRDPWorkerWaitDurationMs: freeRDPWorkerWait.durationMs,
            metalDrainDurationMs: renderDrainDurationMs
        )
    }

    public func sendForcedDesktopSize() {
        clientView.sendForcedDesktopSize()
    }

    public func pollLocalClipboard() throws {
        guard !isShutdown else { return }
        try session?.pollLocalClipboard()
    }

    public func injectMouse(x: Int32, y: Int32, button: RDPMouseButton?, flags: RDPMouseFlags) {
        guard !isShutdown else { return }
        clientView.injectMouse(x: x, y: y, button: button, flags: flags)
    }

    public func injectKey(virtualKeyCode: UInt16, scanCode: UInt16, flags: RDPKeyFlags) {
        guard !isShutdown else { return }
        clientView.injectKey(virtualKeyCode: virtualKeyCode, scanCode: scanCode, flags: flags)
    }

    public func injectScroll(x: Int32, y: Int32, deltaY: Int32, deltaX: Int32) {
        guard !isShutdown else { return }
        clientView.injectScroll(x: x, y: y, deltaY: deltaY, deltaX: deltaX)
    }

    /// A new shared-input handle bound to the current native connection. A shut-down or
    /// disconnected view returns a handle that can never activate.
    @MainActor
    public func makeSharedInputSession() -> RDPSharedInputSession {
        guard !isShutdown else {
            return RDPSharedInputSession.unavailable()
        }
        return clientView.makeSharedInputSession()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingOcclusion()
        if let window, !isShutdown {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.evaluateOutputSuppression()
            }
        }
        evaluateOutputSuppression()
    }

    private func configure() {
        autoresizesSubviews = true
        clientView.frame = bounds
        clientView.autoresizingMask = [.width, .height]
        clientView.frameTapDidChange = { [weak self] in
            self?.evaluateOutputSuppression()
        }
        addSubview(clientView)
    }

    private func stopObservingOcclusion() {
        if let occlusionObserver {
            NotificationCenter.default.removeObserver(occlusionObserver)
        }
        occlusionObserver = nil
    }

    private func resetOutputSuppression() {
        outputSuppressionRecheck?.cancel()
        outputSuppressionRecheck = nil
        outputSuppression.connectionDidReset()
    }

    private func evaluateOutputSuppression() {
        guard !isShutdown else { return }
        outputSuppressionRecheck?.cancel()
        outputSuppressionRecheck = nil
        let inputs = RDPOutputSuppressionPolicy.Inputs(
            enabled: suppressesOutputWhenHidden,
            supported: session?.supportsOutputSuppression ?? false,
            connected: session?.isConnected ?? false,
            visible: window.map { $0.occlusionState.contains(.visible) } ?? true,
            frameTapAttached: clientView.onRenderedFrame != nil
        )
        switch outputSuppression.evaluate(inputs, now: ProcessInfo.processInfo.systemUptime) {
        case .none:
            break
        case .suppress:
            applyOutputSuppressed(true)
        case .release:
            applyOutputSuppressed(false)
        case .recheck(let delay):
            let workItem = DispatchWorkItem { [weak self] in
                self?.evaluateOutputSuppression()
            }
            outputSuppressionRecheck = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func applyOutputSuppressed(_ suppressed: Bool) {
        do {
            try session?.setOutputSuppressed(suppressed)
        } catch {
            delegate?.rdpConnectionView(self, didLog: "Output suppression update failed: \(error)")
        }
    }

    private var desktopScale: Double {
        Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1.0)
    }

    private func startClipboardPolling() {
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, !self.isShutdown else { return }
            do {
                try self.session?.pollLocalClipboard()
            } catch {
                self.delegate?.rdpConnectionView(self, didLog: "Local clipboard sync failed: \(error)")
            }
        }
    }

    private func prepareWindowForClose() -> NSWindow? {
        guard let window else {
            return nil
        }
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.initialFirstResponder = nil
        window.makeFirstResponder(nil)
        window.orderOut(nil)
        return window
    }

    private func detachFromWindowContent(_ window: NSWindow?) {
        guard let window, window.contentView === self else {
            removeFromSuperview()
            return
        }
        let placeholder = NSView(frame: frame)
        placeholder.autoresizingMask = [.width, .height]
        window.contentView = placeholder
    }

    private func detachSessionForAsyncDisconnect() {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        let session = session
        session?.delegate = nil
        self.session = nil
        clientView.session = nil
        guard let session else {
            return
        }
        DispatchQueue.global(qos: .utility).async {
            try? session.disconnect()
        }
    }

    private func detachSessionForSynchronousDisconnect() -> (didWait: Bool, durationMs: Int) {
        clipboardTimer?.invalidate()
        clipboardTimer = nil
        let session = session
        session?.delegate = nil
        self.session = nil
        clientView.session = nil
        guard let session else {
            return (false, 0)
        }
        let startedAt = Date()
        try? session.disconnect()
        return (true, elapsedMilliseconds(since: startedAt))
    }

    private func enqueueMainCallback(_ callback: @escaping () -> Void) {
        incrementPendingMainCallback()
        DispatchQueue.main.async { [weak self] in
            defer { self?.decrementPendingMainCallback() }
            callback()
        }
    }

    private func incrementPendingMainCallback() {
        mainCallbackLock.lock()
        pendingMainCallbacks += 1
        mainCallbackLock.unlock()
    }

    private func decrementPendingMainCallback() {
        mainCallbackLock.lock()
        pendingMainCallbacks = max(0, pendingMainCallbacks - 1)
        mainCallbackLock.unlock()
    }

    private func pendingMainCallbackCount() -> Int {
        mainCallbackLock.lock()
        defer { mainCallbackLock.unlock() }
        return pendingMainCallbacks
    }

    private func drainPendingMainCallbacks(timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingMainCallbackCount() > 0 && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
    }

    private func elapsedMilliseconds(since startDate: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startDate) * 1000))
    }

    public func rdpSessionOutputResumedForInput(_ session: RDPSession) {
        enqueueMainCallback { [weak self, weak session] in
            guard let self, !self.isShutdown, let session, self.session === session else { return }
            self.outputSuppression.outputResumedForInput()
            self.evaluateOutputSuppression()
        }
    }

    public func rdpSession(_ session: RDPSession, didLog message: String) {
        guard !isShutdown else { return }
        delegate?.rdpConnectionView(self, didLog: message)
        enqueueMainCallback { [weak self] in
            guard let self, !self.isShutdown else { return }
            if message == "FreeRDP connected." || message == "Display control channel connected." {
                self.clientView.sendForcedDesktopSize()
            }
            if message == "FreeRDP connected." {
                // A fresh FreeRDP connection starts with output allowed; re-evaluate from there.
                self.outputSuppression.connectionDidReset()
                self.evaluateOutputSuppression()
            } else if message == "FreeRDP disconnected." {
                self.evaluateOutputSuppression()
            }
            self.delegate?.rdpConnectionView(self, didChangeConnected: session.isConnected)
        }
    }

    public func rdpSession(
        _ session: RDPSession,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool {
        guard !isShutdown else { return false }
        // Fail CLOSED: with no delegate to make a trust decision, reject rather
        // than silently accepting the certificate.
        return await delegate?.rdpConnectionView(
            self,
            shouldTrustCertificateFingerprint: fingerprint,
            hostname: hostname,
            port: port
        ) ?? false
    }

    public func rdpSession(_ session: RDPSession, didFailWith error: RDPSessionError) {
        guard !isShutdown else { return }
        delegate?.rdpConnectionView(self, didFailWith: error)
    }

    public func rdpSession(_ session: RDPSession, didDisconnectWith reason: RDPDisconnectReason) {
        guard !isShutdown else { return }
        delegate?.rdpConnectionView(self, didDisconnectWith: reason)
    }

    public func rdpSession(_ session: RDPSession, didReceiveRemoteText text: String) {
        guard !isShutdown else { return }
        delegate?.rdpConnectionView(self, didReceiveRemoteText: text)
    }

    public func rdpSession(_ session: RDPSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {
        guard !isShutdown else { return }
        delegate?.rdpConnectionView(self, didReceiveRemoteFiles: files)
    }

    public func rdpSession(_ session: RDPSession, didUpdatePointer pointer: RDPRemotePointer) {
        guard !isShutdown else { return }
        pointerSlotLock.lock()
        let deliveryQueued = pendingPointer != nil
        pendingPointer = pointer
        pointerSlotLock.unlock()
        guard !deliveryQueued else { return }
        enqueueMainCallback { [weak self] in
            guard let self else { return }
            self.pointerSlotLock.lock()
            let pointer = self.pendingPointer
            self.pendingPointer = nil
            self.pointerSlotLock.unlock()
            guard !self.isShutdown, let pointer else { return }
            self.clientView.updateRemotePointer(pointer)
        }
    }

    public func rdpSession(_ session: RDPSession, didReceiveFrame frame: RDPFrame) {
        guard !isShutdown else { return }
        frameSlotLock.lock()
        let deliveryQueued = pendingFrame != nil
        pendingFrame = frame
        frameSlotLock.unlock()
        guard !deliveryQueued else { return }
        enqueueMainCallback { [weak self] in
            guard let self else { return }
            self.frameSlotLock.lock()
            let frame = self.pendingFrame
            self.pendingFrame = nil
            self.frameSlotLock.unlock()
            guard !self.isShutdown, let frame else { return }
            self.clientView.display(frame)
        }
    }
}
