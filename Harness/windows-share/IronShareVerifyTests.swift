import XCTest
import AppKit
import CoreVideo
import RDPClientCore
import RDPMacView
@testable import CNDFTerminalTools

// iron-share-verify: a live RDP share against the isolated relay.
//
// Host: a real RDPConnectionView (IronRDP or FreeRDP) to the Windows test server, a real
// SessionShareController host session, RDPSessionShareHost (frame tap + HEVC), and the share's
// input pipeline installed through RDPShareCoordinator.installActiveShareForTesting — the same
// activateInput / installInputOwnerCallbacks / RDPShareInputOwners / CNDFRDPInputBackend path
// performStart goes live with. Only the invite dialog and the toolbar UI are skipped.
// Viewers: WebSocket clients with their own dev principal (X-CNDF-Dev-Principal), so two viewers
// and a second connection of the same account have distinct relay identities in one process.
// Lifecycle rows send raw 0x21/0x22 frames (a viewer that never releases anything itself); the
// 104 rows drive the app's real SharedRDPViewerView → RDPInputForwarder with scripted NSEvents and
// a scripted Mac input source.
// Windows side: Harness/windows-share/shareprobe.ps1 logs keys, clicks, held keys and screen size.
// Rows are separated by an F7 tap the host injects locally. Every step is also written to
// $ISV_OUT/<run>.mac.jsonl.
//
// Mac working copy only; never committed to the app repository.

// MARK: - Event log

@MainActor
final class ISVLog {
    private let handle: FileHandle
    init(path: String) {
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)!
    }
    func write(_ event: String, _ fields: [String: Any] = [:]) {
        var object = fields
        object["t"] = Int(Date().timeIntervalSince1970 * 1000)
        object["ev"] = event
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        handle.write(data + Data("\n".utf8))
        print("[ISV] \(event) \(fields)")
    }
}

// MARK: - Windows connection

@MainActor
final class ISVWindow: NSWindow {
    var simulatedBackingScale: CGFloat?
    override var backingScaleFactor: CGFloat { simulatedBackingScale ?? super.backingScaleFactor }
}

@MainActor
final class ISVConnection: NSObject, RDPConnectionViewDelegate {
    let window: ISVWindow
    let view: RDPConnectionView
    private(set) var frameSize = CGSize.zero
    private(set) var frames = 0
    private(set) var failure: String?
    private(set) var disconnected = false
    private(set) var logLines: [String] = []

    init(size: CGSize, backingScale: CGFloat? = nil) {
        _ = NSApplication.shared
        window = ISVWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        window.simulatedBackingScale = backingScale
        window.isReleasedWhenClosed = false
        view = RDPConnectionView(frame: CGRect(origin: .zero, size: size))
        super.init()
        window.contentView = view
        window.orderFront(nil)
        view.delegate = self
        installFrameCounter()
    }

    func installFrameCounter() {
        view.onRenderedFrame = { [weak self] buffer, _ in
            let size = CGSize(width: CGFloat(CVPixelBufferGetWidth(buffer)), height: CGFloat(CVPixelBufferGetHeight(buffer)))
            MainActor.assumeIsolated {
                self?.frameSize = size
                self?.frames += 1
            }
        }
    }

    func connect(engine: RDPEngineKind, port: UInt16, password: String, forcedSize: CGSize? = nil) async throws {
        try view.connect(RDPConnectionOptions(
            host: "127.0.0.1", port: port, username: "Administrator",
            securePassword: RDPSecureString(password), enableClipboard: false,
            forcedDesktopSize: forcedSize, engine: engine, keyboardProfile: .korean
        ))
        guard await ISV.wait(40, { self.frameSize != .zero || self.failure != nil }), frameSize != .zero else {
            throw NSError(domain: "ISV", code: 1, userInfo: [NSLocalizedDescriptionKey: "no first frame: \(failure ?? "-")"])
        }
    }

    func resize(_ size: CGSize) {
        window.setContentSize(size)
        view.frame = CGRect(origin: .zero, size: size)
    }

    func close() {
        view.onRenderedFrame = nil
        _ = view.shutdown()
        window.close()
    }

    /// Local host keyboard: F7 is the row marker of the Windows log.
    func tap(scanCode: UInt16, macKey: UInt16) async {
        view.injectKey(virtualKeyCode: macKey, scanCode: scanCode, flags: .down)
        try? await Task.sleep(for: .milliseconds(40))
        view.injectKey(virtualKeyCode: macKey, scanCode: scanCode, flags: .up)
        try? await Task.sleep(for: .milliseconds(250))
    }

    func click(_ x: Int32, _ y: Int32) async {
        view.injectMouse(x: x, y: y, button: .left, flags: .down)
        try? await Task.sleep(for: .milliseconds(40))
        view.injectMouse(x: x, y: y, button: .left, flags: .up)
        try? await Task.sleep(for: .milliseconds(200))
    }

