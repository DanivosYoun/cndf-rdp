import AppKit
import CoreGraphics
import RDPClientCore
import XCTest
@testable import RDPMacView

private final class FakeInputSourceReader: RDPInputSourceReading {
    var language: RDPInputLanguage
    var sourceID: String?

    init(language: RDPInputLanguage = .other, sourceID: String? = "com.apple.keylayout.ABC") {
        self.language = language
        self.sourceID = sourceID
    }

    func currentLanguage() -> RDPInputLanguage { language }
    func currentSourceID() -> String? { sourceID }
}

private final class FakeClock {
    var now: TimeInterval
    init(_ start: TimeInterval = 100.0) { self.now = start }
    func advance(by delta: TimeInterval) { now += delta }
}

private final class RecordingDelegate: RDPSessionDelegate {
    var logs: [String] = []
    func rdpSession(_ session: RDPEngineSession, didLog message: String) {
        logs.append(message)
    }
    func rdpSession(_ session: RDPEngineSession, shouldTrustCertificateFingerprint fingerprint: String, hostname: String, port: UInt16) async -> Bool { false }
    func rdpSession(_ session: RDPEngineSession, didFailWith error: RDPSessionError) {}
    func rdpSession(_ session: RDPEngineSession, didDisconnectWith reason: RDPDisconnectReason) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteText text: String) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveFrame frame: RDPFrame) {}
    func rdpSession(_ session: RDPEngineSession, didUpdatePointer pointer: RDPRemotePointer) {}
    func rdpSessionOutputResumedForInput(_ session: RDPEngineSession) {}
}

private final class FollowKeySession: RDPEngineSession {
    struct Key: Equatable {
        let code: UInt16
        let pressed: Bool
        let extended: Bool
    }

    private let lock = NSLock()
    private var recorded: [Key] = []
    var keyboardProfile: RDPKeyboardProfile
    var isConnected: Bool = true

    init(profile: RDPKeyboardProfile) {
        keyboardProfile = profile
    }

    var keys: [Key] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func clearKeys() {
        lock.lock()
        recorded.removeAll()
        lock.unlock()
    }

    let engine = RDPEngineKind.freeRDP
    weak var delegate: RDPSessionDelegate?
    var connectionGeneration: UInt64 { 1 }
    func isInputConnectionCurrent(generation: UInt64) -> Bool { isConnected }
    func withInputConnection(generation: UInt64, _ body: () throws -> Void) throws {
        guard isConnected else { throw RDPSessionError.unableToCreateBridgeSession }
        try body()
    }
    var statistics: RDPConnectionStatistics { fatalError("not used") }
    func connect(_ options: RDPConnectionOptions, initialPointSize: CGSize, scale: Double) throws {}
    func reconnect() throws {}
    func disconnect() throws {}
    var supportsClipboard: Bool { false }
    func pollLocalClipboard() throws {}
    func sendLocalFiles(_ urls: [URL]) throws {}
    func sendLocalText(_ text: String) throws {}
    func updateDesktopSize(pointWidth: Double, pointHeight: Double, scale: Double, force: Bool) throws {}
    var supportsOutputSuppression: Bool { false }
    func setOutputSuppressed(_ suppressed: Bool) throws {}
    func sendPointerMove(_ location: RDPPointerLocation) throws {}
    func sendPointerButton(_ button: RDPPointerButton, at location: RDPPointerLocation, pressed: Bool) throws {}
    func sendScroll(at location: RDPPointerLocation, deltaX: Int32, deltaY: Int32) throws -> Bool { true }
    func sendUnicode(code: UInt16, pressed: Bool) throws {}

    func sendKey(keyCode: UInt16, pressed: Bool, extended: Bool) throws {
        lock.lock()
        recorded.append(Key(code: keyCode, pressed: pressed, extended: extended))
        lock.unlock()
    }
}

