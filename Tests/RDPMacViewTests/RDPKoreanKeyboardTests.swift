import AppKit
import CoreGraphics
import RDPClientCore
import XCTest
@testable import RDPMacView

/// Records what `RDPClientView` sends through its executor; every input connection is current.
private final class KeySession: RDPEngineSession {
    struct Key: Equatable {
        let code: UInt16
        let pressed: Bool
        let extended: Bool
    }

    private let lock = NSLock()
    private var recorded: [Key] = []
    var keyboardProfile: RDPKeyboardProfile

    init(profile: RDPKeyboardProfile) {
        keyboardProfile = profile
    }

    var keys: [Key] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    let engine = RDPEngineKind.freeRDP
    weak var delegate: RDPSessionDelegate?
    var isConnected: Bool { true }
    var connectionGeneration: UInt64 { 1 }
    func isInputConnectionCurrent(generation: UInt64) -> Bool { true }
    func withInputConnection(generation: UInt64, _ body: () throws -> Void) throws { try body() }
    var statistics: RDPConnectionStatistics { fatalError("not used by the key path") }
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

private let deviceLeftControl: UInt = 0x1
private let deviceRightControl: UInt = 0x2000
private let deviceLeftAlt: UInt = 0x20
private let deviceRightAlt: UInt = 0x40

private func flags(_ base: NSEvent.ModifierFlags, device: UInt = 0) -> NSEvent.ModifierFlags {
    NSEvent.ModifierFlags(rawValue: base.rawValue | device)
}

private func keyEvent(_ type: NSEvent.EventType, keyCode: UInt16, isARepeat: Bool = false) -> NSEvent {
    NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                     characters: "", charactersIgnoringModifiers: "", isARepeat: isARepeat, keyCode: keyCode)!
}

private func flagsEvent(_ modifierFlags: NSEvent.ModifierFlags, keyCode: UInt16) -> NSEvent {
    let event = CGEvent(source: nil)!
    event.type = .flagsChanged
    event.flags = CGEventFlags(rawValue: UInt64(modifierFlags.rawValue))
    event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
    return NSEvent(cgEvent: event)!
}

@MainActor
final class RDPKoreanKeyboardTests: XCTestCase {
    // MARK: Mapper table

    func testIMEToggleScancodesPerProfile() {
        XCTAssertNil(RDPKeyboardMapper.imeToggleScancodes(for: .standard))
        let korean = RDPKeyboardMapper.imeToggleScancodes(for: .korean)
        XCTAssertEqual(korean?.hangul, 0x138)
        XCTAssertEqual(korean?.hanja, 0x11D)

        XCTAssertEqual(RDPKeyboardMapper.imeToggleScancode(forMacKeyCode: 104, profile: .korean), 0x138)
        XCTAssertEqual(RDPKeyboardMapper.imeToggleScancode(forMacKeyCode: 102, profile: .korean), 0x11D)
        XCTAssertNil(RDPKeyboardMapper.imeToggleScancode(forMacKeyCode: 104, profile: .standard))
        XCTAssertNil(RDPKeyboardMapper.imeToggleScancode(forMacKeyCode: 102, profile: .standard))
        XCTAssertNil(RDPKeyboardMapper.imeToggleScancode(forMacKeyCode: 0, profile: .korean))
        XCTAssertTrue(RDPKeyboardMapper.isIMEToggleKey(104))
        XCTAssertTrue(RDPKeyboardMapper.isIMEToggleKey(102))
        XCTAssertFalse(RDPKeyboardMapper.isIMEToggleKey(0))
        // The plain key table is unchanged: 104/102 still have no scancode of their own.
        XCTAssertNil(RDPKeyboardMapper.scancode(for: 104))
        XCTAssertNil(RDPKeyboardMapper.scancode(for: 102))
        XCTAssertEqual(RDPKeyboardMapper.scancode(for: 0), 0x1E)
    }

