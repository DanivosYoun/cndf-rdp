import RDPMacView
import XCTest

final class RDPOutputSuppressionPolicyTests: XCTestCase {
    private typealias Inputs = RDPOutputSuppressionPolicy.Inputs

    private let hidden = Inputs(enabled: true, connected: true, visible: false, frameTapAttached: false)

    func testHiddenSuppressesOnlyAfterDebounce() {
        var policy = RDPOutputSuppressionPolicy()

        XCTAssertEqual(policy.evaluate(hidden, now: 10.0), .recheck(after: 1.0))
        XCTAssertEqual(policy.evaluate(hidden, now: 10.5), .recheck(after: 0.5))
        XCTAssertFalse(policy.isSuppressed)
        XCTAssertEqual(policy.evaluate(hidden, now: 11.0), .suppress)
        XCTAssertTrue(policy.isSuppressed)
        XCTAssertEqual(policy.evaluate(hidden, now: 12.0), .none)
    }

    func testBecomingVisibleWithinDebounceNeverSuppresses() {
        var policy = RDPOutputSuppressionPolicy()
        var visible = hidden
        visible.visible = true

        XCTAssertEqual(policy.evaluate(hidden, now: 0), .recheck(after: 1.0))
        XCTAssertEqual(policy.evaluate(visible, now: 0.5), .none)
        // The debounce restarts on the next hide.
        XCTAssertEqual(policy.evaluate(hidden, now: 1.2), .recheck(after: 1.0))
        XCTAssertFalse(policy.isSuppressed)
    }

    func testBecomingVisibleReleasesImmediately() {
        var policy = suppressedPolicy()
        var visible = hidden
        visible.visible = true

        XCTAssertEqual(policy.evaluate(visible, now: 5.0), .release)
        XCTAssertFalse(policy.isSuppressed)
        XCTAssertEqual(policy.evaluate(visible, now: 5.1), .none)
    }

    func testAttachingFrameTapReleasesImmediately() {
        var policy = suppressedPolicy()
        var tapped = hidden
        tapped.frameTapAttached = true

        XCTAssertEqual(policy.evaluate(tapped, now: 5.0), .release)
    }

    func testNeverSuppressesWithFrameTapAttached() {
        var policy = RDPOutputSuppressionPolicy()
        var tapped = hidden
        tapped.frameTapAttached = true

        for now in stride(from: 0.0, through: 10.0, by: 0.5) {
            XCTAssertEqual(policy.evaluate(tapped, now: now), .none)
        }
        XCTAssertFalse(policy.isSuppressed)
    }

    func testDisabledOrDisconnectedNeverSuppresses() {
        var policy = RDPOutputSuppressionPolicy()
        var disabled = hidden
        disabled.enabled = false
        var disconnected = hidden
        disconnected.connected = false

        XCTAssertEqual(policy.evaluate(disabled, now: 0), .none)
        XCTAssertEqual(policy.evaluate(disabled, now: 5), .none)
        XCTAssertEqual(policy.evaluate(disconnected, now: 10), .none)
        XCTAssertEqual(policy.evaluate(disconnected, now: 15), .none)
        XCTAssertFalse(policy.isSuppressed)
    }

    func testTurningFeatureOffReleases() {
        var policy = suppressedPolicy()
        var disabled = hidden
        disabled.enabled = false

        XCTAssertEqual(policy.evaluate(disabled, now: 5.0), .release)
    }

    func testDisconnectDropsStateWithoutRelease() {
        var policy = suppressedPolicy()
        var disconnected = hidden
        disconnected.connected = false

        XCTAssertEqual(policy.evaluate(disconnected, now: 5.0), .none)
        XCTAssertFalse(policy.isSuppressed)
    }

    func testReconnectReevaluatesFromAllowedOutput() {
        var policy = suppressedPolicy()

        policy.connectionDidReset()

        XCTAssertFalse(policy.isSuppressed)
        XCTAssertEqual(policy.evaluate(hidden, now: 20.0), .recheck(after: 1.0))
        XCTAssertEqual(policy.evaluate(hidden, now: 21.0), .suppress)
    }

    private func suppressedPolicy() -> RDPOutputSuppressionPolicy {
        var policy = RDPOutputSuppressionPolicy()
        _ = policy.evaluate(hidden, now: 0)
        XCTAssertEqual(policy.evaluate(hidden, now: 1.0), .suppress)
        return policy
    }
}