private let deviceLeftAlt: UInt = 0x20
private let deviceRightAlt: UInt = 0x40
private let hangulDown = FollowKeySession.Key(code: 0x38, pressed: true, extended: true)
private let hangulUp = FollowKeySession.Key(code: 0x38, pressed: false, extended: true)
private let maskDown = FollowKeySession.Key(code: 0x1D, pressed: true, extended: false)
private let maskUp = FollowKeySession.Key(code: 0x1D, pressed: false, extended: false)
/// The masked Hangul tap on `.korean` (design G6): E0 38 down, 1D down, 1D up, E0 38 up.
private let hangulTap = [hangulDown, maskDown, maskUp, hangulUp]

private func flags(_ base: NSEvent.ModifierFlags, device: UInt = 0) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: base.rawValue | device)
}

private func keyEvent(
    _ type: NSEvent.EventType,
    keyCode: UInt16,
    modifierFlags: NSEvent.ModifierFlags = [],
    isARepeat: Bool = false
) -> NSEvent {
    NSEvent.keyEvent(
        with: type,
        location: .zero,
        modifierFlags: modifierFlags,
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        characters: "",
        charactersIgnoringModifiers: "",
        isARepeat: isARepeat,
        keyCode: keyCode
    )!
}

private func flagsEvent(_ modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
    let event = CGEvent(source: nil)!
    event.type = .flagsChanged
    event.flags = CGEventFlags(rawValue: UInt64(modifierFlags.rawValue))
    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
    return NSEvent(cgEvent: event)!
}

@MainActor
final class RDPClientViewFollowTests: XCTestCase {
    private func makeFixture(
        profile: RDPKeyboardProfile = .korean,
        follow: Bool = true,
        hotkeys: [RDPSwitchHotkey] = RDPSymbolicHotKeys.defaultSwitchHotkeys
    ) -> (RDPClientView, FollowKeySession, FakeInputSourceReader, FakeClock, NotificationCenter, RecordingDelegate) {
        let session = FollowKeySession(profile: profile)
        let delegate = RecordingDelegate()
        session.delegate = delegate
        let reader = FakeInputSourceReader(language: .other, sourceID: "com.apple.keylayout.ABC")
        let clock = FakeClock(100.0)
        let center = NotificationCenter()

        let view = RDPClientView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.configureInputSourceFollowForTesting(
            reader: reader,
            observer: RDPMacInputSourceObserver(center: center),
            clock: { clock.now },
            isFocused: { true },
            switchHotkeys: hotkeys
        )
        view.session = session
        view.inputSourceFollow = follow
        if follow {
            view.handleInputSourceFocusGained()
            clock.advance(by: RDPInputSourceFollower.defaultSettleInterval)
            view.handleInputSourceSettleElapsed()
        }
        addTeardownBlock { [session, delegate] in
            view.shutdownRendering()
            _ = session
            _ = delegate
        }
        return (view, session, reader, clock, center, delegate)
    }

    private func waitForKeys(_ session: FollowKeySession, count: Int) -> [FollowKeySession.Key] {
        let deadline = Date().addingTimeInterval(2)
        while session.keys.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return session.keys
    }

    // MARK: I-F4 ordering

    func testPreCheckTogglePrecedesKeyOnExecutorQueue() {
        let (view, session, reader, _, _, delegate) = makeFixture()
        // Flip Mac source to Korean, then press 'r' (keyCode 15 -> scancode 0x13).
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        view.keyDown(with: keyEvent(.keyDown, keyCode: 15))

        XCTAssertEqual(waitForKeys(session, count: 5), hangulTap + [
            FollowKeySession.Key(code: 0x13, pressed: true, extended: false)
        ])
        XCTAssertTrue(delegate.logs.contains(
            "RDP input-source follow: languageFlipped lang=ko cause=async sent=toggle"
        ))
    }

    // MARK: F0b duplicate & unchanged notifications

    func testDuplicateAndUnchangedNotificationsSendSingleToggle() {
        let (_, session, reader, clock, center, delegate) = makeFixture()
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"

        // One switch fires two notifications 5 ms apart (observed in F0b).
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
        clock.advance(by: 0.005)
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)

