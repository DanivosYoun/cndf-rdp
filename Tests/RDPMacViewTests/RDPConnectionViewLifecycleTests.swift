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
