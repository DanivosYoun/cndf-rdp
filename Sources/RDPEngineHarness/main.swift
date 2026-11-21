import AppKit
import CryptoKit
import CoreVideo
import QuartzCore
import RDPClientCore
import RDPMacView

// RDPEngineHarness (design D7 H-A): drives a real RDPConnectionView in an off-screen window
// from a JSON scenario and writes metrics JSON. No mocks — every number comes from a live
// connection to a test server (Harness/docker, Scripts/run-engine-harness.sh).
//
// usage: rdp-engine-harness --scenario <file.json> --out <result.json>
//            [--engine freerdp|ironrdp] [--trust-suite <UserDefaults suite>] [--work-dir <dir>]
//            [--reset-trust 1] [--drop-trust 1]
//
// The trust store persists across invocations with the same --trust-suite so a scenario can
// span server restarts (cert A -> B -> A). --reset-trust clears it first, --drop-trust last.
//
// FreeRDP keeps its own known_hosts under $HOME; run with an isolated HOME so trust
// scenarios start clean (the run script does this).

private enum HarnessError: Error, CustomStringConvertible {
    case usage(String)
    case unknownEngine(String)

    var description: String {
        switch self {
        case .usage(let message):
            "usage error: \(message)"
        case .unknownEngine(let engine):
            "unknown engine '\(engine)' (expected freerdp or ironrdp)"
        }
    }
}

private struct Arguments {
    var scenarioURL: URL
    var outURL: URL
    var engine: String?
    var trustSuite: String
    var workDirectory: URL
    var resetTrust: Bool
    var dropTrust: Bool

    init(_ argv: [String]) throws {
        var values: [String: String] = [:]
        var index = 1
        while index < argv.count {
            let key = argv[index]
            guard key.hasPrefix("--"), index + 1 < argv.count else {
                throw HarnessError.usage("unexpected argument \(key)")
            }
            values[String(key.dropFirst(2))] = argv[index + 1]
            index += 2
        }
        guard let scenario = values["scenario"], let out = values["out"] else {
            throw HarnessError.usage("--scenario and --out are required")
        }
        scenarioURL = URL(fileURLWithPath: scenario)
        outURL = URL(fileURLWithPath: out)
        engine = values["engine"]
        trustSuite = values["trust-suite"] ?? "cndf.rdp-engine-harness.\(getpid())"
        workDirectory = URL(fileURLWithPath: values["work-dir"] ?? FileManager.default.currentDirectoryPath)
        resetTrust = values["reset-trust"] == "1"
        dropTrust = values["drop-trust"] == "1"
    }
}

/// Harness-only certificate trust store, keyed like the app's KnownHostStore (host:port ->
/// lowercased trust string). Policy follows design I4: new = accept and store after the
/// connection succeeds, same = accept, changed = prompt (answered by the scenario).
private final class TrustStore {
    private let defaults: UserDefaults
    private let suiteName: String
    private let lock = NSLock()

    init(suiteName: String) {
        self.suiteName = suiteName
        defaults = UserDefaults(suiteName: suiteName)!
    }

    func stored(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return defaults.string(forKey: key)
    }

    func store(_ value: String, for key: String) {
        lock.lock()
        defaults.set(value, forKey: key)
        lock.unlock()
    }

    func removeAll() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private final class HarnessDelegate: RDPConnectionViewDelegate {
    private let lock = NSLock()
    private let trustStore: TrustStore
    private let approveChanged: Bool
    private var pendingTrust: (key: String, value: String)?

    private(set) var connected = false
    /// Not-connected -> connected rises. The view repeats `didChangeConnected(true)` while
    /// connected, so only a rise counts; more than one means the session reconnected.
    private(set) var connectRises = 0
    private var lastReportedConnected = false
    private(set) var connectedAt: CFTimeInterval?
    private(set) var trustCallbacks: [String] = []
    /// Per trust callback: SHA-256 of each certificate in the trust string, in order. Shows
    /// what the engine puts in the string (leaf only, leaf + chain, ...) for design I3.
    private(set) var trustStringCertificates: [[String]] = []
    /// Per trust callback: SHA-256 of the exact trust string bytes before lowercasing, so two
    /// engines can be compared byte for byte (design I3).
    private(set) var trustStringDigests: [String] = []
    private(set) var prompts = 0
    private(set) var displayControlReady = false
    private(set) var failure: RDPSessionError?
    private(set) var disconnectReason: RDPDisconnectReason?
    private(set) var callbacksAfterShutdown = 0
    var shutdownReturned = false

    init(trustStore: TrustStore, approveChanged: Bool) {
        self.trustStore = trustStore
        self.approveChanged = approveChanged
    }

    private func noteCallback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if shutdownReturned {
            callbacksAfterShutdown += 1
            return false
        }
        return true
    }

