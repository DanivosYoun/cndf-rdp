import XCTest
@testable import RDPMacView
import RDPClientCore

@MainActor
final class RDPConnectionViewLifecycleTests: XCTestCase {
    func testShutdownIsIdempotent() {
        let view = RDPConnectionView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        let firstDiagnostics = view.shutdown()
        let secondDiagnostics = view.shutdown()

        XCTAssertFalse(view.isConnected)
        XCTAssertNil(view.statistics)
        XCTAssertFalse(firstDiagnostics.didWaitForFreeRDPWorker)
        XCTAssertEqual(firstDiagnostics.pendingMainQueueTasks, 0)
        XCTAssertEqual(firstDiagnostics.inFlightCommandBuffers, 0)
        XCTAssertEqual(firstDiagnostics.freeRDPWorkerWaitDurationMs, 0)
        XCTAssertEqual(firstDiagnostics.metalDrainDurationMs, 0)
        XCTAssertFalse(secondDiagnostics.didWaitForFreeRDPWorker)
    }

    func testShutdownDetachesDelegateAfterSingleStateCallback() throws {
        let view = RDPConnectionView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let delegate = LifecycleDelegate()
        view.delegate = delegate

        view.shutdown()
        try view.pollLocalClipboard()
        view.rdpSession(try RDPSession(), didLog: "late callback")
        view.rdpSession(try RDPSession(), didReceiveRemoteText: "late text")

        XCTAssertEqual(delegate.connectedChanges, [false])
        XCTAssertTrue(delegate.logs.isEmpty)
        XCTAssertTrue(delegate.remoteTexts.isEmpty)
    }

    func testConnectAfterShutdownThrows() {
        let view = RDPConnectionView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        view.shutdown()

        XCTAssertThrowsError(try view.connect(RDPConnectionOptions(host: "rdp.example"))) { error in
            XCTAssertEqual(
                error as? RDPSessionError,
                .configurationInvalid(reason: "RDPConnectionView has been shut down.")
            )
        }
    }

    func testShutdownThenWindowCloseSurvivesAutoreleaseDrain() {
        for _ in 0..<10 {
            autoreleasepool {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                let view = RDPConnectionView(frame: window.contentView?.bounds ?? .zero)
                window.contentView = view
                window.makeKeyAndOrderFront(nil)

                let diagnostics = view.shutdown()
                window.close()
                drainRunLoop()

                XCTAssertFalse(view.isConnected)
                XCTAssertEqual(diagnostics.pendingMainQueueTasks, 0)
                XCTAssertEqual(diagnostics.inFlightCommandBuffers, 0)
            }
            drainRunLoop()
        }
    }

    func testShutdownDetachesFromWindowContentBeforeDelayedMainQueueDrain() {
        weak var releasedView: RDPConnectionView?
        weak var releasedWindow: NSWindow?

        autoreleasepool {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            let view = RDPConnectionView(frame: window.contentView?.bounds ?? .zero)
            releasedView = view
            releasedWindow = window
            window.contentView = view
            window.makeKeyAndOrderFront(nil)

            let diagnostics = view.shutdown()
            XCTAssertFalse(window.contentView === view)
            XCTAssertFalse(window.isReleasedWhenClosed)
            window.close()
            drainRunLoop(duration: 2.5)

            XCTAssertFalse(view.isConnected)
            XCTAssertEqual(diagnostics.pendingMainQueueTasks, 0)
            XCTAssertEqual(diagnostics.inFlightCommandBuffers, 0)
            XCTAssertGreaterThanOrEqual(diagnostics.freeRDPWorkerWaitDurationMs, 0)
            XCTAssertGreaterThanOrEqual(diagnostics.metalDrainDurationMs, 0)
        }
        drainRunLoop()
        XCTAssertNil(releasedView)
        XCTAssertNil(releasedWindow)
    }

