import AppKit
import RDPClientCore
// The input-source follow test hook of RDPClientView is internal; the harness is built with
// `-Xswiftc -enable-testing` for the F3 runs (Harness/windows-ime/run-k5.sh).
@testable import RDPMacView

/// K5 (Korean input design V4): plays a space-separated key script as the Mac would deliver it.
/// `local` sends synthetic NSEvents into the real `RDPClientView`; `shared` sends what the app's
/// share host (`CNDFRDPInputBackend`) submits for the same viewer events through a share handle.
///
///   t:<keys>        type each key (a-z, 0-9, space, enter; down then up)
///   ropt rctl lopt  tap right Option / right Control / left Option alone (device bits set)
///   k104 k102       PC Han/Yeong / Hanja: down, one auto-repeat down, up
///   end esc f11 f12 tap that key
///   ctrl:<key>      left Control held around one key
///   hold:<key>:<ms> key down, auto-repeat every 33 ms for <ms>, then up
///   optdown optup   left Option down / up
///   blur            the window resigns key (local only)
///   click:<x>,<y>   left click at remote pixel x,y
///   wait:<ms>
///
/// F3 (Hangul follow design V-W) scripts the Mac input source with a fake reader; the real
/// macOS input source is never read or changed:
///   follow:<src>      input-source follow on, current source <src>. local: RDPClientView's test
///                     hook; shared: one RDPInputSourceFollower driven like the app's shared viewer
///                     (SharedRDPViewerView), whose vk 104 pair the share host turns into one chord
///   src:<src>         the source becomes <src>, then the change notification arrives
///   srcq:<src>        the source becomes <src> without a notification (the next key's pre-check sees it)
///   focus             follow focus regained; blur also drops it
///   ctrldown ctrlup   left Control down / up; optdown optup and these keep the other held modifiers
///   roptdown roptup   right Option down / up
///   kd:<key> ku:<key> key down / up with the held modifiers (_ is space)
///   f7 f8 f9          tap that key (f7 marks a row in the Windows probe log)
///   mask              shared only: the follow toggle becomes the masked chord [E0 38, 1D] (design H6
///                     candidate, sent through the same executor chord without changing the mapper)
/// <src>: ko (2-Set Korean), ko3 (3-Set Korean), en (ABC), us (U.S.)
struct KeyScript {
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49, "\n": 36
    ]
    private static let namedKeys: [String: UInt16] = [
        "end": 119, "esc": 53, "f11": 103, "f12": 111, "f7": 98, "f8": 100, "f9": 101
    ]
    private static let leftControl: UInt = 0x1, rightControl: UInt = 0x2000
    private static let leftAlt: UInt = 0x20, rightAlt: UInt = 0x40

    let view: RDPConnectionView
    let window: NSWindow
    let shared: RDPSharedInputSession?
    private var flags: NSEvent.ModifierFlags = []
    private let follow = ScriptedFollow()

    init(view: RDPConnectionView, window: NSWindow, shared: RDPSharedInputSession?) {
        self.view = view
        self.window = window
        self.shared = shared
    }

    /// Plays `script`; returns the tokens it could not play.
    mutating func play(_ script: String, pause: (TimeInterval) -> Void) -> [String] {
        var unknown: [String] = []
        for token in script.split(separator: " ").map(String.init) {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            let argument = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "t":
                for character in argument.replacingOccurrences(of: "_", with: " ") {
                    guard let code = Self.keyCodes[character] else { unknown.append(token); continue }
                    key(code, down: true)
                    pause(0.03)
                    key(code, down: false)
                    pause(0.05)
                }
            case "follow":
                guard ScriptedInputSource.sourceIDs[argument] != nil else { unknown.append(token); continue }
                startFollow(source: argument)
                pause(0.1)
            case "src", "srcq":
                guard ScriptedInputSource.sourceIDs[argument] != nil, follow.isOn else { unknown.append(token); continue }
                follow.source.current = argument
                if parts[0] == "src" { notifySourceChanged() }
                pause(0.02)
            case "mask":
                guard shared != nil else { unknown.append(token); continue }
                follow.maskedToggle = true
            case "focus":
                follow.focused = true
                if shared != nil {
                    sharedFocusGained()
                } else {
                    view.clientView.handleInputSourceFocusGained()
                }
                pause(0.1)
            case "ctrldown": press(.control, device: Self.leftControl, keyCode: 59); pause(0.05)
            case "ctrlup": release(.control, device: Self.leftControl, keyCode: 59); pause(0.05)
            case "roptdown": press(.option, device: Self.rightAlt, keyCode: 61); pause(0.05)
            case "roptup": release(.option, device: Self.rightAlt, keyCode: 61); pause(0.05)
            case "kd", "ku":
                guard let code = argument.replacingOccurrences(of: "_", with: " ").first.flatMap({ Self.keyCodes[$0] }) else {
                    unknown.append(token); continue
                }
                key(code, down: parts[0] == "kd")
                pause(0.03)
            case "ropt": tapModifier(.option, device: Self.rightAlt, keyCode: 61, pause: pause)
            case "rctl": tapModifier(.control, device: Self.rightControl, keyCode: 62, pause: pause)
            case "lopt": tapModifier(.option, device: Self.leftAlt, keyCode: 58, pause: pause)
            case "k104", "k102":
                let code: UInt16 = parts[0] == "k104" ? 104 : 102
                key(code, down: true)
                pause(0.05)
                key(code, down: true, isARepeat: true)
                pause(0.05)
                key(code, down: false)
                pause(0.1)
            case "ctrl":
                guard let code = argument.first.flatMap({ Self.keyCodes[$0] }) else { unknown.append(token); continue }
                setFlags([.control], device: Self.leftControl, keyCode: 59)
                pause(0.05)
                key(code, down: true)
                pause(0.03)
                key(code, down: false)
                pause(0.05)
                setFlags([], device: 0, keyCode: 59)
                pause(0.1)
            case "hold":
                let fields = argument.split(separator: ":")
                guard fields.count == 2, let code = fields[0].first.flatMap({ Self.keyCodes[$0] }),
                      let milliseconds = Double(fields[1]) else { unknown.append(token); continue }
                key(code, down: true)
                let end = Date().addingTimeInterval(milliseconds / 1000)
                pause(0.5)
                while Date() < end {
                    key(code, down: true, isARepeat: true)
                    pause(0.033)
                }
                key(code, down: false)
                pause(0.1)
            case "optdown": press(.option, device: Self.leftAlt, keyCode: 58); pause(0.1)
            case "optup": release(.option, device: Self.leftAlt, keyCode: 58); pause(0.1)
            case "blur":
                follow.focused = false
                if shared != nil {
                    follow.follower?.focusLost()
                } else {
                    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                }
                pause(0.2)
            case "click":
                let xy = argument.split(separator: ",").compactMap { Int32($0) }
                guard xy.count == 2 else { unknown.append(token); continue }
                click(x: xy[0], y: xy[1])
                pause(0.3)
            case "end", "esc", "f11", "f12", "f7", "f8", "f9":
                let code = Self.namedKeys[parts[0]]!
                key(code, down: true)
                pause(0.03)
                key(code, down: false)
                pause(0.2)
            case "wait":
                pause((Double(argument) ?? 100) / 1000)
            default:
                unknown.append(token)
            }
        }
        return unknown
    }

    private mutating func tapModifier(_ modifier: NSEvent.ModifierFlags, device: UInt, keyCode: UInt16,
                                      pause: (TimeInterval) -> Void) {
        setFlags(modifier, device: device, keyCode: keyCode)
        pause(0.08)
        setFlags([], device: 0, keyCode: keyCode)
        pause(0.3)
    }

    private mutating func press(_ modifier: NSEvent.ModifierFlags, device: UInt, keyCode: UInt16) {
        setFlags(flags.union(modifier), device: (flags.rawValue & Self.deviceBits) | device, keyCode: keyCode)
    }

    private mutating func release(_ modifier: NSEvent.ModifierFlags, device: UInt, keyCode: UInt16) {
        let remainingDevice = flags.rawValue & Self.deviceBits & ~device
        var remaining = flags.subtracting(modifier)
        // Keep the modifier when its other side is still held.
        if modifier == .option && remainingDevice & (Self.leftAlt | Self.rightAlt) != 0 { remaining.insert(.option) }
        if modifier == .control && remainingDevice & (Self.leftControl | Self.rightControl) != 0 { remaining.insert(.control) }
        setFlags(remaining.intersection(.deviceIndependentFlagsMask), device: remainingDevice, keyCode: keyCode)
    }

    private static let deviceBits: UInt = leftControl | rightControl | leftAlt | rightAlt

    private mutating func setFlags(_ modifiers: NSEvent.ModifierFlags, device: UInt, keyCode: UInt16) {
        let previous = flags
        flags = NSEvent.ModifierFlags(rawValue: modifiers.intersection(.deviceIndependentFlagsMask).rawValue | device)
        if let shared {
            sharedPreCheck()
            var scancodes = RDPKeyboardMapper.modifierScancodes(for: flags)
            if sharedRightOption(previous: previous) {
                scancodes.removeAll { $0 == RDPKeyboardMapper.rightAlt }
            }
            _ = shared.submit(.modifiers(scancodes))
            return
        }
        let event = CGEvent(source: nil)!
        event.type = .flagsChanged
        event.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(keyCode))
        view.clientView.flagsChanged(with: NSEvent(cgEvent: event)!)
    }

    private func key(_ code: UInt16, down: Bool, isARepeat: Bool = false) {
        if let shared {
            sharedPreCheck()
            // The share host's translation (CNDFRDPInputBackend.injectKey); the viewer forwards no
            // auto-repeat of the IME keys (RDPInputForwarder).
            let modifiers = RDPKeyboardMapper.modifierScancodes(for: flags)
            if RDPKeyboardMapper.isIMEToggleKey(code) {
                guard down, !isARepeat else { return }
                if let toggle = RDPKeyboardMapper.imeToggleScancode(forMacKeyCode: code, profile: shared.keyboardProfile) {
                    _ = shared.submit(.chord([toggle]))
                } else {
                    _ = shared.submit(.modifiers(modifiers))
                }
                return
            }
            guard let scancode = RDPKeyboardMapper.scancode(for: code) else { return }
            _ = shared.submit(.key(scanCode: scancode, pressed: down, modifiers: modifiers))
            return
        }
        let event = NSEvent.keyEvent(
            with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: isARepeat, keyCode: code
        )!
        if down {
            view.clientView.keyDown(with: event)
        } else {
            view.clientView.keyUp(with: event)
        }
    }

    // MARK: - Scripted input source (F3)

    private func startFollow(source: String) {
        follow.source.current = source
        follow.isOn = true
        follow.focused = true
        if shared != nil {
            follow.follower = RDPInputSourceFollower()
            sharedFocusGained()
            return
        }
        let state = follow
        view.clientView.configureInputSourceFollowForTesting(
            reader: state.source,
            observer: RDPMacInputSourceObserver(center: state.center),
            clock: { ProcessInfo.processInfo.systemUptime },
            isFocused: { state.focused },
            switchHotkeys: RDPSymbolicHotKeys.defaultSwitchHotkeys
        )
        view.clientView.inputSourceFollow = true
    }

    private func notifySourceChanged() {
        if shared != nil {
            sharedPreCheck()
        } else {
            follow.center.post(name: RDPMacInputSourceObserver.notificationName, object: nil)
        }
    }

    /// The shared viewer's focus gain: baseline now, settle timer (SharedRDPViewerView).
    private func sharedFocusGained() {
        let state = follow
        guard var follower = state.follower else { return }
        follower.focusGained(at: ProcessInfo.processInfo.systemUptime, language: state.source.currentLanguage())
        state.follower = follower
        DispatchQueue.main.asyncAfter(deadline: .now() + follower.settleInterval) {
            guard state.focused, state.follower?.isFocused == true else { return }
            state.follower?.settleElapsed(at: ProcessInfo.processInfo.systemUptime, language: state.source.currentLanguage())
        }
    }

    /// The shared viewer's pre-check: a flip becomes a vk 104 down/up pair, which the share host
    /// turns into one Han/Yeong chord for its own keyboard profile (CNDFRDPInputBackend).
    private func sharedPreCheck() {
        guard let shared, follow.focused, var follower = follow.follower else { return }
        let decision = follower.observe(follow.source.currentLanguage(), at: ProcessInfo.processInfo.systemUptime, cause: .async)
        follow.follower = follower
        guard decision.sendsToggle,
              let toggle = RDPKeyboardMapper.imeToggleScancode(forMacKeyCode: 104, profile: shared.keyboardProfile) else { return }
        // 0x1D: left Control, the mask key of the H6 candidate chord.
        _ = shared.submit(.chord(follow.maskedToggle ? [toggle, 0x1D] : [toggle]))
    }

    /// The shared viewer's right Option merge (R4) and suppression (R6); true while the right
    /// Alt scancode must be left out.
    private func sharedRightOption(previous: NSEvent.ModifierFlags) -> Bool {
        guard follow.focused, var follower = follow.follower else { return false }
        defer { follow.follower = follower }
        let now = ProcessInfo.processInfo.systemUptime
        let wasRightOptionOnly = RDPKeyboardMapper.isRightOptionOnly(previous)
        let isRightOptionOnly = RDPKeyboardMapper.isRightOptionOnly(flags)
        if !wasRightOptionOnly && isRightOptionOnly {
            if follower.shouldSuppressRawToggle(at: now) {
                follow.suppressingRightOption = true
            } else {
                follow.rightOptionActive = true
                follower.rawToggleBegan(at: now)
            }
        } else if !isRightOptionOnly {
            if follow.rightOptionActive {
                follow.rightOptionActive = false
                follower.rawToggleEnded(at: now)
            }
            if follow.suppressingRightOption && !flags.contains(.option) {
                follow.suppressingRightOption = false
                return true
            }
        }
        return follow.suppressingRightOption
    }

    private func click(x: Int32, y: Int32) {
        if let shared {
            let modifiers = RDPKeyboardMapper.modifierScancodes(for: flags)
            _ = shared.submit(.mouse(x: x, y: y, button: nil, flags: .move, modifiers: modifiers))
            _ = shared.submit(.mouse(x: x, y: y, button: .left, flags: .down, modifiers: modifiers))
            _ = shared.submit(.mouse(x: x, y: y, button: .left, flags: .up, modifiers: modifiers))
            return
        }
        view.injectMouse(x: x, y: y, button: nil, flags: .move)
        view.injectMouse(x: x, y: y, button: .left, flags: .down)
        view.injectMouse(x: x, y: y, button: .left, flags: .up)
    }
}

/// The scripted Mac input source (F3). Never touches the real TIS state.
final class ScriptedInputSource: RDPInputSourceReading {
    static let sourceIDs: [String: String] = [
        "ko": "com.apple.inputmethod.Korean.2SetKorean",
        "ko3": "com.apple.inputmethod.Korean.390Sebulshik",
        "en": "com.apple.keylayout.ABC",
        "us": "com.apple.keylayout.US"
    ]
    var current = "en"

    func currentLanguage() -> RDPInputLanguage { current.hasPrefix("ko") ? .korean : .other }
    func currentSourceID() -> String? { Self.sourceIDs[current] }
}

/// Follow state shared by the script and the closures it hands out.
final class ScriptedFollow {
    let source = ScriptedInputSource()
    let center = NotificationCenter()
    var isOn = false
    var focused = true
    var follower: RDPInputSourceFollower?
    var rightOptionActive = false
    var suppressingRightOption = false
    var maskedToggle = false
}
