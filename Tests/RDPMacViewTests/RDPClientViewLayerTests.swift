import QuartzCore
import RDPMacView
import XCTest

final class RDPClientViewLayerTests: XCTestCase {
    func testFrameLayerDisablesImplicitAnimations() {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let actions = view.layer?.actions

        XCTAssertTrue(actions?["contents"] is NSNull)
        XCTAssertTrue(actions?["contentsScale"] is NSNull)
        XCTAssertTrue(actions?["bounds"] is NSNull)
        XCTAssertTrue(actions?["position"] is NSNull)
    }
}