    func testRealSessionShutdownThenWindowCloseSurvivesAutoreleaseDrain() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RDP_WINDOW_CLOSE_INTEGRATION"] == "1" else {
            throw XCTSkip("Set RDP_WINDOW_CLOSE_INTEGRATION=1 and RDP_MAC_* connection variables to run live close stress.")
        }
        guard let options = makeLiveConnectionOptions(environment: environment) else {
            throw XCTSkip("RDP_MAC_HOST is required for live close stress.")
        }

        let cycles = max(1, Int(environment["RDP_WINDOW_CLOSE_TEST_CYCLES"] ?? "10") ?? 10)
        for _ in 0..<cycles {
            weak var releasedView: RDPConnectionView?
            weak var releasedWindow: NSWindow?

            autoreleasepool {
                let window = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 640, height: 420),
                    styleMask: [.titled, .closable, .resizable],
                    backing: .buffered,
                    defer: false
                )
                let view = RDPConnectionView(frame: window.contentView?.bounds ?? .zero)
                let delegate = LifecycleDelegate()
                releasedView = view
                releasedWindow = window
                view.delegate = delegate
                window.contentView = view
                window.makeKeyAndOrderFront(nil)

                do {
                    try view.connect(options)
                    waitForLiveSession(view: view, delegate: delegate, timeout: 8)
                    XCTAssertTrue(view.isConnected)

                    drainRunLoop(duration: 0.5)
                    let diagnostics = view.shutdown()
                    XCTAssertTrue(diagnostics.didWaitForFreeRDPWorker)
                    XCTAssertGreaterThanOrEqual(diagnostics.freeRDPWorkerWaitDurationMs, 0)
                    XCTAssertGreaterThanOrEqual(diagnostics.metalDrainDurationMs, 0)
                    XCTAssertEqual(diagnostics.inFlightCommandBuffers, 0)
                    XCTAssertFalse(window.isReleasedWhenClosed)
                    window.close()
                    drainRunLoop(duration: 1.0)
                } catch {
                    XCTFail("Live RDP close stress failed: \(error)")
                    view.shutdown()
                    window.close()
                }
            }
            drainRunLoop(duration: 0.25)
            XCTAssertNil(releasedView)
            XCTAssertNil(releasedWindow)
        }
    }
}

private func drainRunLoop(cycles: Int = 5) {
    for _ in 0..<cycles {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

private func drainRunLoop(duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

private func waitForLiveSession(view: RDPConnectionView, delegate: LifecycleDelegate, timeout: TimeInterval) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if view.isConnected || delegate.connectedChanges.contains(true) || delegate.logs.contains("FreeRDP connected.") {
            return
        }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    }
}

private func makeLiveConnectionOptions(environment: [String: String]) -> RDPConnectionOptions? {
    guard let host = environment["RDP_MAC_HOST"], !host.isEmpty else {
        return nil
    }
    let port = UInt16(environment["RDP_MAC_PORT"] ?? "") ?? 3389
    let password = environment["RDP_MAC_PASSWORD"].map(RDPSecureString.init)
    return RDPConnectionOptions(
        host: host,
        port: port,
        username: environment["RDP_MAC_USERNAME"],
        securePassword: password,
        domain: environment["RDP_MAC_DOMAIN"],
        audioPlaybackMode: .disabled,
        logLevel: .info
    )
}

private final class LifecycleDelegate: RDPConnectionViewDelegate {
    var connectedChanges: [Bool] = []
    var logs: [String] = []
    var remoteTexts: [String] = []

    func rdpConnectionView(_ view: RDPConnectionView, didChangeConnected connected: Bool) {
        connectedChanges.append(connected)
    }

    func rdpConnectionView(_ view: RDPConnectionView, didLog message: String) {
        logs.append(message)
    }

    func rdpConnectionView(_ view: RDPConnectionView, didReceiveRemoteText text: String) {
        remoteTexts.append(text)
    }
}
