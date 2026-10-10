import AppKit
import RDPClientCore
import XCTest
@testable import RDPMacView

// The queue and the native sender are both driven by the test: nothing runs until `runAll()`,
// and every send is recorded (including the ones the fake is told to fail).

private final class ManualQueue {
    private var blocks: [() -> Void] = []

    var pendingCount: Int {
        blocks.count
    }

    func schedule(_ work: @escaping () -> Void) {
        blocks.append(work)
    }

    func runAll() {
        while !blocks.isEmpty {
            blocks.removeFirst()()
        }
    }
}

private final class FakeSender: RDPInputSending {
    enum Event: Equatable {
        case key(UInt16, pressed: Bool, extended: Bool)
        case unicode(UInt16, pressed: Bool)
        case move(UInt32, UInt32)
        case button(RDPPointerButton, UInt32, UInt32, pressed: Bool)
        case scroll(UInt32, UInt32, dx: Int32, dy: Int32)
    }

    struct SendFailure: Error {}

    var events: [Event] = []
    var connected = true
    var failing: (Event) -> Bool = { _ in false }
    var onSend: ((Event) -> Void)?

    var isConnected: Bool {
        connected
    }

    func perform(_ body: () -> Void) -> Bool {
        guard connected else {
            return false
        }
        body()
        return true
    }

    func sendKey(keyCode: UInt16, pressed: Bool, extended: Bool) throws {
        try record(.key(keyCode, pressed: pressed, extended: extended))
    }

    func sendUnicode(code: UInt16, pressed: Bool) throws {
        try record(.unicode(code, pressed: pressed))
    }

    func sendPointerMove(_ location: RDPPointerLocation) throws {
        try record(.move(location.pixelX, location.pixelY))
    }

    func sendPointerButton(_ button: RDPPointerButton, at location: RDPPointerLocation, pressed: Bool) throws {
        try record(.button(button, location.pixelX, location.pixelY, pressed: pressed))
    }

    func sendScroll(at location: RDPPointerLocation, deltaX: Int32, deltaY: Int32) throws {
        try record(.scroll(location.pixelX, location.pixelY, dx: deltaX, dy: deltaY))
    }

    private func record(_ event: Event) throws {
        events.append(event)
        onSend?(event)
        if failing(event) {
            throw SendFailure()
        }
    }
}

private final class Harness {
    let sender: FakeSender
    let queue: ManualQueue
    let executor: RDPInputExecutor

    init() {
        let sender = FakeSender()
        let queue = ManualQueue()
        self.sender = sender
        self.queue = queue
        self.executor = RDPInputExecutor(sender: sender) { work in
            queue.schedule(work)
        }
    }

    func activeSession() -> RDPSharedInputSession {
        let session = executor.makeSharedSession()
        XCTAssertTrue(session.activate())
        return session
    }

    func submit(_ session: RDPSharedInputSession, _ commands: RDPSharedInputCommand...) {
        for command in commands {
            XCTAssertTrue(session.submit(command))
        }
    }

    func close(_ session: RDPSharedInputSession) async -> RDPSharedInputCloseResult {
        session.beginClose()
        queue.runAll()
        return await session.finishClose()
    }
}

private let shift: UInt16 = 0x2A
private let control: UInt16 = 0x1D
private let alt: UInt16 = 0x38
private let windows: UInt16 = 0x15B
private let keyA: UInt16 = 0x1E
private let keyB: UInt16 = 0x30
private let keyV: UInt16 = 0x2F
private let enter: UInt16 = 0x1C
private let keypadEnter: UInt16 = 0x11C

private func down(_ code: UInt16, extended: Bool = false) -> FakeSender.Event {
    .key(code & 0xFF, pressed: true, extended: extended || (code & 0x100) != 0)
}

private func up(_ code: UInt16, extended: Bool = false) -> FakeSender.Event {
    .key(code & 0xFF, pressed: false, extended: extended || (code & 0x100) != 0)
}

