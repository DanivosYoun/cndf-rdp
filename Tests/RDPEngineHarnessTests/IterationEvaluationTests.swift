import XCTest
@testable import RDPEngineHarness

final class IterationEvaluationTests: XCTestCase {
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
