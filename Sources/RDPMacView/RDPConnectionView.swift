import AppKit
import RDPClientCore

public protocol RDPConnectionViewDelegate: AnyObject {
    func rdpConnectionView(_ view: RDPConnectionView, didLog message: String)
    func rdpConnectionView(_ view: RDPConnectionView, didChangeConnected connected: Bool)
    func rdpConnectionView(_ view: RDPConnectionView, didReceiveRemoteText text: String)
    func rdpConnectionView(_ view: RDPConnectionView, didReceiveRemoteFiles files: [RDPRemoteFile])
}

public extension RDPConnectionViewDelegate {
    func rdpConnectionView(_ view: RDPConnectionView, didLog message: String) {}
    func rdpConnectionView(_ view: RDPConnectionView, didChangeConnected connected: Bool) {}
    func rdpConnectionView(_ view: RDPConnectionView, didReceiveRemoteText text: String) {}
    func rdpConnectionView(_ view: RDPConnectionView, didReceiveRemoteFiles files: [RDPRemoteFile]) {}
}

public final class RDPConnectionView: NSView, RDPSessionDelegate {
    public weak var delegate: RDPConnectionViewDelegate?

    public let clientView: RDPClientView
    private var session: RDPSession?
    private var clipboardTimer: Timer?

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
        disconnect()
    }

    public var isConnected: Bool {
        session?.isConnected ?? false
    }

    public func connect(_ options: RDPConnectionOptions) throws {
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
        delegate?.rdpConnectionView(self, didChangeConnected: false)
    }

    public func sendForcedDesktopSize() {
        clientView.sendForcedDesktopSize()
    }

    public func pollLocalClipboard() throws {
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
            guard let self else { return }
            do {
                try self.session?.pollLocalClipboard()
            } catch {
                self.delegate?.rdpConnectionView(self, didLog: "Local clipboard sync failed: \(error)")
            }
        }
    }

    public func rdpSession(_ session: RDPSession, didLog message: String) {
        delegate?.rdpConnectionView(self, didLog: message)
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if message == "FreeRDP connected." || message == "Display control channel connected." {
                self.clientView.sendForcedDesktopSize()
            }
            self.delegate?.rdpConnectionView(self, didChangeConnected: session.isConnected)
        }
    }

    public func rdpSession(_ session: RDPSession, didReceiveRemoteText text: String) {
        delegate?.rdpConnectionView(self, didReceiveRemoteText: text)
    }

    public func rdpSession(_ session: RDPSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {
        delegate?.rdpConnectionView(self, didReceiveRemoteFiles: files)
    }

    public func rdpSession(_ session: RDPSession, didReceiveFrame frame: RDPFrame) {
        DispatchQueue.main.async { [weak self] in
            self?.clientView.display(frame)
        }
    }
}