    nonisolated func rdpConnectionView(_ view: RDPConnectionView, shouldTrustCertificateFingerprint fingerprint: String,
                                       hostname: String, port: UInt16) async -> Bool {
        hostname == "127.0.0.1"
    }
    nonisolated func rdpConnectionView(_ view: RDPConnectionView, didLog message: String) {
        Task { @MainActor in self.logLines.append(message) }
    }
    nonisolated func rdpConnectionView(_ view: RDPConnectionView, didFailWith error: RDPSessionError) {
        Task { @MainActor in self.failure = "\(error)" }
    }
    nonisolated func rdpConnectionView(_ view: RDPConnectionView, didDisconnectWith reason: RDPDisconnectReason) {
        Task { @MainActor in self.disconnected = true }
    }
}

// MARK: - Relay REST

enum ISV {
    static let relay = URL(string: ProcessInfo.processInfo.environment["CNDF_SESSION_RELAY_URL"] ?? "http://localhost:28080")!
    static let control = URL(string: ProcessInfo.processInfo.environment["ISV_CONTROL_URL"] ?? "http://localhost:28081")!

    @MainActor
    static func wait(_ timeout: TimeInterval, _ predicate: () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate(), ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    static func rest(_ method: String, _ path: String, principal: String? = nil,
                     body: Any? = nil, base: URL = relay) async throws -> (Int, Data) {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!.absoluteURL)
        request.httpMethod = method
        request.timeoutInterval = 60
        if let principal { request.setValue(principal, forHTTPHeaderField: "X-CNDF-Dev-Principal") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? -1, data)
    }

