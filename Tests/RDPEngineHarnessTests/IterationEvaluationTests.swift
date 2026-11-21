import XCTest
@testable import RDPEngineHarness

final class IterationEvaluationTests: XCTestCase {
    func testResizeFailsWhenTheFinalFrameSizeWasNotApplied() {
        var iteration = IterationResult(iteration: 1)
        iteration.connectRises = 1
        iteration.connectedAfterResize = true
        iteration.displayControlReady = true
        iteration.requestedResizeFrameSize = [1280, 800]
        let expected = HarnessExpectation(resizeKeepsSession: true)

        XCTAssertEqual(evaluateResizeFrameSize(iteration, against: expected).status, .fail)
        XCTAssertFalse(evaluate(iteration, against: expected).isEmpty)
        iteration.resizeFrameSize = [960, 640]
        XCTAssertEqual(evaluateResizeFrameSize(iteration, against: expected).status, .fail)
        XCTAssertFalse(evaluate(iteration, against: expected).isEmpty)
        iteration.resizeFrameSize = [1280, 800]
        XCTAssertEqual(evaluateResizeFrameSize(iteration, against: expected).status, .pass)
        XCTAssertTrue(evaluate(iteration, against: expected).isEmpty)
    }

    func testResizeIsNotApplicableWithoutDisplayControl() {
        var iteration = IterationResult(iteration: 1)
        iteration.connectRises = 1
        iteration.connectedAfterResize = true
        iteration.requestedResizeFrameSize = [1024, 700]
        iteration.resizeFrameSize = [1280, 800]
        let expected = HarnessExpectation(resizeKeepsSession: true)

        // Nil and false displayControlReady both mark the final size check N/A without failing.
        XCTAssertEqual(evaluateResizeFrameSize(iteration, against: expected).status, .notApplicable)
        XCTAssertEqual(evaluateResizeFrameSize(iteration, against: expected).status?.rawValue, "N/A")
        XCTAssertEqual(evaluate(iteration, against: expected), [])

        iteration.displayControlReady = false
        XCTAssertEqual(evaluateResizeFrameSize(iteration, against: expected).status, .notApplicable)
        XCTAssertEqual(evaluate(iteration, against: expected), [])

        // Session drop or reconnect must still fail even when Display Control did not open.
        iteration.connectedAfterResize = false
        XCTAssertFalse(evaluate(iteration, against: expected).isEmpty)
        iteration.connectedAfterResize = true
        iteration.connectRises = 2
        XCTAssertFalse(evaluate(iteration, against: expected).isEmpty)
    }

    func testResizeIsNotApplicableWhenScenarioOptedOut() {
        var iteration = IterationResult(iteration: 1)
        iteration.connectRises = 1
        iteration.connectedAfterResize = true
        iteration.displayControlReady = true
        iteration.requestedResizeFrameSize = [1024, 700]
        iteration.resizeFrameSize = [1920, 1080]
        let expected = HarnessExpectation(resizeKeepsSession: true, resizeAppliesFrameSize: false)

        XCTAssertEqual(evaluateResizeFrameSize(iteration, against: expected).status, .notApplicable)
        XCTAssertEqual(evaluate(iteration, against: expected), [])

        iteration.connectedAfterResize = false
        XCTAssertFalse(evaluate(iteration, against: expected).isEmpty)
    }

    func testResizeFailsWhenExplicitlyRequiredWithoutDisplayControl() {
        var iteration = IterationResult(iteration: 1)
        iteration.connectRises = 1
        iteration.connectedAfterResize = true
        iteration.displayControlReady = false
        iteration.requestedResizeFrameSize = [1024, 700]
        iteration.resizeFrameSize = [1024, 700]
        let expected = HarnessExpectation(resizeKeepsSession: true, resizeAppliesFrameSize: true)

        XCTAssertEqual(evaluateResizeFrameSize(iteration, against: expected).status, .fail)
        XCTAssertEqual(evaluate(iteration, against: expected), [
            "iteration 1: resize: Display Control did not open"
        ])
    }

    func testDisplayControlReadyLogTransitions() {
        XCTAssertFalse(updateDisplayControlReady(false, forLogMessage: "Display control channel connected."))
        XCTAssertTrue(updateDisplayControlReady(
            false,
            forLogMessage: "Display control capabilities received: maxMonitors=1 maxArea=9216000."
        ))
        XCTAssertTrue(updateDisplayControlReady(true, forLogMessage: "Display resize encoded: 1024x700."))
        XCTAssertFalse(updateDisplayControlReady(true, forLogMessage: "Display control channel closed."))
        XCTAssertFalse(updateDisplayControlReady(true, forLogMessage: "FreeRDP disconnected."))
        XCTAssertFalse(updateDisplayControlReady(true, forLogMessage: "IronRDP disconnected."))
    }

    func testChannelStepFailureFailsTheIterationWithoutAnExpectation() {
        var iteration = IterationResult(iteration: 1)
        iteration.steps = ["clipboardSetRemote:ok", "clipboardExpectLocal:failed", "shutdown:ok"]
        XCTAssertEqual(evaluate(iteration, against: nil), [
            "iteration 1: clipboardExpectLocal:failed"
        ])
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
