import AppKit
import XCTest
@testable import RDPMacView

private let deviceRightAlt: UInt = 0x40
private let deviceLeftCommand: UInt = 0x08
private let deviceRightCommand: UInt = 0x10

private func flags(_ base: NSEvent.ModifierFlags, device: UInt = 0) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: base.rawValue | device)
}

private let rightOption = flags(.option, device: deviceRightAlt)
private let rightCommand = flags(.command, device: deviceRightCommand)

final class RDPFollowKeyGateTests: XCTestCase {
    private var follower = RDPInputSourceFollower()
    private var gate = RDPFollowKeyGate()

    override func setUp() {
        super.setUp()
        follower = RDPInputSourceFollower()
        follower.focusGained(at: 0, language: .other)
        follower.settleElapsed(at: 1, language: .other)
        gate = RDPFollowKeyGate()
    }

    private func down(_ keyCode: UInt16, repeat isRepeat: Bool = false, changed: Bool = false,
                      candidate: Bool = false, active: Bool = true, at now: TimeInterval = 10) -> RDPFollowKeyGate.KeyDownAction {
        gate.keyDown(keyCode: keyCode, isRepeat: isRepeat, sourceChanged: changed, isSwitchCandidate: candidate,
                     followActive: active, follower: &follower, now: now)
    }

    private func up(_ keyCode: UInt16, at now: TimeInterval = 10) -> RDPFollowKeyGate.KeyUpAction {
        gate.keyUp(keyCode: keyCode, follower: &follower, now: now)
    }

    private func flagsChanged(_ value: NSEvent.ModifierFlags, active: Bool = true, at now: TimeInterval = 10) -> [NSEvent.ModifierFlags] {
        gate.modifiersChanged(value, followActive: active, follower: &follower, now: now)
    }

    /// Makes an async flip at `now`, so R6 suppresses raw toggles for `T_merge` after it.
    private func asyncFlip(at now: TimeInterval) {
        XCTAssertEqual(follower.observe(.korean, at: now, cause: .async), .sendToggle(.languageFlipped))
    }

    // MARK: Fates (G3, I-G4)

    func testForwardedPressKeepsItsRepeatAndKeyUpWhateverComesLater() {
        XCTAssertEqual(down(49), .forward)
        XCTAssertEqual(gate.fate(of: 49), .forwarded)
        XCTAssertEqual(down(49, repeat: true, changed: true, candidate: true), .forward)
        XCTAssertEqual(up(49), .forward)
        XCTAssertNil(gate.fate(of: 49))
    }

    func testSwitchCandidateIsSuppressedOnlyWhenTheSourceChanged() {
        XCTAssertEqual(down(49, changed: false, candidate: true), .forward)
        XCTAssertEqual(up(49), .forward)
        XCTAssertEqual(down(49, changed: true, candidate: false), .forward)
        XCTAssertEqual(up(49), .forward)
        XCTAssertEqual(down(49, changed: true, candidate: true), .drop)
        XCTAssertEqual(down(49, repeat: true), .drop)
        XCTAssertEqual(up(49), .drop)
        // A key with no open press goes up as usual.
        XCTAssertEqual(up(49), .forward)
    }

    func testIMEKeysTapOncePerPressAndNeverSendRepeatOrKeyUp() {
        XCTAssertEqual(down(104), .imeTap(.hangul))
        XCTAssertEqual(down(104, repeat: true), .drop)
        XCTAssertEqual(up(104), .drop)
        XCTAssertEqual(down(102, active: false), .imeTap(.hanja))
        XCTAssertEqual(down(102, repeat: true, active: false), .drop)
        XCTAssertEqual(up(102), .drop)
        // A repeat with no open press is still never sent.
        XCTAssertEqual(down(104, repeat: true), .drop)
    }

    func testR6SuppressedHangulKeySwallowsRepeatAndKeyUpAndTheNextPressTaps() {
        asyncFlip(at: 10)
        XCTAssertEqual(down(104, at: 10.1), .drop)
        XCTAssertEqual(gate.fate(of: 104), .suppressed)
        XCTAssertEqual(down(104, repeat: true, at: 10.5), .drop)
        XCTAssertEqual(up(104, at: 10.6), .drop)
        XCTAssertEqual(down(104, at: 10.7), .imeTap(.hangul))
    }

    func testHangulKeyIsARawToggleUntilItsKeyUp() {
        XCTAssertEqual(down(104, at: 10), .imeTap(.hangul))
        // Still held 400 ms later: the flip merges with it.
        XCTAssertEqual(follower.observe(.korean, at: 10.4, cause: .async), .none(.mergedWithRawToggle))
        XCTAssertEqual(up(104, at: 10.5), .drop)
    }

    func testHangulKeyWithoutFollowDoesNotTouchTheFollower() {
        asyncFlip(at: 10)
        XCTAssertEqual(down(104, active: false, at: 10.1), .imeTap(.hangul))
        XCTAssertEqual(up(104, at: 10.2), .drop)
    }

    // MARK: Source tracking (G2)

