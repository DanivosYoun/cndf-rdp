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

    func testShutdownRetainGraveyardSurvivesDelayedMainQueueDrain() {
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
            drainRunLoop(duration: 2.5)

            XCTAssertFalse(view.isConnected)
            XCTAssertEqual(diagnostics.pendingMainQueueTasks, 0)
            XCTAssertEqual(diagnostics.inFlightCommandBuffers, 0)
        }
        drainRunLoop()
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
