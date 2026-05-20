import AppKit
import RDPClientCore

final class AppDelegate: NSObject, NSApplicationDelegate, RDPSessionDelegate, ConnectionBarViewDelegate {
    private var session: RDPSession?
    private var timer: Timer?
    private var clientView: RDPClientView?
    private var connectionBar: ConnectionBarView?
    private let externalCredentialProvider = ExternalCredentialProvider()
    private var receivedFrameCount = 0
    private var lastFrameSize: CGSize = .zero
    private var didRunExplorerFilePasteAutotest = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RDP Mac"
        window.center()
        let root = NSView(frame: window.contentView?.bounds ?? .zero)
        root.autoresizingMask = [.width, .height]

        let connectionBar = ConnectionBarView(frame: NSRect(x: 0, y: root.bounds.height - 48, width: root.bounds.width, height: 48))
        connectionBar.autoresizingMask = [.width, .minYMargin]
        connectionBar.delegate = self

        let clientView = RDPClientView(frame: NSRect(x: 0, y: 0, width: root.bounds.width, height: root.bounds.height - 48))
        clientView.autoresizingMask = [.width, .height]

        root.addSubview(clientView)
        root.addSubview(connectionBar)
        window.contentView = root
        self.clientView = clientView
        self.connectionBar = connectionBar
        window.makeKeyAndOrderFront(nil)

        if let externalOptions = externalCredentialProvider.connectionOptions() {
            connectionBar.applyExternalCredentials(externalOptions)
            connectionBar.setStatus("Credentials injected")
            if externalCredentialProvider.shouldAutoConnect {
                connect(using: externalOptions, statusView: connectionBar)
            }
        }
    }

    func connectionBarDidRequestConnect(
        _ view: ConnectionBarView,
        host: String,
        port: UInt16,
        username: String,
        password: String,
        domain: String
    ) {
        guard !host.isEmpty else {
            view.setStatus("Host required")
            return
        }
        connect(
            using: RDPConnectionOptions(
                host: host,
                port: port,
                username: username.isEmpty ? nil : username,
                password: password.isEmpty ? nil : password,
                domain: domain.isEmpty ? nil : domain
            ),
            statusView: view
        )
    }

    private func connect(using options: RDPConnectionOptions, statusView view: ConnectionBarView) {
        do {
            let session = try RDPSession()
            session.delegate = self
            self.session = session
            clientView?.session = session
            try session.connect(options)
            clientView?.sendForcedDesktopSize()
            view.setConnected(true)
            view.setStatus("Connecting")
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                do {
                    try self?.session?.pollLocalClipboard()
                } catch {
                    NSLog("[RDP] local clipboard poll failed: \(String(describing: error))")
                }
            }
        } catch {
            view.setStatus("Failed: \(String(describing: error))")
        }
    }

    func connectionBarDidRequestDisconnect(_ view: ConnectionBarView) {
        timer?.invalidate()
        timer = nil
        try? session?.disconnect()
        session = nil
        clientView?.session = nil
        view.setConnected(false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        timer?.invalidate()
        try? session?.disconnect()
    }

    func rdpSession(_ session: RDPSession, didLog message: String) {
        NSLog("[RDP] \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.connectionBar?.setStatus(message)
            self?.connectionBar?.setConnected(session.isConnected)
            if message == "FreeRDP connected." || message == "Display control channel connected." {
                self?.clientView?.sendForcedDesktopSize()
            }
            if message == "Display control channel connected." {
                self?.runExplorerFilePasteAutotestIfNeeded()
            }
        }
    }

    func rdpSession(_ session: RDPSession, didReceiveRemoteText text: String) {
        NSLog("[RDP] received remote text, \(text.count) chars")
    }

    func rdpSession(_ session: RDPSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {
        NSLog("[RDP] received remote files, \(files.count) files")
    }

    func rdpSession(_ session: RDPSession, didReceiveFrame frame: RDPFrame) {
        receivedFrameCount += 1
        let frameSize = CGSize(width: frame.width, height: frame.height)
        if receivedFrameCount == 1 || receivedFrameCount % 120 == 0 || frameSize != lastFrameSize {
            NSLog("[RDP] received frame \(receivedFrameCount), \(frame.width)x\(frame.height)")
        }
        lastFrameSize = frameSize
        DispatchQueue.main.async { [weak self] in
            self?.clientView?.display(frame)
        }
    }

    private func runExplorerFilePasteAutotestIfNeeded() {
        guard !didRunExplorerFilePasteAutotest,
              ProcessInfo.processInfo.environment["RDP_MAC_AUTOTEST_EXPLORER_FILE_PASTE"] == "1",
              let session else {
            return
        }
        didRunExplorerFilePasteAutotest = true

        DispatchQueue.global(qos: .utility).async { [weak self, weak session] in
            guard let self, let session else { return }
            let testURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("rdp-mac-autotest-file-copy.txt")
            do {
                try "RDP Mac automated file copy test\n".write(to: testURL, atomically: true, encoding: .utf8)
                Thread.sleep(forTimeInterval: 1.0)
                try session.sendLocalText("explorer.exe %USERPROFILE%\\Desktop")
                try self.sendShortcut(session: session, modifiers: [RDPKeyboardMapper.leftWindows], key: 0x13)
                Thread.sleep(forTimeInterval: 1.0)
                try self.sendShortcut(session: session, modifiers: [RDPKeyboardMapper.leftControl], key: 0x2F)
                try self.sendShortcut(session: session, modifiers: [], key: 0x1C)
                Thread.sleep(forTimeInterval: 2.0)
                try session.sendLocalFiles([testURL])
                Thread.sleep(forTimeInterval: 1.0)
                try self.sendShortcut(session: session, modifiers: [RDPKeyboardMapper.leftControl], key: 0x2F)
                session.delegate?.rdpSession(session, didLog: "Explorer file paste autotest opened Desktop and sent Ctrl+V.")
                Thread.sleep(forTimeInterval: 7.0)
                try self.sendShortcut(session: session, modifiers: [RDPKeyboardMapper.leftControl], key: 0x2E)
                session.delegate?.rdpSession(session, didLog: "Explorer file copyback autotest sent Ctrl+C.")
            } catch {
                session.delegate?.rdpSession(session, didLog: "Explorer file paste autotest failed: \(error)")
            }
        }
    }

    private func sendShortcut(session: RDPSession, modifiers: [UInt16], key: UInt16) throws {
        for modifier in modifiers {
            try session.sendKey(keyCode: modifier, pressed: true)
        }
        try session.sendKey(keyCode: key, pressed: true)
        try session.sendKey(keyCode: key, pressed: false)
        for modifier in modifiers.reversed() {
            try session.sendKey(keyCode: modifier, pressed: false)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
