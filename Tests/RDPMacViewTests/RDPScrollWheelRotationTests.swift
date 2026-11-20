import AppKit
import CoreGraphics
@testable import RDPMacView
import XCTest

/// The view turns AppKit scroll events into RDP wheel rotation (120 = one notch) before either
/// engine sees them. It used to forward the rounded `scrollingDelta*`, so one wheel click reached
/// Windows as 1/120 of a notch and IronRDP did not scroll at all (FreeRDP only looked as if it
/// did, downward, through its old sign-magnitude encoding).
final class RDPScrollWheelRotationTests: XCTestCase {
    private func event(_ units: CGScrollEventUnit, y: Int32, x: Int32 = 0) throws -> NSEvent {
        let cgEvent = try XCTUnwrap(CGEvent(
            scrollWheelEvent2Source: nil, units: units, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0
        ))
        return try XCTUnwrap(NSEvent(cgEvent: cgEvent))
    }

    func testOneWheelClickIsOneNotch() throws {
        XCTAssertEqual(RDPClientView.wheelRotation(for: try event(.line, y: -1)).y, -120)
        XCTAssertEqual(RDPClientView.wheelRotation(for: try event(.line, y: 1)).y, 120)
        XCTAssertEqual(RDPClientView.wheelRotation(for: try event(.line, y: 0, x: -1)).x, -120)
    }

    func testTrackpadPixelsScaleByLines() throws {
        // A precise (trackpad) event of 10 points is one AppKit line.
        let trackpad = try event(.pixel, y: -10)
        XCTAssertTrue(trackpad.hasPreciseScrollingDeltas)
        XCTAssertEqual(RDPClientView.wheelRotation(for: trackpad).y, -120)
        XCTAssertEqual(RDPClientView.wheelRotation(for: try event(.pixel, y: 10)).y, 120)
    }
}
