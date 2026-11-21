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

    private func rotation(_ event: NSEvent) -> (x: Int32, y: Int32) {
        var quantizer = RDPWheelQuantizer()
        return quantizer.quantize(event)
    }

    func testOneWheelClickIsOneNotch() throws {
        XCTAssertEqual(rotation(try event(.line, y: -1)).y, -120)
        XCTAssertEqual(rotation(try event(.line, y: 1)).y, 120)
        XCTAssertEqual(rotation(try event(.line, y: 0, x: -1)).x, -120)
        XCTAssertEqual(rotation(try event(.line, y: 0, x: 1)).x, 120)
    }

    func testTrackpadPixelsScaleByLines() throws {
        // A precise (trackpad) event of 10 points is one AppKit line.
        let trackpad = try event(.pixel, y: -10)
        XCTAssertTrue(trackpad.hasPreciseScrollingDeltas)
        XCTAssertEqual(rotation(trackpad).y, -120)
        XCTAssertEqual(rotation(try event(.pixel, y: 10)).y, 120)
    }

    /// Rounding every event on its own sent 5 per 0.04-line event (50 for ten). The residual makes
    /// the sum follow the input: 10 × 4.8 = 48.
    func testFractionalLinesAccumulate() {
        for sign in [1.0, -1.0] {
            var quantizer = RDPWheelQuantizer()
            var sumX: Int32 = 0, sumY: Int32 = 0
            var input = 0.0
            for _ in 0..<10 {
                let r = quantizer.quantize(deltaX: 0.04 * sign, deltaY: 0.04 * sign)
                sumX += r.x
                sumY += r.y
                input += 0.04 * sign * 120
                XCTAssertLessThanOrEqual(abs(Double(sumY) - input), 0.5 + 1e-9)
            }
            XCTAssertEqual(sumX, Int32(48 * sign))
            XCTAssertEqual(sumY, Int32(48 * sign))
        }
    }

    func testExactHalfRoundsToEven() {
        var quantizer = RDPWheelQuantizer(scale: 1, limit: .max)
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0.5).y, 0)
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 1.0).y, 2) // 0.5 + 1.0 = 1.5 → 2
        var other = RDPWheelQuantizer(scale: 1, limit: .max)
        XCTAssertEqual(other.quantize(deltaX: 0, deltaY: 2.5).y, 2)
        XCTAssertEqual(other.quantize(deltaX: 0, deltaY: 0).y, 0) // residual 0.5 → 0, stays 0.5
        XCTAssertEqual(other.quantize(deltaX: 0, deltaY: 0.5).y, 1) // 1.0
    }

    /// The 9-bit field carries −256…+255; the old local clamp at ±32767 let the encoder saturate
    /// asymmetrically (+255 / −256). Both directions now stop at 255, and the clipped part is not
    /// carried into the next event.
    func testSaturationIsSymmetricAndDropsTheClippedPart() {
        var quantizer = RDPWheelQuantizer()
        XCTAssertEqual(quantizer.quantize(deltaX: 3, deltaY: 3).y, 255)
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0).y, 0)
        XCTAssertEqual(quantizer.quantize(deltaX: -3, deltaY: -3).x, -255)
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0).x, 0)
    }

    func testNonFiniteInputIsDroppedBeforeTheResidual() {
        var quantizer = RDPWheelQuantizer()
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0.004).y, 0) // residual 0.48
        XCTAssertEqual(quantizer.quantize(deltaX: .nan, deltaY: .infinity).y, 0)
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0.001).y, 1) // 0.48 + 0.12
    }

    func testResidualFollowsTheGesture() {
        var quantizer = RDPWheelQuantizer()
        // Direct gesture leaves 0.48; momentum continues from it.
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0.004, phase: .began).y, 0)
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0, phase: .ended).y, 0)
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0.001, momentumPhase: .began).y, 1)
        // Momentum end clears it.
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0.004, momentumPhase: .changed).y, 0)
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0, momentumPhase: .ended).y, 0)
        XCTAssertEqual(quantizer.quantize(deltaX: 0, deltaY: 0.001).y, 0)
        // A new gesture starts from zero.
        var fresh = RDPWheelQuantizer()
        XCTAssertEqual(fresh.quantize(deltaX: 0, deltaY: 0.004).y, 0)
        XCTAssertEqual(fresh.quantize(deltaX: 0, deltaY: 0.001, phase: .began).y, 0)
        // Cancellation clears it.
        var cancelled = RDPWheelQuantizer()
        XCTAssertEqual(cancelled.quantize(deltaX: 0, deltaY: 0.004, phase: .changed).y, 0)
        XCTAssertEqual(cancelled.quantize(deltaX: 0, deltaY: 0, phase: .cancelled).y, 0)
        XCTAssertEqual(cancelled.quantize(deltaX: 0, deltaY: 0.001).y, 0)
    }
}
