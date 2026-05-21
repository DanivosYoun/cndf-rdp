import AppKit
import RDPClientCore
import RDPMacView

private final class StressDelegate: RDPConnectionViewDelegate {
    var connected = false
    var logs: [String] = []

    func rdpConnectionView(_ view: RDPConnectionView, didChangeConnected connected: Bool) {
        self.connected = connected
    }

    func rdpConnectionView(_ view: RDPConnectionView, didLog message: String) {
        logs.append(message)
        fputs("[RDP] \(message)\n", stderr)
    }
}

private enum StressError: Error, CustomStringConvertible {
    case missingHost
    case connectionTimeout

    var description: String {
        switch self {
        case .missingHost:
            "RDP_MAC_HOST is required."
        case .connectionTimeout:
            "Timed out waiting for the RDP session to connect."
        }
    }
}

private func makeConnectionOptions(environment: [String: String]) throws -> RDPConnectionOptions {
    guard let host = environment["RDP_MAC_HOST"], !host.isEmpty else {
        throw StressError.missingHost
    }
    let port = UInt16(environment["RDP_MAC_PORT"] ?? "") ?? 3389
    let password = environment["RDP_MAC_PASSWORD"].map(RDPSecureString.init)
    let audioMode: RDPAudioPlaybackMode = switch environment["RDP_MAC_AUDIO_MODE"] {
    case "local": .playLocally
    case "remote": .playOnRemote
    default: .disabled
    }

    return RDPConnectionOptions(
        host: host,
        port: port,
        username: environment["RDP_MAC_USERNAME"],
        securePassword: password,
        domain: environment["RDP_MAC_DOMAIN"],
        redirectedFolderPath: environment["RDP_MAC_REDIRECT_FOLDER_PATH"],
        redirectedFolderName: environment["RDP_MAC_REDIRECT_FOLDER_NAME"],
        audioPlaybackMode: audioMode,
        logFileURL: environment["RDP_MAC_LOG_FILE"].map { URL(fileURLWithPath: $0) },
        logLevel: .info,
        preferDeviceNativeResolution: parsedBool(environment["RDP_MAC_PREFER_NATIVE_RESOLUTION"], defaultValue: true),
        colorDepth: parsedColorDepth(environment["RDP_MAC_COLOR_DEPTH"]),
        forcedDesktopSize: parsedDesktopSize(environment["RDP_MAC_FORCED_DESKTOP_SIZE"])
    )
}

private func parsedBool(_ value: String?, defaultValue: Bool) -> Bool {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on":
        return true
    case "0", "false", "no", "off":
        return false
    default:
        return defaultValue
    }
}

private func parsedColorDepth(_ value: String?) -> RDPColorDepth {
    switch value?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "16":
        return .depth16
    case "24":
        return .depth24
    default:
        return .depth32
    }
}

private func parsedDesktopSize(_ value: String?) -> CGSize? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
          !value.isEmpty else {
        return nil
    }
    let parts = value
        .replacingOccurrences(of: "×", with: "x")
        .split(separator: "x", maxSplits: 1)
        .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
        return nil
    }
    return CGSize(width: parts[0], height: parts[1])
}

private func drainRunLoop(duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

private func waitForConnection(view: RDPConnectionView, delegate: StressDelegate, timeout: TimeInterval) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if view.isConnected || delegate.connected || delegate.logs.contains("FreeRDP connected.") {
            return
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
    throw StressError.connectionTimeout
}

private func runCycle(index: Int, options: RDPConnectionOptions, waitAfterConnect: TimeInterval) throws {
    try autoreleasepool {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        let view = RDPConnectionView(frame: window.contentView?.bounds ?? .zero)
        let delegate = StressDelegate()
        view.delegate = delegate
        window.title = "RDP close stress \(index)"
        window.contentView = view
        window.makeKeyAndOrderFront(nil)

        try view.connect(options)
        try waitForConnection(view: view, delegate: delegate, timeout: 10)
        drainRunLoop(duration: waitAfterConnect)

        let diagnostics = view.shutdown()
        print(
            "cycle \(index): didWait=\(diagnostics.didWaitForFreeRDPWorker) " +
            "freeRDPWaitMs=\(diagnostics.freeRDPWorkerWaitDurationMs) " +
            "renderDrainMs=\(diagnostics.metalDrainDurationMs) " +
            "pendingMain=\(diagnostics.pendingMainQueueTasks) " +
            "inFlight=\(diagnostics.inFlightCommandBuffers)"
        )
        window.close()
        drainRunLoop(duration: 1.0)
    }
    drainRunLoop(duration: 0.25)
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let environment = ProcessInfo.processInfo.environment
do {
    let options = try makeConnectionOptions(environment: environment)
    let cycles = max(1, Int(environment["RDP_WINDOW_CLOSE_STRESS_CYCLES"] ?? "10") ?? 10)
    let waitAfterConnect = TimeInterval(environment["RDP_WINDOW_CLOSE_STRESS_WAIT_SECONDS"] ?? "1.0") ?? 1.0

    for index in 1...cycles {
        try runCycle(index: index, options: options, waitAfterConnect: waitAfterConnect)
    }
    print("window-close-stress-test completed \(cycles) cycles")
} catch {
    fputs("window-close-stress-test failed: \(error)\n", stderr)
    exit(1)
}