    /// Host (dev-user) invites `oid` with write permission; returns the one-shot token.
    static func invite(_ sessionID: String, _ oid: String) async throws -> String {
        let (code, data) = try await rest("POST", "v1/share/sessions/\(sessionID)/invite",
                                          body: ["invitees": [["oid": oid, "permission": "write"]]])
        guard (200..<300).contains(code),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = (json["invitations"] as? [[String: Any]])?.first?["token"] as? String else {
            throw NSError(domain: "ISV", code: code, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return token
    }

    static func setPermission(_ sessionID: String, _ oid: String, _ permission: String) async throws -> Int {
        try await rest("PATCH", "v1/share/sessions/\(sessionID)/permission",
                       body: ["viewerOid": oid, "permission": permission]).0
    }
}

// MARK: - Viewer client

/// One viewer WebSocket with its own relay identity. Also an `RDPInputFrameSending`, so the real
/// RDPInputForwarder can send through it.
final class ISVViewer: NSObject, RDPInputFrameSending, URLSessionWebSocketDelegate, @unchecked Sendable {
    let oid: String
    private let lock = NSLock()
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var wsURL: URL?
    private var generation = 0
    private var _open = false
    private var _videoFrames = 0
    private var _shareStates = 0
    private var _bye = false
    private var _closedAt: Date?

    var isOpen: Bool { lock.withLock { _open } }
    var videoFrames: Int { lock.withLock { _videoFrames } }
    var shareStates: Int { lock.withLock { _shareStates } }
    var gotBye: Bool { lock.withLock { _bye } }

    init(oid: String) {
        self.oid = oid
        super.init()
        session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
    }

    func accept(token: String) async throws {
        let (code, data) = try await ISV.rest("POST", "v1/share/invitations/\(token)/accept", principal: oid)
        guard code == 200, let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["wsURL"] as? String, var comps = URLComponents(string: raw) else {
            throw NSError(domain: "ISV", code: code, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        if comps.scheme == "http" { comps.scheme = "ws" } else if comps.scheme == "https" { comps.scheme = "wss" }
        wsURL = comps.url
    }

    /// Opens a new connection (the previous one, if any, is left as it is — `close()` it first to
    /// leave, keep it to model a second connection of the same account).
    @discardableResult
    func connect() -> Int {
        var request = URLRequest(url: wsURL!)
        request.setValue(oid, forHTTPHeaderField: "X-CNDF-Dev-Principal")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 << 20
        let gen: Int = lock.withLock {
            generation += 1
            self.task = task
            _open = false
            return generation
        }
        task.resume()
        receive(task, gen)
        return gen
    }

    /// The task of the current connection, so an older one can still be written to.
    var currentTask: URLSessionWebSocketTask? { lock.withLock { task } }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.lock.withLock { if self.generation == gen { self._open = false; self._closedAt = Date() } }
            case .success(let message):
                if case .data(var data) = message, let frames = try? SessionShareWire.decodeAll(buffer: &data) {
                    self.lock.withLock {
                        if self.generation == gen { self._open = true }
                        for frame in frames {
                            switch frame.type {
                            case .rdpVideo: self._videoFrames += 1
                            case .shareState: self._shareStates += 1
                            case .bye: self._bye = true
                            default: break
                            }
                        }
                    }
                }
                self.receive(task, gen)
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        lock.withLock { if webSocketTask === task { _open = true } }
    }

    func close() {
        currentTask?.cancel(with: .goingAway, reason: nil)
        lock.withLock { _open = false }
    }

    func send(_ frame: SessionShareFrame, on task: URLSessionWebSocketTask? = nil) async throws {
        guard let task = task ?? currentTask else { return }
        try await task.send(.data(SessionShareWire.encode(frame)))
    }

    func key(_ code: UInt16, _ pressed: Bool, mods: UInt32 = 0, on task: URLSessionWebSocketTask? = nil) async throws {
        try await send(try SessionShareWire.makeJSONFrame(type: .rdpInputKey, value: RDPKeyEvent(
            virtualKeyCode: code, scanCode: code, pressed: pressed, modifiers: mods)), on: task)
    }

    func tap(_ code: UInt16, on task: URLSessionWebSocketTask? = nil) async throws {
        try await key(code, true, on: task)
        try await Task.sleep(for: .milliseconds(40))
        try await key(code, false, on: task)
    }

    func mouse(_ x: Int32, _ y: Int32, _ button: String, _ pressed: Bool) async throws {
        try await send(try SessionShareWire.makeJSONFrame(type: .rdpInputMouse, value: RDPMouseEvent(
            x: x, y: y, button: button, pressed: pressed)))
    }

    @MainActor
    func sendRDPFrame(_ frame: SessionShareFrame) async throws {
        try await send(frame)
    }
}

// MARK: - Real viewer view with a scripted input source

// One subclass per viewer, so each viewer Mac has its own scripted input source.
@MainActor
final class ISVViewerViewA: SharedRDPViewerView {
    nonisolated(unsafe) static var language: RDPInputLanguage = .other
    nonisolated(unsafe) static var sourceID: String? = "com.apple.keylayout.ABC"
    override class func currentKeyboardInputLanguage() -> RDPInputLanguage { language }
    override class func currentKeyboardInputSourceID() -> String? { sourceID }
}

@MainActor
final class ISVViewerViewB: SharedRDPViewerView {
    nonisolated(unsafe) static var language: RDPInputLanguage = .other
    nonisolated(unsafe) static var sourceID: String? = "com.apple.keylayout.ABC"
    override class func currentKeyboardInputLanguage() -> RDPInputLanguage { language }
    override class func currentKeyboardInputSourceID() -> String? { sourceID }
}

@MainActor
final class ISVRealViewer {
    let client: ISVViewer
    let view: SharedRDPViewerView
    let forwarder: RDPInputForwarder
    let window: NSWindow
    let center = NotificationCenter()
    private let setSource: (RDPInputLanguage, String) -> Void

    init(client: ISVViewer, follow: Bool, slotA: Bool) {
        self.client = client
        if slotA {
            ISVViewerViewA.language = .other; ISVViewerViewA.sourceID = "com.apple.keylayout.ABC"
            view = ISVViewerViewA(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
            setSource = { ISVViewerViewA.language = $0; ISVViewerViewA.sourceID = $1 }
        } else {
            ISVViewerViewB.language = .other; ISVViewerViewB.sourceID = "com.apple.keylayout.ABC"
            view = ISVViewerViewB(frame: NSRect(x: 0, y: 0, width: 1280, height: 800))
            setSource = { ISVViewerViewB.language = $0; ISVViewerViewB.sourceID = $1 }
        }
        view.hostFrameSize = CGSize(width: 1280, height: 800)
        view.followNotificationCenter = center
        view.followSwitchHotkeysProvider = { RDPSymbolicHotKeys.defaultSwitchHotkeys }
        view.composedTextInputEnabled = false
        view.inputEnabled = true
        view.inputSourceFollowEnabled = follow
        window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 1280, height: 800),
                          styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        forwarder = RDPInputForwarder(sender: client, scrollEncoding: .rdpWheelRotation)
        forwarder.setPermission(.input)
        view.delegate = forwarder
        view.followFocusOverrideForTesting = true
    }

    /// The follower settles on the current source before it acts on changes.
    func settle() async {
        try? await Task.sleep(for: .milliseconds(Int(RDPInputSourceFollower.defaultSettleInterval * 1000) + 100))
        view.handleFollowSettleElapsed()
    }

    private func event(_ type: NSEvent.EventType, _ code: UInt16, _ mods: NSEvent.ModifierFlags, repeatKey: Bool = false) -> NSEvent {
        NSEvent.keyEvent(with: type, location: .zero, modifierFlags: mods,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: repeatKey, keyCode: code)!
    }

    func down(_ code: UInt16, _ mods: NSEvent.ModifierFlags = [], repeatKey: Bool = false) { view.keyDown(with: event(.keyDown, code, mods, repeatKey: repeatKey)) }
    func up(_ code: UInt16, _ mods: NSEvent.ModifierFlags = []) { view.keyUp(with: event(.keyUp, code, mods)) }
    func flags(_ mods: NSEvent.ModifierFlags, _ code: UInt16) { view.flagsChanged(with: event(.flagsChanged, code, mods)) }

    func source(korean: Bool) {
        setSource(korean ? .korean : .other, korean ? "com.apple.inputmethod.Korean.2SetKorean" : "com.apple.keylayout.ABC")
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
    }

    func flush() async {
        forwarder.waitForPendingSends()
        try? await Task.sleep(for: .milliseconds(60))
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

// MARK: - Host share

@MainActor
final class ISVShare {
    let controller: SessionShareController
    let coordinator: RDPShareCoordinator
    let host: RDPSessionShareHost
    let tap: CNDFRDPFrameTapSource
    let sessionID: String

    init(connection: ISVConnection, log: ISVLog) async throws {
        controller = SessionShareController(sessionKind: .rdp)
        try await controller.startHostSession(resourceID: "iron-share-rdp", title: "iron-share", kind: "rdp")
        guard case .connected(let id, _, _, _) = controller.state else {
            throw NSError(domain: "ISV", code: 2, userInfo: [NSLocalizedDescriptionKey: "host not connected"])
        }
        sessionID = id
        tap = CNDFRDPFrameTapSource(connectionView: connection.view)
        host = RDPSessionShareHost(tapSource: tap, controller: controller)
        controller.startQualitySession(host: host, preset: nil)
        let view = connection.view
        controller.onViewerJoined = { [weak host] viewer in
            host?.handleKeyframeRequest(reason: "viewer_join:\(viewer.oid)")
            view.sendForcedDesktopSize()
        }
        try host.start()
        coordinator = RDPShareCoordinator(
            window: connection.window, rdpView: connection.view,
            resource: TerminalResource(type: "rdp", id: "iron-share-rdp", name: "iron-share", host: "127.0.0.1",
                                       port: 33389, user: "Administrator", auth: AuthConfig(type: .password),
                                       rdpConfig: RDPConfig(port: 33389, resolution: "fullscreen", colorDepth: 32,
                                                            audioMode: "off", clipboardEnabled: false, driveRedirect: nil)),
            sessionID: UUID(), auditEmitter: { _ in })
        // performStart's remote-end wiring (onBye / onStateChange .ended → handleRemoteStop, which is
        // beginStop without a relay disconnect). The test seam does not install it; stop(reason:) is
        // the same beginStop path with a (harmless) relay disconnect.
        let coordinator = self.coordinator
        controller.onBye = { [weak coordinator] _ in
            Task { @MainActor in await coordinator?.stop(reason: "host_request") }
        }
        controller.onStateChange = { [weak coordinator] state in
            if case .ended = state { Task { @MainActor in await coordinator?.stop(reason: "ended") } }
        }
        let backend = CNDFRDPInputBackend(connectionView: connection.view)
        coordinator.installActiveShareForTesting(
            host: host, controller: controller, tapSource: tap,
            injector: RDPInputInjector(backend: backend), inputBackend: backend, relaySessionID: id)
        log.write("share_started", ["session": id, "epoch": controller.relayInputActorEpoch ?? "-"])
    }

    var isConnected: Bool {
        if case .connected = controller.state { return true }
        return false
    }

    func stop() async {
        await coordinator.stop(reason: "host_request")
    }
}

// MARK: - Test

@MainActor
final class IronShareVerifyTests: XCTestCase {
    private var log: ISVLog!
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    // Mac keycodes and the Windows VK the probe logs for them.
    private let kA: UInt16 = 0, kB: UInt16 = 11, kC: UInt16 = 8, kD: UInt16 = 2, kE: UInt16 = 14
    private let kX: UInt16 = 7, kZ: UInt16 = 6, kQ: UInt16 = 12, k104: UInt16 = 104
    private let ctrlBit: UInt32 = 1 << 9
    private let kLCtrl: UInt16 = 59

    private func marker(_ conn: ISVConnection, _ row: String) async {
        log.write("row", ["row": row])
        await conn.tap(scanCode: 0x41, macKey: 98) // F7
    }

    private func pause(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    func testIronShareVerify() async throws {
        fputs("ISV testRun entered mode=\(env["ISV_MODE"] ?? "nil")\n", stderr)
        guard let passwordFile = env["ISV_PASSWORD_FILE"], let out = env["ISV_OUT"], let mode = env["ISV_MODE"] else {
            throw XCTSkip("ISV_PASSWORD_FILE / ISV_OUT / ISV_MODE not set")
        }
        let run = env["ISV_RUN"] ?? "isv"
        log = ISVLog(path: "\(out)/\(run).mac.jsonl")
        let password = try String(contentsOfFile: passwordFile, encoding: .utf8).trimmingCharacters(in: .newlines)
        let engine: RDPEngineKind = env["ISV_ENGINE"] == "freeRDP" ? .freeRDP : .ironRDP
        let port = UInt16(env["ISV_PORT"] ?? "33389")!
        log.write("start", ["mode": mode, "engine": engine.rawValue, "run": run])
        switch mode {
        case "share": try await runShare(engine: engine, port: port, password: password)
        case "display": try await runDisplay(engine: engine, port: port, password: password)
        default: XCTFail("unknown mode \(mode)")
        }
        log.write("end")
    }

    // MARK: Share rows (1) and 104 rows (2)

    private func runShare(engine: RDPEngineKind, port: UInt16, password: String) async throws {
        let conn = ISVConnection(size: CGSize(width: 1280, height: 800))
        defer { conn.close() }
        try await conn.connect(engine: engine, port: port, password: password)
        log.write("connected", ["frame": "\(conn.frameSize)"])
        // The probe starts at logon; give it and the desktop time to come up, then focus its box.
        await pause(Int(env["ISV_LOGON_WAIT_MS"] ?? "35000")!)
        await conn.click(100, 40)

        var share = try await ISVShare(connection: conn, log: log)
        let a = ISVViewer(oid: "viewer-a"), b = ISVViewer(oid: "viewer-b")
        try await a.accept(token: ISV.invite(share.sessionID, a.oid))
        try await b.accept(token: ISV.invite(share.sessionID, b.oid))
        a.connect(); b.connect()
        let joined = await ISV.wait(15) { a.isOpen && b.isOpen && a.videoFrames > 0 && b.videoFrames > 0 }
        log.write("viewers_joined", ["ok": joined, "aVideo": a.videoFrames, "bVideo": b.videoFrames,
                                     "epoch": share.controller.relayInputActorEpoch ?? "-"])
        await pause(1500)

        let rows = Set((env["ISV_ROWS"] ?? "S1,S2,S3,S4K,S4T,S5,K,S6").split(separator: ",").map(String.init))

        // S1 permission revoke: A holds left Ctrl, A and the left button, B then presses B.
        if rows.contains("S1") {
            await marker(conn, "S1")
            try await a.key(kLCtrl, true, mods: ctrlBit)
            try await a.key(kA, true, mods: ctrlBit)
            try await a.send(try SessionShareWire.makeJSONFrame(type: .rdpInputMouse, value: RDPMouseEvent(
                x: 300, y: 300, button: "left", pressed: true, modifiers: ctrlBit)))
            await pause(300)
            try await b.key(kB, true)
            await pause(800)
            let code = try await ISV.setPermission(share.sessionID, a.oid, "read")
            log.write("revoke", ["oid": a.oid, "code": code])
            await pause(1200)
            try await a.tap(kD)            // revoked: must not arrive
            try await b.tap(kC)            // other viewer: must arrive
            await pause(500)
            try await b.key(kB, false)
            await pause(500)
            let back = try await ISV.setPermission(share.sessionID, a.oid, "write")
            log.write("restore", ["oid": a.oid, "code": back])
            await pause(1200)
            try await a.tap(kE)            // restored: must arrive
            await pause(600)
        }

        // S2 viewer leaves while holding A; B keeps typing.
        if rows.contains("S2") {
            await marker(conn, "S2")
            try await a.key(kA, true)
            try await b.key(kB, true)
            await pause(800)
            a.close()
            log.write("leave", ["oid": a.oid])
            await pause(2500)
            try await b.tap(kC)
            await pause(400)
            try await b.key(kB, false)
            await pause(400)
            a.connect()
            let back = await ISV.wait(15) { a.isOpen }
            log.write("rejoin", ["ok": back])
            await pause(1500)
            try await a.tap(kE)
            await pause(600)
        }

        // S3 the same account opens a second connection while the first holds A.
        if rows.contains("S3") {
            await marker(conn, "S3")
            let first = a.currentTask
            try await a.key(kA, true)
            try await b.key(kB, true)
            await pause(800)
            a.connect()
            let second = await ISV.wait(15) { a.isOpen }
            log.write("replace", ["ok": second])
            await pause(1000)
            try await a.tap(kE)                         // new connection: must arrive, A released
            await pause(800)
            try? await a.tap(kD, on: first)             // old connection: must not arrive
            await pause(600)
            try await b.tap(kC)
            await pause(400)
            try await b.key(kB, false)
            await pause(600)
        }

        // S4K relay crash (SIGKILL, then start) and S4T relay restart (SIGTERM: the relay ends its
        // sessions) while A holds A and B holds B.
        for (row, mode) in [("S4K", "kill"), ("S4T", "term")] where rows.contains(row) {
            await marker(conn, row)
            let epochBefore = share.controller.relayInputActorEpoch ?? "-"
            try await a.key(kA, true)
            try await b.key(kB, true)
            await pause(800)
            let restart = try await ISV.rest("POST", "restart-relay?mode=\(mode)", base: ISV.control)
            log.write("relay_restarted", ["mode": mode, "code": restart.0, "body": String(decoding: restart.1, as: UTF8.self)])
            let t0 = Date()
            let hostBack = await ISV.wait(mode == "kill" ? 60 : 20) {
                (share.isConnected && (share.controller.relayInputActorEpoch ?? "-") != epochBefore) || !share.coordinator.isSharing
            }
            log.write("host_after_restart", ["ok": hostBack, "s": Date().timeIntervalSince(t0), "sharing": share.coordinator.isSharing,
                                             "state": "\(share.controller.state)".prefix(80).description,
                                             "epochBefore": epochBefore, "epochAfter": share.controller.relayInputActorEpoch ?? "-"])
            if !share.coordinator.isSharing {
                // The share ended: start a new one, as the host would.
                await share.stop()
                share = try await ISVShare(connection: conn, log: log)
                try await a.accept(token: ISV.invite(share.sessionID, a.oid))
                try await b.accept(token: ISV.invite(share.sessionID, b.oid))
                log.write("share_restarted", ["s": Date().timeIntervalSince(t0)])
            }
            for viewer in [a, b] {
                var ok = false
                for _ in 0..<20 where !ok {
                    viewer.connect()
                    ok = await ISV.wait(3) { viewer.isOpen }
                }
                log.write("viewer_reconnected", ["oid": viewer.oid, "ok": ok, "s": Date().timeIntervalSince(t0)])
            }
            await pause(2500)
            try? await a.tap(kX)
            try? await b.tap(kZ)
            await pause(800)
        }

        // S5 host resize while A holds A.
        if rows.contains("S5") {
            await marker(conn, "S5")
            try await a.key(kA, true)
            await pause(600)
            let videoBefore = b.videoFrames
            conn.resize(CGSize(width: 1024, height: 768))
            // The share's frame tap owns onRenderedFrame now; it records the rendered size.
            let resized = await ISV.wait(15) { share.tap.renderedFrameSize == CGSize(width: 1024, height: 768) }
            await pause(1500)
            log.write("host_resized", ["ok": resized, "frame": "\(share.tap.renderedFrameSize)", "videoAfter": b.videoFrames - videoBefore])
            try await b.tap(kC)
            await pause(400)
            try await a.key(kA, false)
            await pause(400)
            conn.resize(CGSize(width: 1280, height: 800))
            let back = await ISV.wait(15) { share.tap.renderedFrameSize == CGSize(width: 1280, height: 800) }
            log.write("host_resized_back", ["ok": back, "frame": "\(share.tap.renderedFrameSize)"])
            await pause(800)
            await conn.click(100, 40)
        }

        // (2) 104 rows through the real viewer path: A follows the Mac input source, B is the
        // pre-follow (follow off) path.
        if rows.contains("K") {
            try await runKeyRows(conn: conn, share: share, a: a, b: b)
        }

        // S6 host ends the share while A holds A and the left button and B holds B.
        if rows.contains("S6") {
            await marker(conn, "S6")
            try await a.key(kA, true)
            try await a.mouse(400, 400, "left", true)
            try await b.key(kB, true)
            await pause(800)
            await share.stop()
            log.write("host_stopped")
            let bye = await ISV.wait(10) { (a.gotBye || !a.isOpen) && (b.gotBye || !b.isOpen) }
            log.write("viewers_after_stop", ["ok": bye, "aBye": a.gotBye, "bBye": b.gotBye, "aOpen": a.isOpen, "bOpen": b.isOpen])
            await pause(1000)
        }
        await marker(conn, "END")
        a.close(); b.close()
        await pause(500)
    }

    private func runKeyRows(conn: ISVConnection, share: ISVShare, a: ISVViewer, b: ISVViewer) async throws {
        let follow = ISVRealViewer(client: a, follow: true, slotA: true)
        let legacy = ISVRealViewer(client: b, follow: false, slotA: false)
        defer { follow.close(); legacy.close() }
        await follow.settle()
        await legacy.settle()
        let control: NSEvent.ModifierFlags = .control, option: NSEvent.ModifierFlags = .option

        // After every row: a plain Q tap from the same viewer must arrive without any modifier.
        func check(_ v: ISVRealViewer) async {
            await pause(500)
            v.down(kQ); await v.flush(); await pause(40); v.up(kQ); await v.flush()
            await pause(400)
        }
        func tap104(_ v: ISVRealViewer, repeats: Int = 0) async {
            v.down(k104); await v.flush()
            for _ in 0..<repeats { await pause(80); v.down(k104, repeatKey: true); await v.flush() }
            await pause(60)
            v.up(k104); await v.flush()
        }
        let rows: [(String, ISVRealViewer, () async throws -> Void)] = [
            ("K1-legacy-tap", legacy, { await tap104(legacy) }),
            ("K2-legacy-repeat", legacy, { await tap104(legacy, repeats: 3) }),
            ("K3-follow-tap", follow, { await tap104(follow) }),
            ("K4-follow-repeat", follow, { await tap104(follow, repeats: 3) }),
            ("K5-follow-src-between", follow, {
                follow.down(self.k104); await follow.flush(); await self.pause(30)
                follow.source(korean: true); await follow.flush(); await self.pause(60)
                follow.up(self.k104); await follow.flush()
                await self.pause(900)
                follow.source(korean: false); await follow.flush()   // back to ABC: one follow tap
            }),
            ("K6-legacy-src-between", legacy, {
                legacy.down(self.k104); await legacy.flush(); await self.pause(30)
                legacy.source(korean: true); await legacy.flush(); await self.pause(60)
                legacy.up(self.k104); await legacy.flush()
                await self.pause(900)
                legacy.source(korean: false); await legacy.flush()
            }),
            ("K7-follow-ctrl", follow, {
                follow.flags(control, 59); await follow.flush(); await self.pause(60)
                follow.down(self.k104, control); await follow.flush(); await self.pause(40)
                follow.up(self.k104, control); await follow.flush(); await self.pause(60)
                follow.flags([], 59); await follow.flush()
            }),
            ("K8-follow-alt", follow, {
                follow.flags(option, 58); await follow.flush(); await self.pause(60)
                follow.down(self.k104, option); await follow.flush(); await self.pause(40)
                follow.up(self.k104, option); await follow.flush(); await self.pause(60)
                follow.flags([], 58); await follow.flush()
            }),
            ("K9-legacy-ctrl", legacy, {
                legacy.flags(control, 59); await legacy.flush(); await self.pause(60)
                legacy.down(self.k104, control); await legacy.flush(); await self.pause(40)
                legacy.up(self.k104, control); await legacy.flush(); await self.pause(60)
                legacy.flags([], 59); await legacy.flush()
            }),
            ("K10-legacy-alt", legacy, {
                legacy.flags(option, 58); await legacy.flush(); await self.pause(60)
                legacy.down(self.k104, option); await legacy.flush(); await self.pause(40)
                legacy.up(self.k104, option); await legacy.flush(); await self.pause(60)
                legacy.flags([], 58); await legacy.flush()
            }),
            ("K11-follow-focus-loss", follow, {
                follow.flags(control, 59); await follow.flush()
                follow.down(self.k104, control); await follow.flush(); await self.pause(60)
                follow.forwarder.releaseHeldInput(); await follow.flush()   // windowDidResignKey
                await self.pause(200)
                follow.up(self.k104, control); follow.flags([], 59); await follow.flush()
            }),
            ("K12-follow-revoke", follow, {
                follow.flags(control, 59); await follow.flush()
                follow.down(self.k104, control); await follow.flush(); await self.pause(60)
                let code = try await ISV.setPermission(share.sessionID, a.oid, "read")
                follow.forwarder.setPermission(.view); await follow.flush()
                self.log.write("revoke", ["oid": a.oid, "code": code])
                await self.pause(1200)
                follow.up(self.k104, control); follow.flags([], 59); await follow.flush()
                let back = try await ISV.setPermission(share.sessionID, a.oid, "write")
                follow.forwarder.setPermission(.input)
                self.log.write("restore", ["oid": a.oid, "code": back])
                await self.pause(1200)
            }),
            ("K13-both-viewers", follow, {
                follow.down(self.k104); legacy.down(self.k104)
                await follow.flush(); await legacy.flush(); await self.pause(60)
                follow.up(self.k104); legacy.up(self.k104)
                await follow.flush(); await legacy.flush()
            }),
        ]
        let wanted = env["ISV_KROWS"].map { Set($0.split(separator: ",").map(String.init)) }
        for (name, viewer, body) in rows where wanted?.contains(String(name.split(separator: "-")[0])) ?? true {
            await marker(conn, name)
            try await body()
            await check(viewer)
            if name.hasPrefix("K13") { await check(legacy) }
            await pause(600)
        }
    }

    // MARK: Resize rows (3) and pixel / click rows (4)

    private func runDisplay(engine: RDPEngineKind, port: UInt16, password: String) async throws {
        let reps = Int(env["ISV_REPS"] ?? "3")!
        // R: continuous resize (H.264 active: the probe animates). Last request wins.
        do {
            let conn = ISVConnection(size: CGSize(width: 1280, height: 800))
            try await conn.connect(engine: engine, port: port, password: password)
            await pause(Int(env["ISV_LOGON_WAIT_MS"] ?? "35000")!)
            await conn.click(100, 40)
            let sequences: [[CGSize]] = [
                [CGSize(width: 1100, height: 700), CGSize(width: 900, height: 650), CGSize(width: 1200, height: 760),
                 CGSize(width: 1000, height: 720), CGSize(width: 1180, height: 740), CGSize(width: 1060, height: 690)],
                [CGSize(width: 1024, height: 768), CGSize(width: 1280, height: 720), CGSize(width: 960, height: 640),
                 CGSize(width: 1240, height: 780), CGSize(width: 1120, height: 700), CGSize(width: 1300, height: 820)],
                [CGSize(width: 1180, height: 760), CGSize(width: 1000, height: 600), CGSize(width: 1260, height: 800),
                 CGSize(width: 1080, height: 700), CGSize(width: 940, height: 660), CGSize(width: 1160, height: 720)],
            ]
            for rep in 0..<reps {
                for gap in [120, 400] {
                    let seq = sequences[rep % sequences.count]
                    await marker(conn, "R-gap\(gap)-\(rep + 1)")
                    let framesBefore = conn.frames
                    for size in seq {
                        conn.resize(size)
                        await pause(gap)
                    }
                    let last = seq.last!
                    let ok = await ISV.wait(20) { conn.frameSize == last }
                    await pause(3000)
                    log.write("resize_done", ["row": "R-gap\(gap)-\(rep + 1)", "last": "\(Int(last.width))x\(Int(last.height))",
                                              "frame": "\(Int(conn.frameSize.width))x\(Int(conn.frameSize.height))",
                                              "matchedWithin20s": ok, "framesDuring": conn.frames - framesBefore,
                                              "connected": conn.view.isConnected])
                    conn.resize(CGSize(width: 1280, height: 800))
                    _ = await ISV.wait(20) { conn.frameSize == CGSize(width: 1280, height: 800) }
                    await pause(1500)
                }
            }
            let codecLines = conn.logLines.filter { $0.localizedCaseInsensitiveContains("h264") || $0.localizedCaseInsensitiveContains("avc") || $0.localizedCaseInsensitiveContains("codec") }
            log.write("codec_lines", ["lines": Array(codecLines.suffix(40)), "total": conn.logLines.count])
            await marker(conn, "R-END")
            conn.close()
        }
        await pause(3000)
        // P: pixel size and click position at 1×, simulated 2× backing scale, fixed WxH.
        let cases: [(String, CGSize, CGFloat?, CGSize?)] = [
            ("P1-scale1", CGSize(width: 1280, height: 800), nil, nil),
            ("P2-scale2sim", CGSize(width: 640, height: 400), 2, nil),
            ("P3-fixed1024x768", CGSize(width: 1280, height: 800), nil, CGSize(width: 1024, height: 768)),
            ("P4-fixed1024x768-scale2sim", CGSize(width: 640, height: 400), 2, CGSize(width: 1024, height: 768)),
        ]
        for (name, size, scale, fixed) in cases {
            let conn = ISVConnection(size: size, backingScale: scale)
            try await conn.connect(engine: engine, port: port, password: password, forcedSize: fixed)
            _ = await ISV.wait(10) { conn.frameSize == (fixed ?? CGSize(width: size.width * (scale ?? 1), height: size.height * (scale ?? 1))) }
            await pause(4000)
            await marker(conn, name)
            log.write("pixels", ["row": name, "points": "\(Int(size.width))x\(Int(size.height))", "scale": scale ?? 1,
                                 "backing": conn.window.backingScaleFactor,
                                 "frame": "\(Int(conn.frameSize.width))x\(Int(conn.frameSize.height))",
                                 "fixed": fixed.map { "\(Int($0.width))x\(Int($0.height))" } ?? "-"])
            for rep in 0..<reps {
                // Points measured from the view's top-left; AppKit locations are bottom-left.
                for fraction in [CGPoint(x: 0.25, y: 0.25), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.8)] {
                    let p = CGPoint(x: (size.width * fraction.x).rounded(), y: (size.height * fraction.y).rounded())
                    let location = conn.view.convert(CGPoint(x: p.x, y: size.height - p.y), to: nil)
                    for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                        let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: conn.window.windowNumber, context: nil,
                                                       eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                        if type == .leftMouseDown { conn.view.clientView.mouseDown(with: event) } else { conn.view.clientView.mouseUp(with: event) }
                        await pause(60)
                    }
                    log.write("click", ["row": name, "rep": rep + 1, "viewPoint": "\(Int(p.x)),\(Int(p.y))",
                                        "frame": "\(Int(conn.frameSize.width))x\(Int(conn.frameSize.height))",
                                        "expect": "\(Int((fraction.x * conn.frameSize.width).rounded())),\(Int((fraction.y * conn.frameSize.height).rounded()))"])
                    await pause(400)
                }
            }
            await marker(conn, "\(name)-END")
            conn.close()
            await pause(3000)
        }
    }
}
