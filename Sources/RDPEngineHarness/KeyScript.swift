import AppKit
import RDPClientCore
import RDPMacView

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
struct KeyScript {
    private static let keyCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21,
        "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "o": 31, "u": 32, "i": 34, "p": 35,
        "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, " ": 49, "\n": 36
    ]
    private static let namedKeys: [String: UInt16] = ["end": 119, "esc": 53, "f11": 103, "f12": 111]
    private static let leftControl: UInt = 0x1, rightControl: UInt = 0x2000
    private static let leftAlt: UInt = 0x20, rightAlt: UInt = 0x40

    let view: RDPConnectionView
    let window: NSWindow
    let shared: RDPSharedInputSession?
    private var flags: NSEvent.ModifierFlags = []

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
            case "optdown": setFlags([.option], device: Self.leftAlt, keyCode: 58); pause(0.1)
            case "optup": setFlags([], device: 0, keyCode: 58); pause(0.1)
            case "blur":
                NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
                pause(0.2)
            case "click":
                let xy = argument.split(separator: ",").compactMap { Int32($0) }
                guard xy.count == 2 else { unknown.append(token); continue }
                click(x: xy[0], y: xy[1])
                pause(0.3)
            case "end", "esc", "f11", "f12":
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

    private mutating func setFlags(_ modifiers: NSEvent.ModifierFlags, device: UInt, keyCode: UInt16) {
        flags = NSEvent.ModifierFlags(rawValue: modifiers.rawValue | device)
        if let shared {
            _ = shared.submit(.modifiers(RDPKeyboardMapper.modifierScancodes(for: flags)))
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
