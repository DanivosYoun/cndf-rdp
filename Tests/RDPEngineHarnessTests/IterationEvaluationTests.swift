import XCTest
@testable import RDPEngineHarness

final class IterationEvaluationTests: XCTestCase {
    func testResizeFailsWhenTheFinalFrameSizeWasNotApplied() {
        var iteration = IterationResult(iteration: 1)
        iteration.connectRises = 1
        iteration.connectedAfterResize = true
        iteration.requestedResizeFrameSize = [1280, 800]
        let expected = HarnessExpectation(resizeKeepsSession: true)

        XCTAssertFalse(evaluate(iteration, against: expected).isEmpty)
        iteration.resizeFrameSize = [960, 640]
        XCTAssertFalse(evaluate(iteration, against: expected).isEmpty)
        iteration.resizeFrameSize = [1280, 800]
        XCTAssertTrue(evaluate(iteration, against: expected).isEmpty)
    }

    func testUnexpectedDisconnectFailsBeforeShutdown() {
        var iteration = IterationResult(iteration: 1)
        iteration.disconnectReason = "error"
        XCTAssertTrue(evaluate(iteration, against: nil).isEmpty)

        iteration.disconnectBeforeShutdown = "error"
        XCTAssertEqual(evaluate(iteration, against: nil), [
            "iteration 1: unexpected disconnect before shutdown: error"
        ])

        let expected = HarnessExpectation(disconnect: "error")
        XCTAssertTrue(evaluate(iteration, against: expected).isEmpty)
        iteration.disconnectBeforeShutdown = nil
        XCTAssertFalse(evaluate(iteration, against: expected).isEmpty)

        iteration.failure = "tlsHandshakeFailed"
        XCTAssertFalse(evaluate(iteration, against: nil).isEmpty)
        iteration.disconnectBeforeShutdown = "error"
        XCTAssertTrue(evaluate(iteration, against: HarnessExpectation(failure: "tlsHandshakeFailed")).isEmpty)
    }
}