        // Same-classification switch (2-bulsik -> 3-bulsik) fires notification.
        clock.advance(by: 0.100)
        reader.sourceID = "com.apple.inputmethod.Korean.3SetKorean"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)

        XCTAssertEqual(waitForKeys(session, count: 4), hangulTap)
        XCTAssertTrue(delegate.logs.contains(
            "RDP input-source follow: unchanged lang=ko cause=async sent=none"
        ))
    }

    // MARK: I-F5 hotkey suppression, Caps Lock, no F1b inputContext

    func testSwitchHotkeyPreCheckChangeSuppressesKeyDownRepeatAndKeyUp() {
        let (view, session, reader, _, _, _) = makeFixture()
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"

        // Control+Space (keyCode 49) arrives with Mac source already flipped.
        view.keyDown(with: keyEvent(.keyDown, keyCode: 49, modifierFlags: [.control]))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 49, modifierFlags: [.control], isARepeat: true))
        view.keyUp(with: keyEvent(.keyUp, keyCode: 49, modifierFlags: [.control]))

        // Only Hangul chord is sent; Space (0x39) is completely suppressed.
        XCTAssertEqual(waitForKeys(session, count: 4), hangulTap)
    }

    func testSwitchHotkeyWithoutSourceChangeForwardsSpaceNormally() {
        let (view, session, _, _, _, _) = makeFixture(hotkeys: [])
        view.keyDown(with: keyEvent(.keyDown, keyCode: 49, modifierFlags: [.control]))
        view.keyUp(with: keyEvent(.keyUp, keyCode: 49, modifierFlags: [.control]))

        XCTAssertEqual(waitForKeys(session, count: 2), [
            FollowKeySession.Key(code: 0x39, pressed: true, extended: false),
            FollowKeySession.Key(code: 0x39, pressed: false, extended: false)
        ])
    }

    func testCapsLockIsNotForwardedAndNoInputContextIsAttached() {
        let (view, session, reader, _, _, _) = makeFixture()
        // F1b is not implemented: inputContext remains nil.
        XCTAssertNil(view.inputContext)

        // Caps Lock short press flips Mac source in F0b, but Caps Lock scancode is never sent (K4 not done).
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        view.flagsChanged(with: flagsEvent(.capsLock, keyCode: 57))
        view.flagsChanged(with: flagsEvent([], keyCode: 57))

        XCTAssertEqual(waitForKeys(session, count: 4), hangulTap)
    }

    // MARK: I-F1 R4 & R6 right Option and 104 merging

    func testRightOptionTapFollowedByAsyncFlipWithinMergeWindowSendsOnce() {
        let (view, session, reader, clock, center, _) = makeFixture()
        view.flagsChanged(with: flagsEvent(flags(.option, device: deviceRightAlt), keyCode: 61))
        clock.advance(by: 0.050)
        view.flagsChanged(with: flagsEvent([], keyCode: 61))

        // 200 ms later (< 300 ms T_merge): Mac flips asynchronously -> merged (0 extra chord).
        clock.advance(by: 0.200)
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)

        // Right Option itself is the modifier E0 38, not a masked tap (out of G6's scope).
        XCTAssertEqual(waitForKeys(session, count: 4), [hangulDown, hangulUp])
    }

    func testAsyncFlipFollowedByRightOptionWithinMergeWindowSuppressesRightAlt() {
        let (view, session, reader, clock, center, _) = makeFixture()
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)

        // 100 ms later (< 300 ms T_merge): right Option pressed and released -> suppressed.
        clock.advance(by: 0.100)
        view.flagsChanged(with: flagsEvent(flags(.option, device: deviceRightAlt), keyCode: 61))
        clock.advance(by: 0.050)
        view.flagsChanged(with: flagsEvent([], keyCode: 61))

        XCTAssertEqual(waitForKeys(session, count: 4), hangulTap)
    }

    func testKey104MergesFollowingFlipAndSuppressesAfterFlip() {
        let (view, session, reader, clock, center, _) = makeFixture()
        // 104 tap followed by flip within 300 ms -> merged (1 chord total).
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104))
        clock.advance(by: 0.150)
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)

        XCTAssertEqual(waitForKeys(session, count: 4), hangulTap)

        // Wait past T_merge, flip back asynchronously, then press 104 within 300 ms -> 104 suppressed.
        session.clearKeys()
        clock.advance(by: 0.500)
        reader.language = .other
        reader.sourceID = "com.apple.keylayout.ABC"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
        clock.advance(by: 0.100)
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104))

        XCTAssertEqual(waitForKeys(session, count: 4), hangulTap)
    }

    // MARK: I-F9, I-F11, I-F3, I-F8, I-F13

    func testDisabledFollowSendsNothingAndKeepsInputContextNil() {
        let (view, session, reader, _, center, _) = makeFixture(profile: .korean, follow: false)
        XCTAssertNil(view.inputContext)

        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
        view.keyDown(with: keyEvent(.keyDown, keyCode: 15))

        XCTAssertEqual(waitForKeys(session, count: 1), [
            FollowKeySession.Key(code: 0x13, pressed: true, extended: false)
        ])
    }

    func testStandardProfileNeverSendsFollowToggle() {
        let (view, session, reader, _, center, _) = makeFixture(profile: .standard, follow: true)
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
        view.keyDown(with: keyEvent(.keyDown, keyCode: 15))

        XCTAssertEqual(waitForKeys(session, count: 1), [
            FollowKeySession.Key(code: 0x13, pressed: true, extended: false)
        ])
    }

    func testFocusLossClearsSuppressedSwitchKeysAndReleasesHostHeldInputs() {
        let (view, session, reader, clock, _, _) = makeFixture()

        // Suppress Space keyDown on switch, hold left Option + 'a', then lose focus.
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        view.keyDown(with: keyEvent(.keyDown, keyCode: 49, modifierFlags: [.control]))
        view.flagsChanged(with: flagsEvent(flags(.option, device: deviceLeftAlt), keyCode: 58))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 0))
        view.releaseHostInput()

        XCTAssertEqual(waitForKeys(session, count: 8), hangulTap + [
            FollowKeySession.Key(code: 0x38, pressed: true, extended: false),
            FollowKeySession.Key(code: 0x1E, pressed: true, extended: false),
            FollowKeySession.Key(code: 0x1E, pressed: false, extended: false),
            FollowKeySession.Key(code: 0x38, pressed: false, extended: false)
        ])

        // Refocus with language changed while unfocused: 0 toggles (I-F8), and Space keyUp is no longer swallowed.
        session.clearKeys()
        reader.language = .other
        reader.sourceID = "com.apple.keylayout.ABC"
        view.handleInputSourceFocusGained()
        clock.advance(by: RDPInputSourceFollower.defaultSettleInterval)
        view.handleInputSourceSettleElapsed()
        view.keyUp(with: keyEvent(.keyUp, keyCode: 49))

        XCTAssertEqual(waitForKeys(session, count: 1), [
            FollowKeySession.Key(code: 0x39, pressed: false, extended: false)
        ])
    }

    // MARK: Design G2-G4, G7 on the local view

    private let space = FollowKeySession.Key(code: 0x39, pressed: true, extended: false)
    private let spaceUp = FollowKeySession.Key(code: 0x39, pressed: false, extended: false)
    private let controlDown = FollowKeySession.Key(code: 0x1D, pressed: true, extended: false)
    private let controlUp = FollowKeySession.Key(code: 0x1D, pressed: false, extended: false)

    /// REPRO4: a key whose keyDown went out keeps its keyUp even when a later repeat looks like a
    /// switch hotkey with the source changed.
    func testForwardedKeyUpSurvivesALaterSwitchCandidateRepeat() {
        let (view, session, reader, _, _, _) = makeFixture()
        view.keyDown(with: keyEvent(.keyDown, keyCode: 49))
        view.flagsChanged(with: flagsEvent(.control, keyCode: 59))
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        view.keyDown(with: keyEvent(.keyDown, keyCode: 49, modifierFlags: [.control], isARepeat: true))
        view.keyUp(with: keyEvent(.keyUp, keyCode: 49, modifierFlags: [.control]))
        view.flagsChanged(with: flagsEvent([], keyCode: 59))

        // The follow tap waits for Control to go up (G7).
        XCTAssertEqual(waitForKeys(session, count: 9), [space, controlDown, space, spaceUp, controlUp] + hangulTap)
    }

    /// G2: with the source unchanged, Control+Space reaches the host with Control held.
    func testControlSpaceWithoutSourceChangeIsForwardedWithControl() {
        let (view, session, _, _, _, _) = makeFixture()
        view.flagsChanged(with: flagsEvent(.control, keyCode: 59))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 49, modifierFlags: [.control]))
        view.keyUp(with: keyEvent(.keyUp, keyCode: 49, modifierFlags: [.control]))
        XCTAssertEqual(waitForKeys(session, count: 3), [controlDown, space, spaceUp])
    }

    /// G3: the raw Hangul key stays a raw toggle until its keyUp, so a flip while it is still
    /// held merges with it.
    func testHeldHangulKeyMergesAFlipUntilItsKeyUp() {
        let (view, session, reader, clock, center, _) = makeFixture()
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104))
        clock.advance(by: 0.400)
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
        view.keyUp(with: keyEvent(.keyUp, keyCode: 104))
        XCTAssertEqual(waitForKeys(session, count: 8), hangulTap)
    }

    /// REPRO3: a 104 press R6 swallowed swallows its repeat and keyUp, and a later press taps.
    func testR6Suppressed104SwallowsItsRepeatAndKeyUp() {
        let (view, session, reader, clock, center, _) = makeFixture()
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
        clock.advance(by: 0.100)
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104, isARepeat: true))
        view.keyUp(with: keyEvent(.keyUp, keyCode: 104))
        clock.advance(by: 0.500)
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104))
        view.keyUp(with: keyEvent(.keyUp, keyCode: 104))
        XCTAssertEqual(waitForKeys(session, count: 8), hangulTap + hangulTap)
    }

    /// E3b: the Hangul key pressed with Control and Option held taps after both go up.
    func testHangulKeyWithControlAndOptionHeldTapsAfterRelease() {
        let (view, session, _, _, _, _) = makeFixture()
        view.flagsChanged(with: flagsEvent(.control, keyCode: 59))
        view.flagsChanged(with: flagsEvent(flags([.control, .option], device: deviceLeftAlt), keyCode: 58))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104, modifierFlags: [.control, .option]))
        let altDown = FollowKeySession.Key(code: 0x38, pressed: true, extended: false)
        let altUp = FollowKeySession.Key(code: 0x38, pressed: false, extended: false)
        XCTAssertEqual(waitForKeys(session, count: 3), [controlDown, altDown])
        view.flagsChanged(with: flagsEvent(.control, keyCode: 58))
        view.flagsChanged(with: flagsEvent([], keyCode: 59))
        XCTAssertEqual(waitForKeys(session, count: 8), [controlDown, altDown, altUp, controlUp] + hangulTap)
    }

    /// G4: follow armed while unconnected starts at the connected boundary, so a flip after the
    /// settle window sends one tap instead of being absorbed by a late arm.
    func testConnectedBoundaryArmsFollow() {
        let connection = RDPConnectionView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let view = connection.clientView
        let session = FollowKeySession(profile: .korean)
        session.isConnected = false
        let reader = FakeInputSourceReader(language: .other, sourceID: "com.apple.keylayout.ABC")
        let clock = FakeClock(100.0)
        let center = NotificationCenter()
        view.configureInputSourceFollowForTesting(
            reader: reader,
            observer: RDPMacInputSourceObserver(center: center),
            clock: { clock.now },
            isFocused: { true },
            switchHotkeys: []
        )
        view.session = session
        view.inputSourceFollow = true
        addTeardownBlock { [session] in
            connection.shutdown()
            _ = session
        }

        session.isConnected = true
        connection.rdpSession(session, didLog: "FreeRDP connected.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        clock.advance(by: 5)
        view.handleInputSourceSettleElapsed()
        reader.language = .korean
        reader.sourceID = "com.apple.inputmethod.Korean.2SetKorean"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
        XCTAssertEqual(waitForKeys(session, count: 4), hangulTap)

        // The disconnected boundary disarms: a flip after it sends nothing.
        session.clearKeys()
        session.isConnected = false
        connection.rdpSession(session, didLog: "FreeRDP disconnected.")
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        session.isConnected = true
        reader.language = .other
        reader.sourceID = "com.apple.keylayout.ABC"
        center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
        XCTAssertEqual(waitForKeys(session, count: 1), [])
    }
}