    func testSourceChangeComparesIDsAndFallsBackToTheLanguage() {
        gate.resetSource(to: "a")
        XCTAssertFalse(gate.sourceChanged(id: "a", language: .other, baseline: .other))
        XCTAssertTrue(gate.sourceChanged(id: "b", language: .other, baseline: .other))
        XCTAssertFalse(gate.sourceChanged(id: "b", language: .korean, baseline: .other))
        XCTAssertTrue(gate.sourceChanged(id: nil, language: .korean, baseline: .other))
        XCTAssertFalse(gate.sourceChanged(id: "c", language: .other, baseline: .other))
    }

    // MARK: Right Option (R6 latch) and outbound (I-G2)

    func testRightOptionAfterAFlipIsKeptOffEveryFrameUntilReleased() {
        asyncFlip(at: 10)
        XCTAssertEqual(flagsChanged(rightOption, at: 10.1), [[]])
        XCTAssertEqual(gate.outbound(rightOption), [])
        XCTAssertEqual(gate.outbound(flags([.option, .shift], device: deviceRightAlt)), .shift)
        XCTAssertEqual(flagsChanged([], at: 10.2), [[]])
        XCTAssertEqual(gate.outbound(rightOption), rightOption)
    }

    func testRightOptionOutsideTheMergeWindowIsARawToggle() {
        XCTAssertEqual(flagsChanged(rightOption, at: 10), [rightOption])
        XCTAssertEqual(follower.observe(.korean, at: 10.1, cause: .async), .none(.mergedWithRawToggle))
        XCTAssertEqual(flagsChanged([], at: 10.2), [[]])
    }

    func testModifierFramesPassThroughWithoutFollow() {
        asyncFlip(at: 10)
        XCTAssertEqual(flagsChanged(rightOption, active: false, at: 10.1), [rightOption])
    }

    // MARK: Right Command hold (viewer)

    func testRightCommandIsNotHeldUnlessEnabled() {
        XCTAssertEqual(flagsChanged(rightCommand), [rightCommand])
        XCTAssertNil(gate.rightCommandDeadline)
    }

    func testRightCommandTapIsHeldUntilItsDeadline() {
        gate = RDPFollowKeyGate(holdsRightCommand: true)
        XCTAssertEqual(flagsChanged(rightCommand, at: 10), [])
        XCTAssertEqual(gate.outbound(rightCommand), [])
        XCTAssertEqual(flagsChanged([], at: 10.1), [])
        XCTAssertEqual(gate.rightCommandDeadline ?? 0, 10.4, accuracy: 1e-9)
        XCTAssertEqual(gate.flushIfExpired(at: 10.3), [])
        XCTAssertEqual(gate.flushIfExpired(at: 10.5), [rightCommand, []])
        XCTAssertNil(gate.rightCommandDeadline)
    }

    func testHeldRightCommandGoesOutBeforeOtherInput() {
        gate = RDPFollowKeyGate(holdsRightCommand: true)
        XCTAssertEqual(flagsChanged(rightCommand), [])
        XCTAssertEqual(gate.flushForOtherInput(), [rightCommand])
        XCTAssertEqual(gate.outbound(rightCommand), rightCommand)
        XCTAssertEqual(gate.flushForOtherInput(), [])
    }

    func testRightCommandWithAnotherModifierIsSentAtOnce() {
        gate = RDPFollowKeyGate(holdsRightCommand: true)
        XCTAssertEqual(flagsChanged(rightCommand), [])
        let withShift = flags([.command, .shift], device: deviceRightCommand)
        XCTAssertEqual(flagsChanged(withShift), [rightCommand, withShift])
    }

    func testFollowToggleConsumesAHeldRightCommandUntilItIsReleased() {
        gate = RDPFollowKeyGate(holdsRightCommand: true)
        XCTAssertEqual(flagsChanged(rightCommand), [])
        gate.followToggleSent()
        XCTAssertEqual(gate.flushForOtherInput(), [])
        XCTAssertEqual(gate.outbound(rightCommand), [])
        XCTAssertEqual(gate.outbound(flags(.command, device: deviceLeftCommand)), [])
        XCTAssertEqual(flagsChanged([]), [[]])
        XCTAssertEqual(gate.outbound(rightCommand), rightCommand)
    }

    func testFollowToggleDropsAPendingRightCommandTap() {
        gate = RDPFollowKeyGate(holdsRightCommand: true)
        XCTAssertEqual(flagsChanged(rightCommand, at: 10), [])
        XCTAssertEqual(flagsChanged([], at: 10.1), [])
        gate.followToggleSent()
        XCTAssertNil(gate.rightCommandDeadline)
        XCTAssertEqual(gate.flushIfExpired(at: 11), [])
    }

    func testResetForgetsPressesAndLatches() {
        gate = RDPFollowKeyGate(holdsRightCommand: true)
        XCTAssertEqual(down(49, changed: true, candidate: true), .drop)
        XCTAssertEqual(flagsChanged(rightCommand), [])
        gate.reset()
        XCTAssertNil(gate.fate(of: 49))
        XCTAssertEqual(up(49), .forward)
        XCTAssertEqual(gate.outbound(rightCommand), rightCommand)
    }
}
