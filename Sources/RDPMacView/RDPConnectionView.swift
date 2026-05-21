import AppKit
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
    ) async -> Bool { true }
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
        detachSessionForAsyncDisconnect()
        clientView.shutdownRendering()
    }

    public var isConnected: Bool {
        session?.isConnected ?? false
    }

    public var statistics: RDPConnectionStatistics? {
        session?.statistics
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
        if !isShutdown {
            delegate?.rdpConnectionView(self, didChangeConnected: false)
        }
    }

    public func reconnect() throws {
        guard !isShutdown else {
            throw RDPSessionError.configurationInvalid(reason: "RDPConnectionView has been shut down.")
        }
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

    private func configure() {
        autoresizesSubviews = true
        clientView.frame = bounds
        clientView.autoresizingMask = [.width, .height]
        addSubview(clientView)
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

    public func rdpSession(_ session: RDPSession, didLog message: String) {
        guard !isShutdown else { return }
        delegate?.rdpConnectionView(self, didLog: message)
        enqueueMainCallback { [weak self] in
            guard let self, !self.isShutdown else { return }
            if message == "FreeRDP connected." || message == "Display control channel connected." {
                self.clientView.sendForcedDesktopSize()
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
        return await delegate?.rdpConnectionView(
            self,
            shouldTrustCertificateFingerprint: fingerprint,
            hostname: hostname,
            port: port
        ) ?? true
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

    public func rdpSession(_ session: RDPSession, didReceiveFrame frame: RDPFrame) {
        guard !isShutdown else { return }
        enqueueMainCallback { [weak self] in
            guard let self, !self.isShutdown else { return }
            self.clientView.display(frame)
        }
    }
}