final class RDPSharedInputSessionTests: XCTestCase {
    func testExtendedScancodeAndExplicitFlagShareTheSameOwnership() async {
        let h = Harness()
        let session = h.activeSession()
        h.executor.hostInjectKey(scanCode: 0x53, flags: [.down, .extended])
        h.submit(session, .key(scanCode: 0x153, pressed: true, modifiers: []))
        h.queue.runAll()
        h.sender.events.removeAll()
        let result = await h.close(session)
        XCTAssertEqual(result, .released)
        XCTAssertEqual(h.sender.events, [])
        h.executor.hostInjectKey(scanCode: 0x53, flags: [.up, .extended])
        h.queue.runAll()
        XCTAssertEqual(h.sender.events, [up(0x53, extended: true)])
    }

    func testWheelFailureWithoutHeldInputsIsStillFailed() async {
        let h = Harness()
        let session = h.activeSession()
        h.sender.failing = { _ in true }
        h.submit(session, .scroll(x: 1, y: 2, deltaY: 120, deltaX: 0, modifiers: []))
        h.queue.runAll()
        h.sender.failing = { _ in false }
        let result = await h.close(session)
        XCTAssertEqual(result, .failed(.sendFailed))
        XCTAssertFalse(h.executor.makeSharedSession().activate())
    }

    func testRejectedConnectDoesNotResetTheNativeConnectionGeneration() throws {
        let session = try RDPSession()
        let generation = session.connectionGeneration
        XCTAssertThrowsError(try session.connect(RDPConnectionOptions(host: "")))
        XCTAssertEqual(session.connectionGeneration, generation)
        var ran = false
        XCTAssertThrowsError(try session.withInputConnection(generation: generation) { ran = true })
        XCTAssertFalse(ran)
    }

    @MainActor
    func testTwoViewsAndReattachmentShareConnectionOwnershipAndFailureBlock() async throws {
        let native = try RDPSession()
        let queue = ManualQueue()
        let sender = FakeSender()
        let executor = RDPInputExecutorRegistry.executor(for: native, schedule: queue.schedule, makeSender: { _, _ in sender })
        let first = RDPClientView(frame: .zero)
        let second = RDPClientView(frame: .zero)
        first.session = native
        second.session = native
        let share = first.makeSharedInputSession()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit(.key(scanCode: keyA, pressed: true, modifiers: [])))
        second.injectKey(virtualKeyCode: 0, scanCode: keyA, flags: .down)
        queue.runAll()
        sender.events.removeAll()
        share.beginClose()
        queue.runAll()
        let result = await share.finishClose()
        XCTAssertEqual(result, .released)
        XCTAssertEqual(sender.events, [], "other view's host owner must survive share close")
        second.injectKey(virtualKeyCode: 0, scanCode: keyA, flags: .up)
        queue.runAll()
        XCTAssertEqual(sender.events, [up(keyA)])