    func testModifierScancodesSplitOnlyRightOnlyOptionAndControl() {
        let rows: [(NSEvent.ModifierFlags, [UInt16])] = [
            ([], []),
            (.shift, [0x2A]),
            (.option, [0x38]),
            (flags(.option, device: deviceLeftAlt), [0x38]),
            (flags(.option, device: deviceRightAlt), [0x138]),
            (flags(.option, device: deviceLeftAlt | deviceRightAlt), [0x38]),
            (.control, [0x1D]),
            (flags(.control, device: deviceLeftControl), [0x1D]),
            (flags(.control, device: deviceRightControl), [0x11D]),
            (flags(.control, device: deviceLeftControl | deviceRightControl), [0x1D]),
            (flags([.shift, .control, .option], device: deviceRightControl | deviceRightAlt), [0x2A, 0x11D, 0x138]),
            // A stale device bit without the modifier itself sends nothing.
            (flags([], device: deviceRightAlt | deviceRightControl), []),
            (.command, [])
        ]
        for (modifierFlags, expected) in rows {
            XCTAssertEqual(RDPKeyboardMapper.modifierScancodes(for: modifierFlags), expected, "flags 0x\(String(modifierFlags.rawValue, radix: 16))")
        }
    }

    // MARK: Local view

    func testRightOptionFlagsEventSendsExtendedAlt() {
        let (view, session) = makeView(profile: .standard)
        view.flagsChanged(with: flagsEvent(flags(.option, device: deviceRightAlt), keyCode: 61))
        view.flagsChanged(with: flagsEvent([], keyCode: 61))
        XCTAssertEqual(waitForKeys(session, count: 2), [
            KeySession.Key(code: 0x38, pressed: true, extended: true),
            KeySession.Key(code: 0x38, pressed: false, extended: true)
        ])
    }

    func testLeftOptionFlagsEventStaysPlainAlt() {
        let (view, session) = makeView(profile: .korean)
        view.flagsChanged(with: flagsEvent(flags(.option, device: deviceLeftAlt), keyCode: 58))
        XCTAssertEqual(waitForKeys(session, count: 1), [KeySession.Key(code: 0x38, pressed: true, extended: false)])
    }

    func testKoreanHangulKeyTapsOnceAndIgnoresRepeatAndKeyUp() {
        let (view, session) = makeView(profile: .korean)
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104, isARepeat: true))
        view.keyUp(with: keyEvent(.keyUp, keyCode: 104))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 102))
        view.keyUp(with: keyEvent(.keyUp, keyCode: 102))
        XCTAssertEqual(waitForKeys(session, count: 4), [
            KeySession.Key(code: 0x38, pressed: true, extended: true),
            KeySession.Key(code: 0x38, pressed: false, extended: true),
            KeySession.Key(code: 0x1D, pressed: true, extended: true),
            KeySession.Key(code: 0x1D, pressed: false, extended: true)
        ])
    }

    func testStandardProfileDropsHangulAndHanjaKeys() {
        let (view, session) = makeView(profile: .standard)
        view.keyDown(with: keyEvent(.keyDown, keyCode: 104))
        view.keyUp(with: keyEvent(.keyUp, keyCode: 104))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 102))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 0))
        XCTAssertEqual(waitForKeys(session, count: 1), [KeySession.Key(code: 0x1E, pressed: true, extended: false)])
    }

    func testFocusLossReleasesHeldKeysThenModifiers() {
        let (view, session) = makeView(profile: .korean)
        view.flagsChanged(with: flagsEvent(flags(.option, device: deviceLeftAlt), keyCode: 58))
        view.keyDown(with: keyEvent(.keyDown, keyCode: 0))
        view.releaseHostInput()
        XCTAssertEqual(waitForKeys(session, count: 4), [
            KeySession.Key(code: 0x38, pressed: true, extended: false),
            KeySession.Key(code: 0x1E, pressed: true, extended: false),
            KeySession.Key(code: 0x1E, pressed: false, extended: false),
            KeySession.Key(code: 0x38, pressed: false, extended: false)
        ])
        // Nothing is left to release a second time.
        view.releaseHostInput()
        view.keyDown(with: keyEvent(.keyDown, keyCode: 1))
        XCTAssertEqual(waitForKeys(session, count: 5).last, KeySession.Key(code: 0x1F, pressed: true, extended: false))
    }

    private func makeView(profile: RDPKeyboardProfile) -> (RDPClientView, KeySession) {
        let session = KeySession(profile: profile)
        let view = RDPClientView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        view.session = session
        addTeardownBlock { [session] in _ = session }
        return (view, session)
    }

    private func waitForKeys(_ session: KeySession, count: Int) -> [KeySession.Key] {
        let deadline = Date().addingTimeInterval(2)
        while session.keys.count < count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        // Let anything unexpected arrive before comparing.
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        return session.keys
    }
}