    func rdpConnectionView(_ view: RDPConnectionView, didLog message: String) {
        guard noteCallback() else { return }
        // F3: the follow decisions, to compare with the Windows probe log.
        if message.hasPrefix("RDP input-source follow:") {
            FileHandle.standardError.write(Data("\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime)) \(message)\n".utf8))
        }
        lock.withLock {
            displayControlReady = updateDisplayControlReady(displayControlReady, forLogMessage: message)
        }
        fputs("[RDP] \(message)\n", stderr)
    }

    func rdpConnectionView(_ view: RDPConnectionView, didChangeConnected connected: Bool) {
        guard noteCallback() else { return }
        lock.lock()
        if connected && !lastReportedConnected { connectRises += 1 }
        lastReportedConnected = connected
        if connected && !self.connected {
            connectedAt = CACurrentMediaTime()
            if let pendingTrust {
                trustStore.store(pendingTrust.value, for: pendingTrust.key)
                self.pendingTrust = nil
            }
        }
        self.connected = self.connected || connected
        lock.unlock()
    }

    func rdpConnectionView(
        _ view: RDPConnectionView,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool {
        guard noteCallback() else { return false }
        let digest = SHA256.hash(data: Data(fingerprint.utf8)).map { String(format: "%02x", $0) }.joined()
        lock.withLock { trustStringDigests.append(digest) }
        return classifyTrust(
            key: "\(hostname):\(port)",
            value: fingerprint.lowercased(),
            certificates: pemCertificateDigests(fingerprint)
        )
    }

    private func classifyTrust(key: String, value: String, certificates: [String]) -> Bool {
        let stored = trustStore.stored(for: key)
        lock.lock()
        defer { lock.unlock() }
        trustStringCertificates.append(certificates)
        if stored == nil {
            trustCallbacks.append("new")
            pendingTrust = (key, value)
            return true
        }
        if stored == value {
            trustCallbacks.append("same")
            return true
        }
        trustCallbacks.append("changed")
        prompts += 1
        if approveChanged {
            pendingTrust = (key, value)
        }
        return approveChanged
    }

    func rdpConnectionView(_ view: RDPConnectionView, didFailWith error: RDPSessionError) {
        guard noteCallback() else { return }
        lock.lock()
        failure = error
        lock.unlock()
    }

    func rdpConnectionView(_ view: RDPConnectionView, didDisconnectWith reason: RDPDisconnectReason) {
        guard noteCallback() else { return }
        lock.lock()
        disconnectReason = reason
        lock.unlock()
    }

    var currentFailure: RDPSessionError? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    var isDisplayControlReady: Bool {
        lock.withLock { displayControlReady }
    }
}

func updateDisplayControlReady(_ current: Bool, forLogMessage message: String) -> Bool {
    if message.hasPrefix("Display control capabilities received:") {
        return true
    }
    if message == "Display control channel closed."
        || message == "FreeRDP disconnected."
        || message == "IronRDP disconnected." {
        return false
    }
    return current
}

/// SHA-256 (hex) of each PEM certificate block in a trust string, in order.
private func pemCertificateDigests(_ pem: String) -> [String] {
    pem.components(separatedBy: "-----BEGIN CERTIFICATE-----").dropFirst().map { block in
        let body = block.components(separatedBy: "-----END CERTIFICATE-----")[0].filter { !$0.isWhitespace }
        guard let der = Data(base64Encoded: body) else { return "undecodable" }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

/// Frame tap state. Only touched on main (onRenderedFrame runs inside display on main).
private final class FrameProbe {
    var firstFrameAt: CFTimeInterval?
    var firstFrameSize: [Int]?
    var framesWithTap = 0
    var pixelBufferBytes: UInt64 = 0
    var probePoint: (x: Int, y: Int)?
    var lastProbeColor: UInt32?
    var lastProbeColorAt: CFTimeInterval = 0
    var afterShutdown = 0
    var shutdownReturned = false

    func handle(_ buffer: CVPixelBuffer, at time: CFTimeInterval) {
        if shutdownReturned {
            afterShutdown += 1
            return
        }
        framesWithTap += 1
        pixelBufferBytes += UInt64(CVPixelBufferGetDataSize(buffer))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        func pixel(_ x: Int, _ y: Int) -> UInt32 {
            base.advanced(by: y * stride + x * 4).loadUnaligned(as: UInt32.self) & 0x00FF_FFFF
        }
        if firstFrameAt == nil {
            // "Non-empty": some sampled pixel is not black.
            var nonEmpty = false
            for gy in 0..<16 where !nonEmpty {
                for gx in 0..<16 where pixel(gx * width / 16, gy * height / 16) != 0 {
                    nonEmpty = true
                    break
                }
            }
            if nonEmpty {
                firstFrameAt = time
                firstFrameSize = [width, height]
            }
        }
        if let probePoint, probePoint.x < width, probePoint.y < height {
            let color = pixel(probePoint.x, probePoint.y)
            if color != lastProbeColor {
                lastProbeColor = color
                lastProbeColorAt = time
            }
        }
    }
}

private func drainRunLoop(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
}

/// Runs the loop until `condition` holds or `timeout` passes. Returns whether it held.
private func waitUntil(_ timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    return condition()
}

/// Leave the main run loop active: xclip and FUSE may need a response from this client.
private func fixtureRequest(port: UInt16, path: String, body: Data?, timeout: TimeInterval) -> Data? {
    guard let token = ProcessInfo.processInfo.environment["HARNESS_B3_FIXTURE_TOKEN"],
          let url = URL(string: "http://127.0.0.1:\(port)/\(path)") else { return nil }
    var request = URLRequest(url: url, timeoutInterval: timeout)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    if let body {
        request.httpMethod = "POST"
        request.httpBody = body
    }
    var responseBody: Data?
    var completed = false
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
        DispatchQueue.main.async {
            if (response as? HTTPURLResponse)?.statusCode == 200 { responseBody = data }
            completed = true
        }
    }
    task.resume()
    guard waitUntil(timeout, { completed }) else {
        task.cancel()
        return nil
    }
    return responseBody
}

private func milliseconds(_ seconds: CFTimeInterval) -> Double {
    (seconds * 1000 * 10).rounded() / 10
}

private func failureName(_ error: RDPSessionError) -> String {
    switch error {
    case .unableToCreateBridgeSession: "unableToCreateBridgeSession"
    case .bridgeRejectedOperation: "bridgeRejectedOperation"
    case .networkUnreachable: "networkUnreachable"
    case .tlsHandshakeFailed: "tlsHandshakeFailed"
    case .authenticationFailed: "authenticationFailed"
    case .certificateRejected: "certificateRejected"
    case .freerdp: "freerdp"
    case .configurationInvalid: "configurationInvalid"
    case .ironrdp: "ironrdp"
    }
}

private func disconnectName(_ reason: RDPDisconnectReason) -> String {
    switch reason {
    case .localRequest: "localRequest"
    case .serverDisconnect(let code): "serverDisconnect(\(code.map(String.init) ?? "nil"))"
    case .timeout: "timeout"
    case .error: "error"
    }
}

private func runIteration(
    _ run: HarnessRun,
    engine: RDPEngineKind,
    iteration: Int,
    trustStore: TrustStore,
    workDirectory: URL
) -> IterationResult {
    var result = IterationResult(iteration: iteration)
    let password = run.passwordEnv.flatMap { ProcessInfo.processInfo.environment[$0] }
    let logURL = workDirectory.appendingPathComponent("\(run.id)-\(iteration).session.log")
    try? FileManager.default.removeItem(at: logURL)
    let driveURL = run.shareHome == true
        ? workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        : nil
    if let driveURL {
        do {
            try FileManager.default.createDirectory(at: driveURL, withIntermediateDirectories: false)
        } catch {
            result.failure = "driveFixtureFailed"
            result.failureDetail = String(describing: error)
            return result
        }
    }
    defer {
        if let driveURL { try? FileManager.default.removeItem(at: driveURL) }
    }
    let pasteboard = run.enableClipboard == true
        ? NSPasteboard(name: .init("cndf-rdp-harness-\(UUID().uuidString)"))
        : nil
    defer { pasteboard?.releaseGlobally() }

    let audioMode = RDPAudioPlaybackMode(rawValue: run.audioMode ?? 0)
    guard let audioMode else {
        result.failure = "invalidAudioMode"
        return result
    }
    let options = RDPConnectionOptions(
        host: run.host,
        port: run.port,
        username: run.username,
        securePassword: password.map(RDPSecureString.init),
        domain: run.domain,
        enableClipboard: run.enableClipboard ?? false,
        enableDriveRedirection: driveURL != nil,
        redirectedFolderPath: driveURL?.path,
        redirectedFolderName: driveURL.map { _ in "Home" },
        audioPlaybackMode: audioMode,
        logFileURL: logURL,
        logLevel: .info,
        networkAutoDetect: run.networkAutoDetect ?? false,
        graphicsMode: RDPGraphicsMode(rawValue: run.graphicsMode ?? "auto") ?? .automatic,
        engine: engine,
        pasteboardName: pasteboard?.name.rawValue,
        keyboardProfile: RDPKeyboardProfile(rawValue: run.keyboardProfile ?? "standard") ?? .standard
    )

    let size = run.window ?? HarnessSize(width: 1280, height: 800)
    // Borderless so AppKit does not pull the window back onto a screen.
    let window = NSWindow(
        contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let view = RDPConnectionView(frame: NSRect(origin: .zero, size: NSSize(width: size.width, height: size.height)))
    let delegate = HarnessDelegate(trustStore: trustStore, approveChanged: run.promptAnswer == "approve")
    let probe = FrameProbe()
    view.delegate = delegate
    window.contentView = view
    window.orderFront(nil)

    let attachTap = {
        view.onRenderedFrame = { buffer, time in probe.handle(buffer, at: time) }
    }
    let startCPU = processCPUMilliseconds()
    let sampler = FootprintSampler()
    sampler.start()
    let startedAt = CACurrentMediaTime()
    var connectAt: CFTimeInterval?
    var aborted = false
    var didShutdown = false

    for step in run.steps {
        if aborted && step.op != "shutdown" {
            result.steps.append("\(step.op):skipped")
            continue
        }
        switch step.op {
        case "connect":
            attachTap()
            connectAt = CACurrentMediaTime()
            do {
                try view.connect(options)
                result.steps.append("connect:ok")
            } catch {
                result.steps.append("connect:threw")
                result.failure = "connectThrew"
                result.failureDetail = String(describing: error)
                aborted = true
            }
        case "waitConnected":
            let ok = waitUntil(step.timeout ?? 15) {
                view.isConnected || delegate.connected || delegate.currentFailure != nil
            } && delegate.currentFailure == nil && (view.isConnected || delegate.connected)
            result.steps.append("waitConnected:\(ok ? "ok" : "failed")")
            if !ok { aborted = true }
        case "waitFirstFrame":
            if view.onRenderedFrame == nil { attachTap() }
            let ok = waitUntil(step.timeout ?? 15) {
                probe.firstFrameAt != nil || delegate.currentFailure != nil
            } && probe.firstFrameAt != nil
            result.steps.append("waitFirstFrame:\(ok ? "ok" : "timeout")")
            // Keep the tap only where a step needs it: its CVPixelBuffer copy costs CPU.
            view.onRenderedFrame = nil
            if !ok { aborted = true }
        case "idle":
            drainRunLoop(step.seconds ?? 5)
            result.steps.append("idle:\(step.seconds ?? 5)s")
        case "tap":
            attachTap()
            drainRunLoop(step.seconds ?? 5)
            view.onRenderedFrame = nil
            result.steps.append("tap:\(step.seconds ?? 5)s")
        case "inputLatency":
            attachTap()
            probe.probePoint = (step.probeX ?? 100, step.probeY ?? 100)
            view.sendForcedDesktopSize()
            _ = waitUntil(3) { probe.lastProbeColor != nil }
            let scanCode = step.scanCode ?? 0x1E
            var samples: [Double] = []
            for _ in 0..<(step.samples ?? 20) {
                drainRunLoop(0.15)
                let before = probe.lastProbeColor
                let sentAt = CACurrentMediaTime()
                view.injectKey(virtualKeyCode: 0, scanCode: scanCode, flags: .down)
                view.injectKey(virtualKeyCode: 0, scanCode: scanCode, flags: .up)
                if waitUntil(2.0, { probe.lastProbeColor != before && probe.lastProbeColorAt >= sentAt }) {
                    samples.append(milliseconds(probe.lastProbeColorAt - sentAt))
                } else {
                    result.inputLatencyTimeouts += 1
                }
            }
            result.inputLatencyMs = DistributionSummary(samples)
            view.onRenderedFrame = nil
            probe.probePoint = nil
            result.steps.append("inputLatency:\(samples.count)/\(step.samples ?? 20)")
        case "resize":
            let width = step.width ?? 1024
            let height = step.height ?? 700
            // Only records the remote frame size; the tap metrics stay with the tap step.
            var lastFrameSize: [Int]?
            let previousTap = view.onRenderedFrame
            view.onRenderedFrame = { buffer, time in
                lastFrameSize = [CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)]
                previousTap?(buffer, time)
            }
            window.setContentSize(NSSize(width: width, height: height))
            let requestedSize = DisplayResizeCoordinator().candidateSize(
                pointWidth: width, pointHeight: height, scale: window.backingScaleFactor,
                preferDeviceNativeResolution: options.preferDeviceNativeResolution,
                forcedDesktopSize: options.forcedDesktopSize
            )
            // Display Control limits dimensions to 200...8192 and requires even widths.
            let pixelWidth = requestedSize.pixelWidth
            result.requestedResizeFrameSize = [
                min(8192, max(200, Int(pixelWidth - pixelWidth % 2))),
                min(8192, max(200, Int(requestedSize.pixelHeight)))
            ]
            view.frame = NSRect(x: 0, y: 0, width: width, height: height)
            drainRunLoop(step.seconds ?? 2)
            view.onRenderedFrame = previousTap
            result.resizeFrameSize = lastFrameSize
            result.displayControlReady = delegate.isDisplayControlReady
            result.connectedAfterResize = view.isConnected && delegate.disconnectReason == nil
            result.steps.append("resize:\(Int(width))x\(Int(height))")
        case "scroll":
            let deltas = step.scrollDeltas ?? []
            let deltasX = step.scrollDeltasX ?? []
            let unit = step.scrollUnit ?? "line"
            if let x = step.pointerX, let y = step.pointerY {
                view.injectMouse(x: x, y: y, button: nil, flags: .move)
                drainRunLoop(0.3)
            }
            var seen: [String] = []
            for index in 0..<max(deltas.count, deltasX.count) {
                let dy = index < deltas.count ? deltas[index] : 0
                let dx = index < deltasX.count ? deltasX[index] : 0
                if unit == "raw" {
                    view.injectScroll(x: step.pointerX ?? 0, y: step.pointerY ?? 0, deltaY: dy, deltaX: dx)
                } else if let cgEvent = CGEvent(
                    scrollWheelEvent2Source: nil,
                    units: unit == "pixel" ? .pixel : .line,
                    wheelCount: 2,
                    wheel1: dy,
                    wheel2: dx,
                    wheel3: 0
                ), let event = NSEvent(cgEvent: cgEvent) {
                    if index == 0 {
                        seen.append("scrollingDeltaY=\(event.scrollingDeltaY) deltaY=\(event.deltaY) precise=\(event.hasPreciseScrollingDeltas)")
                    }
                    view.clientView.scrollWheel(with: event)
                }
                drainRunLoop((step.intervalMs ?? 50) / 1000)
            }
            result.steps.append("scroll:\(unit)x\(max(deltas.count, deltasX.count)) \(seen.joined())")
        case "clipboardSetRemote", "clipboardExpectRemote", "clipboardSetLocal", "clipboardExpectLocal":
            guard let pasteboard, let value = step.text else {
                result.steps.append("\(step.op):failed")
                aborted = true
                continue
            }
            let timeout = step.timeout ?? 10
            let ok: Bool
            switch step.op {
            case "clipboardSetLocal":
                pasteboard.clearContents()
                do {
                    ok = pasteboard.setString(value, forType: .string)
                    try view.pollLocalClipboard()
                } catch {
                    result.steps.append("\(step.op):failed")
                    aborted = true
                    continue
                }
            case "clipboardExpectLocal":
                ok = waitUntil(timeout) { pasteboard.string(forType: .string) == value }
            case "clipboardSetRemote":
                ok = run.fixturePort.flatMap {
                    fixtureRequest(port: $0, path: "clipboard", body: Data(value.utf8), timeout: timeout)
                } != nil
            default:
                let expected = Data(value.utf8)
                ok = run.fixturePort.map { port in
                    let deadline = Date().addingTimeInterval(timeout)
                    repeat {
                        let remaining = max(0.01, deadline.timeIntervalSinceNow)
                        if fixtureRequest(port: port, path: "clipboard", body: nil, timeout: remaining) == expected {
                            return true
                        }
                        drainRunLoop(min(0.1, remaining))
                    } while Date() < deadline
                    return false
                } ?? false
            }
            result.steps.append("\(step.op):\(ok ? "ok" : "failed")")
            aborted = !ok
        case "driveExpect":
            guard let driveURL, let fixturePort = run.fixturePort else {
                result.steps.append("driveExpect:failed")
                aborted = true
                continue
            }
            let readFile = driveURL.appendingPathComponent("k3-read.txt")
            let writeFile = driveURL.appendingPathComponent("k3-write.txt")
            let seed = Data("k3-read".utf8)
            do {
                try seed.write(to: readFile)
                let readBack = fixtureRequest(port: fixturePort, path: "drive", body: Data(), timeout: step.timeout ?? 10)
                let writeBack = try? Data(contentsOf: writeFile)
                let ok = readBack == seed && writeBack == Data("k3-write".utf8)
                result.steps.append("driveExpect:\(ok ? "ok" : "failed")")
                aborted = !ok
            } catch {
                result.steps.append("driveExpect:failed")
                aborted = true
            }
        case "audioExpectWaves":
            let minWaves = step.minWaves ?? 1
            let timeout = step.timeout ?? 10
            let ok = waitUntil(timeout) { (view.statistics?.audioWavesReceived ?? 0) >= minWaves }
            let waves = view.statistics?.audioWavesReceived ?? 0
            result.audioWavesReceived = waves
            result.steps.append("audioExpectWaves:\(ok ? "ok" : "failed")")
            aborted = !ok
        case "keys", "sharedKeys":
            var shared: RDPSharedInputSession?
            if step.op == "sharedKeys" {
                let handle = MainActor.assumeIsolated { view.makeSharedInputSession() }
                guard handle.activate() else {
                    result.steps.append("sharedKeys:inactive")
                    aborted = true
                    continue
                }
                shared = handle
            }
            var script = KeyScript(view: view, window: window, shared: shared)
            let unknown = script.play(step.text ?? "", pause: drainRunLoop)
            if let shared {
                shared.beginClose()
                drainRunLoop(0.5)
            }
            drainRunLoop(step.seconds ?? 0.5)
            result.steps.append("\(step.op):\(unknown.isEmpty ? "ok" : "unknown " + unknown.joined(separator: ","))")
        case "shutdown":
            result.disconnectBeforeShutdown = delegate.disconnectReason.map(disconnectName)
            if let statistics = view.statistics {
                result.framesReceived = statistics.framesReceived
                result.frameBytesReceived = statistics.frameBytesReceived
                result.audioWavesReceived = statistics.audioWavesReceived
            }
            let shutdownStart = CACurrentMediaTime()
            let diagnostics = view.shutdown()
            result.shutdownMs = milliseconds(CACurrentMediaTime() - shutdownStart)
            delegate.shutdownReturned = true
            probe.shutdownReturned = true
            result.shutdownDiagnostics = [
                "freeRDPWorkerWaitMs": diagnostics.freeRDPWorkerWaitDurationMs,
                "renderDrainMs": diagnostics.metalDrainDurationMs,
                "pendingMain": diagnostics.pendingMainQueueTasks,
                "inFlightCommandBuffers": diagnostics.inFlightCommandBuffers
            ]
            window.close()
            didShutdown = true
            drainRunLoop(1.0)
            result.steps.append("shutdown:ok")
        default:
            result.steps.append("\(step.op):unknown")
            aborted = true
        }
    }
    if !didShutdown {
        result.disconnectBeforeShutdown = delegate.disconnectReason.map(disconnectName)
        view.shutdown()
        delegate.shutdownReturned = true
        probe.shutdownReturned = true
        window.close()
        drainRunLoop(1.0)
    }

    sampler.stop()
    let endCPU = processCPUMilliseconds()
    result.durationMs = milliseconds(CACurrentMediaTime() - startedAt)
    result.cpuUserMs = endCPU.user - startCPU.user
    result.cpuSystemMs = endCPU.system - startCPU.system
    result.physFootprintMaxBytes = sampler.maxBytes
    result.physFootprintAvgBytes = sampler.averageBytes
    result.connected = delegate.connected
    if let connectAt, let connectedAt = delegate.connectedAt {
        result.connectToConnectedMs = milliseconds(connectedAt - connectAt)
    }
    if let connectAt, let firstFrameAt = probe.firstFrameAt {
        result.firstFrameMs = milliseconds(firstFrameAt - connectAt)
        result.firstFrameSize = probe.firstFrameSize
    }
    result.framesDisplayedWithTap = probe.framesWithTap
    result.tapPixelBufferBytes = probe.pixelBufferBytes
    result.trustCallbacks = delegate.trustCallbacks
    result.trustStringCertificates = delegate.trustStringCertificates
    result.trustStringDigests = delegate.trustStringDigests
    result.prompts = delegate.prompts
    if let failure = delegate.failure {
        result.failure = failureName(failure)
        result.failureDetail = String(describing: failure)
    }
    result.disconnectReason = delegate.disconnectReason.map(disconnectName)
    result.connectRises = delegate.connectRises
    result.callbacksAfterShutdown = delegate.callbacksAfterShutdown + probe.afterShutdown
    if let password, !password.isEmpty, let log = try? String(contentsOf: logURL, encoding: .utf8) {
        result.passwordFoundInSessionLog = log.contains(password)
    }
    return result
}

enum ResizeFrameSizeCheckStatus: String, Equatable {
    case pass
    case fail
    case notApplicable = "N/A"
}

func evaluateResizeFrameSize(
    _ iteration: IterationResult,
    against expect: HarnessExpectation?
) -> (status: ResizeFrameSizeCheckStatus?, failure: String?) {
    guard expect?.resizeKeepsSession == true else { return (nil, nil) }
    let prefix = "iteration \(iteration.iteration):"
    if expect?.resizeAppliesFrameSize == false {
        return (.notApplicable, nil)
    }
    if iteration.displayControlReady != true {
        if expect?.resizeAppliesFrameSize == true {
            return (.fail, "\(prefix) resize: Display Control did not open")
        }
        return (.notApplicable, nil)
    }
    if let requested = iteration.requestedResizeFrameSize {
        if iteration.resizeFrameSize != requested {
            return (.fail, "\(prefix) resize: frame size \(iteration.resizeFrameSize.map { String(describing: $0) } ?? "nil"), expected \(requested)")
        }
        return (.pass, nil)
    }
    return (.fail, "\(prefix) resize: no requested frame size")
}

func evaluate(_ iteration: IterationResult, against expect: HarnessExpectation?) -> [String] {
    var failures: [String] = []
    let prefix = "iteration \(iteration.iteration):"
    if iteration.callbacksAfterShutdown != 0 {
        failures.append("\(prefix) \(iteration.callbacksAfterShutdown) callbacks after shutdown")
    }
    if iteration.passwordFoundInSessionLog == true {
        failures.append("\(prefix) password found in session log")
    }
    if let disconnect = expect?.disconnect {
        if iteration.disconnectBeforeShutdown != disconnect {
            failures.append("\(prefix) disconnectBeforeShutdown=\(iteration.disconnectBeforeShutdown ?? "nil"), expected \(disconnect)")
        }
    } else if let disconnect = iteration.disconnectBeforeShutdown, expect?.failure == nil {
        failures.append("\(prefix) unexpected disconnect before shutdown: \(disconnect)")
    }
    if expect?.failure != iteration.failure {
        failures.append("\(prefix) failure=\(iteration.failure ?? "nil"), expected \(expect?.failure ?? "nil")")
    }
    for step in iteration.steps where step.hasSuffix(":failed") || step.hasSuffix(":unknown") {
        failures.append("\(prefix) \(step)")
    }
    guard let expect else { return failures }
    if let connected = expect.connected, connected != iteration.connected {
        failures.append("\(prefix) connected=\(iteration.connected), expected \(connected)")
    }
    if let firstFrame = expect.firstFrame, firstFrame != (iteration.firstFrameMs != nil) {
        failures.append("\(prefix) firstFrame=\(iteration.firstFrameMs != nil), expected \(firstFrame)")
    }
    if let callbacks = expect.trustCallbacks, callbacks != iteration.trustCallbacks {
        failures.append("\(prefix) trustCallbacks=\(iteration.trustCallbacks), expected \(callbacks)")
    }
    if let prompts = expect.prompts, prompts != iteration.prompts {
        failures.append("\(prefix) prompts=\(iteration.prompts), expected \(prompts)")
    }
    if expect.resizeKeepsSession == true,
       iteration.connectedAfterResize != true || iteration.connectRises > 1 {
        failures.append("\(prefix) resize: connectedAfterResize=\(iteration.connectedAfterResize.map(String.init) ?? "nil"), connectRises=\(iteration.connectRises)")
    }
    if let resizeFailure = evaluateResizeFrameSize(iteration, against: expect).failure {
        failures.append(resizeFailure)
    }
    if let maxShutdownMs = expect.maxShutdownMs, let shutdownMs = iteration.shutdownMs,
       shutdownMs > Double(maxShutdownMs) {
        failures.append("\(prefix) shutdownMs=\(shutdownMs) > \(maxShutdownMs)")
    }
    return failures
}

private func iso8601Now() -> String {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "Asia/Seoul")
    return formatter.string(from: Date())
}

private func runScenario(_ arguments: Arguments) throws -> ScenarioResult {
    let scenario = try JSONDecoder().decode(HarnessScenario.self, from: Data(contentsOf: arguments.scenarioURL))
    // A run's own engine wins (mixed-engine scenarios such as I3); otherwise --engine, then
    // the scenario default, then FreeRDP.
    let engine = arguments.engine ?? scenario.engine ?? RDPEngineKind.freeRDP.rawValue
    guard RDPEngineKind(rawValue: engine) != nil else { throw HarnessError.unknownEngine(engine) }
    for run in scenario.runs {
        if let runEngine = run.engine, RDPEngineKind(rawValue: runEngine) == nil {
            throw HarnessError.unknownEngine(runEngine)
        }
    }
    try FileManager.default.createDirectory(at: arguments.workDirectory, withIntermediateDirectories: true)
    let trustStore = TrustStore(suiteName: arguments.trustSuite)
    if arguments.resetTrust { trustStore.removeAll() }
    defer { if arguments.dropTrust { trustStore.removeAll() } }

    let startedAt = iso8601Now()
    var runs: [RunResult] = []
    for run in scenario.runs {
        let runEngine = RDPEngineKind(rawValue: run.engine ?? engine) ?? .freeRDP
        let expect = run.expectByEngine?[runEngine.rawValue] ?? run.expect
        fputs("== run \(run.id) (\(run.host):\(run.port), engine \(runEngine.rawValue))\n", stderr)
        var iterations: [IterationResult] = []
        var failures: [String] = []
        for iteration in 1...max(1, run.repeatCount ?? 1) {
            var result = autoreleasepool {
                runIteration(run, engine: runEngine, iteration: iteration, trustStore: trustStore, workDirectory: arguments.workDirectory)
            }
            result.resizeFrameSizeCheck = evaluateResizeFrameSize(result, against: expect).status?.rawValue
            failures += evaluate(result, against: expect)
            iterations.append(result)
            drainRunLoop(0.5)
        }
        runs.append(RunResult(
            id: run.id,
            engine: runEngine.rawValue,
            host: run.host,
            port: run.port,
            iterations: iterations,
            firstFrameMs: DistributionSummary(iterations.compactMap(\.firstFrameMs)),
            connectToConnectedMs: DistributionSummary(iterations.compactMap(\.connectToConnectedMs)),
            shutdownMs: DistributionSummary(iterations.compactMap(\.shutdownMs)),
            passed: failures.isEmpty,
            expectationFailures: failures
        ))
        fputs("== run \(run.id): \(failures.isEmpty ? "PASS" : "FAIL \(failures)")\n", stderr)
    }
    return ScenarioResult(
        scenario: scenario.name,
        engine: engine,
        startedAt: startedAt,
        finishedAt: iso8601Now(),
        host: [
            "hostName": ProcessInfo.processInfo.hostName,
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "backingScaleFactor": "\(NSScreen.main?.backingScaleFactor ?? 0)"
        ],
        runs: runs,
        passed: runs.allSatisfy(\.passed)
    )
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

do {
    let arguments = try Arguments(CommandLine.arguments)
    let result = try runScenario(arguments)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(result).write(to: arguments.outURL)
    print("rdp-engine-harness: \(result.scenario) \(result.passed ? "PASS" : "FAIL") -> \(arguments.outURL.path)")
    exit(result.passed ? 0 : 1)
} catch {
    fputs("rdp-engine-harness failed: \(error)\n", stderr)
    exit(2)
}