        let failingShare = first.makeSharedInputSession()
        XCTAssertTrue(failingShare.activate())
        XCTAssertTrue(failingShare.submit(.key(scanCode: keyB, pressed: true, modifiers: [])))
        queue.runAll()
        sender.failing = { $0 == up(keyB) }
        failingShare.beginClose()
        queue.runAll()
        let failure = await failingShare.finishClose()
        XCTAssertEqual(failure, .failed(.sendFailed))
        XCTAssertFalse(second.makeSharedInputSession().activate())
        first.session = nil
        first.session = native
        XCTAssertFalse(first.makeSharedInputSession().activate())
        XCTAssertTrue(executor === RDPInputExecutorRegistry.executor(for: native, schedule: queue.schedule))
        first.shutdownRendering()
        second.shutdownRendering()
    }

    @MainActor
    func testDetachedViewHandleRetainsItsNativeSessionThroughClose() async throws {
        var native: RDPSession? = try RDPSession()
        weak var reference = native
        let view = RDPClientView(frame: .zero)
        view.session = native
        let handle = view.makeSharedInputSession()
        view.session = nil
        native = nil
        XCTAssertNotNil(reference)
        let result = await handle.finishClose()
        XCTAssertEqual(result, .released)
        view.shutdownRendering()
    }

    func testDelayedOldGenerationCannotReplaceNewConnectionRegistry() throws {
        let native = try RDPSession()
        let queue = ManualQueue()
        let newSender = FakeSender()
        let newest = RDPInputExecutorRegistry.executor(for: native, generation: 2, schedule: queue.schedule, makeSender: { _, _ in newSender })
        let stale = RDPInputExecutorRegistry.executor(for: native, generation: 1, schedule: queue.schedule, makeSender: { _, _ in FakeSender() })
        let next = RDPInputExecutorRegistry.executor(for: native, generation: 2, schedule: queue.schedule)
        XCTAssertFalse(stale === newest)
        XCTAssertTrue(next === newest, "stale request must not replace the new connection's executor")
        let handle = newest.makeSharedSession()
        XCTAssertTrue(handle.activate())
        newSender.failing = { _ in true }
        XCTAssertTrue(handle.submit(.key(scanCode: keyA, pressed: true, modifiers: [])))
        queue.runAll()
        XCTAssertFalse(next.makeSharedSession().activate(), "new generation keeps its send-failure block")
        handle.beginClose()
        queue.runAll()
    }

    func testLocalUnicodeSendFailureDoesNotBlockSharedActivation() {
        let h = Harness()
        h.sender.failing = { _ in true }
        h.executor.hostUnicode(code: 0x31, pressed: true)
        h.executor.hostUnicode(code: 0x31, pressed: false)
        h.queue.runAll()
        XCTAssertTrue(h.executor.makeSharedSession().activate())
    }

    func testEmptyFailedCloseAndFailedAdmissionKeepSharingBlocked() async {
        let h = Harness()
        let empty = h.activeSession()
        h.sender.connected = false
        let result = await h.close(empty)
        XCTAssertEqual(result, .failed(.connectionLost))
        h.sender.connected = true
        XCTAssertFalse(h.executor.makeSharedSession().activate())

        let other = Harness()
        let queued = other.activeSession()
        other.submit(queued, .key(scanCode: keyA, pressed: true, modifiers: []))
        other.sender.connected = false
        other.queue.runAll()
        other.sender.connected = true
        XCTAssertFalse(other.executor.makeSharedSession().activate())
        let queuedResult = await other.close(queued)
        XCTAssertEqual(queuedResult, .failed(.connectionLost))
    }

    func testClosingPreparedHandleDuringConnectDoesNotBlockLaterSharing() async {
        let h = Harness()
        h.sender.connected = false
        let prepared = h.executor.makeSharedSession()
        let result = await h.close(prepared)
        XCTAssertEqual(result, .released)
        XCTAssertEqual(h.sender.events, [])
        h.sender.connected = true
        XCTAssertTrue(h.executor.makeSharedSession().activate())
        XCTAssertFalse(prepared.activate())
    }

    // MARK: Lifecycle

    func testPreparedHandleDropsInputUntilActivated() {
        let h = Harness()
        let session = h.executor.makeSharedSession()

        XCTAssertFalse(session.submit(.key(scanCode: keyA, pressed: true, modifiers: [])))
        XCTAssertFalse(session.submit(.modifiers([control])))
        XCTAssertEqual(h.queue.pendingCount, 0)

        XCTAssertTrue(session.activate())
        XCTAssertFalse(session.activate())
        h.submit(session, .key(scanCode: keyA, pressed: true, modifiers: []))
        h.queue.runAll()
        XCTAssertEqual(h.sender.events, [down(keyA)])
    }

    func testClosedHandleCannotReactivateOrAcceptInput() async {
        let h = Harness()
        let session = h.activeSession()

        let result = await h.close(session)

        XCTAssertEqual(result, .released)
        XCTAssertFalse(session.activate())
        XCTAssertFalse(session.submit(.key(scanCode: keyA, pressed: true, modifiers: [])))
        let neverActivated = h.executor.makeSharedSession()
        neverActivated.beginClose()
        XCTAssertFalse(neverActivated.activate())
    }

    func testHandleClosedBeforeActivationReleasesNothing() async {
        let h = Harness()
        let session = h.executor.makeSharedSession()

        let result = await h.close(session)

        XCTAssertEqual(result, .released)
        XCTAssertEqual(h.sender.events, [])
    }

    func testBeginCloseGateDiscardsQueuedBacklogWithoutTouchingTheWire() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(
            session,
            .key(scanCode: keyA, pressed: true, modifiers: [control]),
            .mouse(x: 5, y: 6, button: .left, flags: [.move, .down], modifiers: [shift]),
            .chord([control, keyV])
        )

        session.beginClose()
        XCTAssertFalse(session.submit(.key(scanCode: keyB, pressed: true, modifiers: [])))
        h.queue.runAll()
        let result = await session.finishClose()

        XCTAssertEqual(h.sender.events, [])
        XCTAssertEqual(result, .released)
    }

    func testBacklogCloseReleasesOnlyWhatWasActuallySent() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(session, .key(scanCode: keyA, pressed: true, modifiers: []))
        h.queue.runAll()
        h.submit(session, .key(scanCode: keyB, pressed: true, modifiers: []))

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [down(keyA), up(keyA)])
        XCTAssertEqual(result, .released)
    }

    func testDiscardedCommandsDoNotMovePointerOrModifiers() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(session, .mouse(x: 1, y: 2, button: .left, flags: [.move, .down], modifiers: []))
        h.queue.runAll()
        h.submit(
            session,
            .mouse(x: 90, y: 91, button: nil, flags: [.move], modifiers: [control]),
            .scroll(x: 70, y: 71, deltaY: 1, deltaX: 0, modifiers: [alt])
        )

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [
            .move(1, 2),
            .button(.left, 1, 2, pressed: true),
            .button(.left, 1, 2, pressed: false)
        ])
        XCTAssertEqual(result, .released)
    }

    func testCommandAlreadyRunningCompletesBeforeCleanupAndLaterOnesAreDropped() async {
        let h = Harness()
        let session = h.activeSession()
        h.sender.onSend = { event in
            if event == down(keyV) {
                session.beginClose()
            }
        }
        h.submit(
            session,
            .chord([control, keyV]),
            .key(scanCode: keyB, pressed: true, modifiers: [])
        )

        h.queue.runAll()
        let result = await session.finishClose()

        XCTAssertEqual(h.sender.events, [down(control), down(keyV), up(keyV), up(control)])
        XCTAssertEqual(result, .released)
    }

    func testRepeatDownKeepsOneResponsibilityAndRepeatRacingCloseIsDropped() async {
        let h = Harness()
        let session = h.activeSession()
        let repeatDown = RDPSharedInputCommand.key(scanCode: keyA, pressed: true, modifiers: [])
        h.submit(session, repeatDown, repeatDown, repeatDown)
        h.queue.runAll()
        h.submit(session, repeatDown)

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [down(keyA), down(keyA), down(keyA), up(keyA)])
        XCTAssertEqual(result, .released)
    }

    func testRepeatedAndCancelledFinishCloseShareOneRelease() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(session, .key(scanCode: keyA, pressed: true, modifiers: []))
        h.queue.runAll()

        session.beginClose()
        session.beginClose()
        let waiter = Task { await session.finishClose() }
        waiter.cancel()
        h.queue.runAll()
        let first = await waiter.value
        let second = await session.finishClose()

        XCTAssertEqual(first, .released)
        XCTAssertEqual(second, .released)
        XCTAssertEqual(h.sender.events, [down(keyA), up(keyA)])
    }

    // MARK: Held input release

    func testCloseReleasesOrdinaryAndExtendedKeysAndAllThreeButtonsAtLastPointer() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(
            session,
            .key(scanCode: keyA, pressed: true, modifiers: []),
            .key(scanCode: keypadEnter, pressed: true, modifiers: []),
            .mouse(x: 10, y: 20, button: .left, flags: [.move, .down], modifiers: []),
            .mouse(x: 10, y: 20, button: .right, flags: [.down], modifiers: []),
            .mouse(x: 10, y: 20, button: .middle, flags: [.down], modifiers: []),
            .mouse(x: 30, y: 40, button: nil, flags: [.move], modifiers: [])
        )
        h.queue.runAll()
        h.sender.events.removeAll()

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [
            .button(.left, 30, 40, pressed: false),
            .button(.right, 30, 40, pressed: false),
            .button(.middle, 30, 40, pressed: false),
            up(keyA),
            up(keypadEnter)
        ])
        XCTAssertEqual(result, .released)
    }

    func testExtendedBitIsPartOfKeyIdentity() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(
            session,
            .key(scanCode: 0x53, pressed: true, modifiers: []),
            .key(scanCode: 0x153, pressed: true, modifiers: []),
            .key(scanCode: 0x53, pressed: false, modifiers: [])
        )
        h.queue.runAll()

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [down(0x53), down(0x153), up(0x53), up(0x153)])
        XCTAssertEqual(result, .released)
    }

    func testModifiersReleaseInReversePressOrderAfterOrdinaryKeys() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(
            session,
            .key(scanCode: keyA, pressed: true, modifiers: [shift, control]),
            .modifiers([shift, control, alt, windows])
        )
        h.queue.runAll()
        h.sender.events.removeAll()

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [up(keyA), up(windows), up(alt), up(control), up(shift)])
        XCTAssertEqual(result, .released)
    }

    func testKeyReleasePrecedesModifierSyncAndKeyDownFollowsIt() {
        let h = Harness()
        let session = h.activeSession()

        h.submit(session, .key(scanCode: keyA, pressed: true, modifiers: [control]))
        h.queue.runAll()
        XCTAssertEqual(h.sender.events, [down(control), down(keyA)])

        h.sender.events.removeAll()
        h.submit(session, .key(scanCode: keyA, pressed: false, modifiers: []))
        h.queue.runAll()
        XCTAssertEqual(h.sender.events, [up(keyA), up(control)])
    }

    func testMouseAndScrollSyncModifiersBeforeThePointerAction() {
        let h = Harness()
        let session = h.activeSession()

        h.submit(
            session,
            .mouse(x: 7, y: 8, button: .left, flags: [.move, .down], modifiers: [control]),
            .scroll(x: 9, y: 10, deltaY: -120, deltaX: 3, modifiers: [control, shift])
        )
        h.queue.runAll()

        XCTAssertEqual(h.sender.events, [
            down(control),
            .move(7, 8),
            .button(.left, 7, 8, pressed: true),
            down(shift),
            .scroll(9, 10, dx: 3, dy: -120)
        ])
    }

    func testChordPressesInOrderReleasesInReverseAndKeepsAlreadyHeldInputs() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(session, .modifiers([control]), .chord([control, shift, keyV]))
        h.queue.runAll()

        XCTAssertEqual(h.sender.events, [down(control), down(shift), down(keyV), up(keyV), up(shift)])

        let result = await h.close(session)
        XCTAssertEqual(h.sender.events.last, up(control))
        XCTAssertEqual(result, .released)
    }

    // MARK: Shared owner of the connection

    func testLocalInputIsOnTheSameQueueAndRecordIsShared() async {
        let h = Harness()

        h.executor.hostInjectKey(scanCode: keyA, flags: [.down])
        h.executor.hostMouse(x: 4, y: 5, button: .left, flags: [.move, .down])
        h.executor.hostUnicode(code: 0x35, pressed: true)
        XCTAssertEqual(h.queue.pendingCount, 3)
        XCTAssertEqual(h.sender.events, [])
        h.queue.runAll()

        let session = h.activeSession()
        h.submit(
            session,
            .key(scanCode: keyA, pressed: true, modifiers: []),
            .mouse(x: 4, y: 5, button: .left, flags: [.down], modifiers: [])
        )
        h.queue.runAll()
        h.sender.events.removeAll()

        let result = await h.close(session)

        // The host still holds both, so the share's close must not send either UP.
        XCTAssertEqual(h.sender.events, [])
        XCTAssertEqual(result, .released)

        h.executor.hostInjectKey(scanCode: keyA, flags: [.up])
        h.executor.hostMouse(x: 4, y: 5, button: .left, flags: [.up])
        h.executor.hostUnicode(code: 0x35, pressed: false)
        h.queue.runAll()
        XCTAssertEqual(h.sender.events, [
            up(keyA),
            .button(.left, 4, 5, pressed: false),
            .unicode(0x35, pressed: false)
        ])
    }

    func testHostReleaseWhileShareHoldsLeavesTheInputDownUntilShareCloses() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(
            session,
            .key(scanCode: keyA, pressed: true, modifiers: []),
            .mouse(x: 1, y: 1, button: .right, flags: [.down], modifiers: [])
        )
        h.queue.runAll()
        h.executor.hostInjectKey(scanCode: keyA, flags: [.down, .up])
        h.executor.hostMouse(x: 1, y: 1, button: .right, flags: [.down, .up])
        h.queue.runAll()
        h.sender.events.removeAll()

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [.button(.right, 1, 1, pressed: false), up(keyA)])
        XCTAssertEqual(result, .released)
    }

    func testHostChordDoesNotReleaseAModifierTheShareHolds() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(session, .modifiers([control]))
        h.queue.runAll()
        h.sender.events.removeAll()

        h.executor.hostChord([control, keyA])
        h.queue.runAll()
        XCTAssertEqual(h.sender.events, [down(control), down(keyA), up(keyA)])

        h.sender.events.removeAll()
        let result = await h.close(session)
        XCTAssertEqual(h.sender.events, [up(control)])
        XCTAssertEqual(result, .released)
    }

    func testHostKeyFlagExtendedStaysADistinctKey() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(session, .key(scanCode: 0x53, pressed: true, modifiers: []))
        h.queue.runAll()
        h.executor.hostInjectKey(scanCode: 0x53, flags: [.down, .extended])
        h.executor.hostInjectKey(scanCode: 0x53, flags: [.up, .extended])
        h.queue.runAll()
        h.sender.events.removeAll()

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [up(0x53)])
        XCTAssertEqual(result, .released)
    }

    // MARK: Failures

    func testFailedDownKeepsResponsibilityAndBlocksResharing() async {
        let h = Harness()
        let session = h.activeSession()
        h.sender.failing = { $0 == down(keyA) }
        h.submit(session, .key(scanCode: keyA, pressed: true, modifiers: []))
        h.queue.runAll()
        h.sender.failing = { _ in false }

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [down(keyA), up(keyA)])
        XCTAssertEqual(result, .failed(.sendFailed))
        XCTAssertFalse(h.executor.makeSharedSession().activate())
    }

    func testFailedUpIsReportedAndKeepsLedgerAndBlocksResharing() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(session, .key(scanCode: keyA, pressed: true, modifiers: [control]))
        h.queue.runAll()
        h.sender.failing = { $0 == up(keyA) }
        h.sender.events.removeAll()

        let result = await h.close(session)

        // Control is still released even though A's UP failed.
        XCTAssertEqual(h.sender.events, [up(keyA), up(control)])
        XCTAssertEqual(result, .failed(.sendFailed))
        let next = h.executor.makeSharedSession()
        XCTAssertFalse(next.activate())
        XCTAssertFalse(next.submit(.modifiers([])))
    }

    func testFailedUpOnDirectKeyReleaseDoesNotClearTheRecord() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(session, .key(scanCode: keyA, pressed: true, modifiers: []))
        h.queue.runAll()
        h.sender.failing = { $0 == up(keyA) }
        h.submit(session, .key(scanCode: keyA, pressed: false, modifiers: []))
        h.queue.runAll()
        h.sender.failing = { _ in false }
        h.sender.events.removeAll()

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [up(keyA)])
        XCTAssertEqual(result, .failed(.sendFailed))
    }

    func testWheelErrorBlocksResharingAndDoesNotMoveTheRecordedPointer() async {
        let h = Harness()
        let session = h.activeSession()
        h.submit(session, .mouse(x: 5, y: 5, button: .left, flags: [.move, .down], modifiers: []))
        h.queue.runAll()
        h.sender.failing = { event in
            if case .scroll = event { return true }
            return false
        }
        h.submit(session, .scroll(x: 50, y: 60, deltaY: 120, deltaX: 0, modifiers: []))
        h.queue.runAll()
        h.sender.failing = { _ in false }
        h.sender.events.removeAll()

        let result = await h.close(session)

        XCTAssertEqual(h.sender.events, [.button(.left, 5, 5, pressed: false)])
        XCTAssertEqual(result, .failed(.sendFailed))
        XCTAssertFalse(h.executor.makeSharedSession().activate())
    }

    func testConnectionLossFailsCloseOfHeldInputWithoutSending() async {
        let h = Harness()
        let holding = h.activeSession()
        let idle = h.activeSession()
        h.submit(holding, .key(scanCode: keyA, pressed: true, modifiers: []))
        h.queue.runAll()
        h.sender.events.removeAll()
        h.sender.connected = false
        h.submit(holding, .key(scanCode: keyB, pressed: true, modifiers: []))

        let holdingResult = await h.close(holding)
        let idleResult = await h.close(idle)

        XCTAssertEqual(h.sender.events, [])
        XCTAssertEqual(holdingResult, .failed(.connectionLost))
        XCTAssertEqual(idleResult, .failed(.connectionLost))
        XCTAssertFalse(h.executor.makeSharedSession().activate())
    }

    func testOldHandleNeverReachesANewConnection() async {
        let old = Harness()
        let fresh = Harness()
        let oldSession = old.activeSession()
        old.submit(oldSession, .key(scanCode: keyA, pressed: true, modifiers: []))
        old.queue.runAll()
        old.sender.connected = false
        old.sender.failing = { _ in true }

        let freshSession = fresh.activeSession()
        let oldResult = await old.close(oldSession)
        XCTAssertFalse(oldSession.submit(.key(scanCode: keyB, pressed: true, modifiers: [])))
        XCTAssertTrue(freshSession.submit(.key(scanCode: keyB, pressed: true, modifiers: [])))
        fresh.queue.runAll()

        XCTAssertEqual(oldResult, .failed(.connectionLost))
        XCTAssertEqual(fresh.sender.events, [down(keyB)])
        // A block on the old connection does not carry over to the new executor.
        XCTAssertTrue(fresh.executor.makeSharedSession().activate())
    }

    // MARK: Views

    @MainActor
    func testViewsWithoutAConnectionVendInactiveConnectionLostHandles() async {
        let clientView = RDPClientView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let connectionView = RDPConnectionView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))

        let handles = [clientView.makeSharedInputSession(), connectionView.makeSharedInputSession()]
        connectionView.shutdown()
        let afterShutdown = connectionView.makeSharedInputSession()

        for handle in handles + [afterShutdown] {
            XCTAssertFalse(handle.activate())
            XCTAssertFalse(handle.submit(.modifiers([control])))
            let result = await handle.finishClose()
            XCTAssertEqual(result, .failed(.connectionLost))
        }
    }
}
