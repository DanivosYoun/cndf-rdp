import XCTest
@testable import RDPMacView
import RDPClientCore

@MainActor
final class RDPConnectionViewLifecycleTests: XCTestCase {
    func testShutdownIsIdempotent() {
        let view = RDPConnectionView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        view.shutdown()
        view.shutdown()

        XCTAssertFalse(view.isConnected)
        XCTAssertNil(view.statistics)
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
