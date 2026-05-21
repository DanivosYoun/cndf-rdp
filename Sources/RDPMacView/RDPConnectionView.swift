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

public final class RDPConnectionView: NSView, RDPSessionDelegate {
    public weak var delegate: RDPConnectionViewDelegate?

    public let clientView: RDPClientView
    private var session: RDPSession?
    private var clipboardTimer: Timer?
    private var isShutdown = false

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

        try session.connect(options)
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

    public func shutdown() {
        guard !isShutdown else {
            return
        }
        isShutdown = true
        prepareWindowForClose()
        let callbackDelegate = delegate
        delegate = nil
        clientView.shutdownRendering()
        detachSessionForAsyncDisconnect()
        callbackDelegate?.rdpConnectionView(self, didChangeConnected: false)
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

    private func prepareWindowForClose() {
        guard let window else {
            return
        }
        window.animationBehavior = .none
        window.orderOut(nil)
        retainThroughCloseDrain(window: window)
    }

    private func retainThroughCloseDrain(window: NSWindow) {
        let retainedView = self
        let retainedWindow = window
        DispatchQueue.main.async {
            DispatchQueue.main.async {
                _ = retainedView
                _ = retainedWindow
            }
        }
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

    public func rdpSession(_ session: RDPSession, didLog message: String) {
        guard !isShutdown else { return }
        delegate?.rdpConnectionView(self, didLog: message)
        DispatchQueue.main.async { [weak self] in
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
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isShutdown else { return }
            self.clientView.display(frame)
        }
    }
}
