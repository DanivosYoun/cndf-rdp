import AppKit
import RDPClientCore

public enum RDPKeyboardMapper {
    public static let extended: UInt16 = 0x0100

    public static let leftShift: UInt16 = 0x2A
    public static let leftControl: UInt16 = 0x1D
    public static let leftAlt: UInt16 = 0x38
    public static let leftWindows: UInt16 = extended | 0x5B
    public static let rightControl: UInt16 = extended | 0x1D
    public static let rightAlt: UInt16 = extended | 0x38

    // Device-dependent modifier bits of `NSEvent.ModifierFlags.rawValue` (IOLLEvent.h).
    private static let deviceLeftControl: UInt = 0x0000_0001
    private static let deviceRightControl: UInt = 0x0000_2000
    private static let deviceLeftAlt: UInt = 0x0000_0020
    private static let deviceRightAlt: UInt = 0x0000_0040

    /// A Korean IME key the server's keyboard driver turns into VK_HANGUL or VK_HANJA.
    public enum IMEToggle: Sendable {
        case hangul
        case hanja
    }

    /// Mac key codes sent as an IME key tap instead of a scancode (design D3). This is the one
    /// table of switch keys: a row added here becomes a tap on every profile that has IME keys.
    private static let imeToggleKeyCodes: [UInt16: IMEToggle] = [
        104: .hangul, // PC Korean keyboard Han/Yeong
        102: .hanja   // PC Korean keyboard Hanja
    ]

    private static let keyMap: [UInt16: UInt16] = [
        0: 0x1E, 1: 0x1F, 2: 0x20, 3: 0x21, 4: 0x23, 5: 0x22, 6: 0x2C, 7: 0x2D,
        8: 0x2E, 9: 0x2F, 11: 0x30, 12: 0x10, 13: 0x11, 14: 0x12, 15: 0x13,
        16: 0x15, 17: 0x14, 18: 0x02, 19: 0x03, 20: 0x04, 21: 0x05, 22: 0x07,
        23: 0x06, 24: 0x0D, 25: 0x0A, 26: 0x08, 27: 0x0C, 28: 0x09, 29: 0x0B,
        30: 0x1B, 31: 0x18, 32: 0x16, 33: 0x1A, 34: 0x17, 35: 0x19, 36: 0x1C,
        37: 0x26, 38: 0x24, 39: 0x28, 40: 0x25, 41: 0x27, 42: 0x2B, 43: 0x33,
        44: 0x35, 45: 0x31, 46: 0x32, 47: 0x34, 48: 0x0F, 49: 0x39, 50: 0x29,
        51: 0x0E, 53: 0x01, 65: 0x53, 67: 0x37, 69: 0x4E, 71: 0x45, 75: 0x35,
        76: extended | 0x1C, 78: 0x4A, 81: 0x0D, 82: 0x52, 83: 0x4F, 84: 0x50,
        85: 0x51, 86: 0x4B, 87: 0x4C, 88: 0x4D, 89: 0x47, 91: 0x48, 92: 0x49,
        96: 0x3F, 97: 0x40, 98: 0x41, 99: 0x3D, 100: 0x42, 101: 0x43, 103: 0x57,
        109: 0x44, 111: 0x58, 115: extended | 0x47, 116: extended | 0x49,
        117: extended | 0x53, 118: 0x3E, 119: extended | 0x4F, 120: 0x3C,
        121: extended | 0x51, 122: 0x3B, 123: extended | 0x4B, 124: extended | 0x4D,
        125: extended | 0x50, 126: extended | 0x48
    ]

    private static let commandShortcutMap: [UInt16: UInt16] = [
        0: 0x1E, 6: 0x2C, 7: 0x2D, 8: 0x2E, 9: 0x2F
    ]

    public static func scancode(for macKeyCode: UInt16) -> UInt16? {
        keyMap[macKeyCode]
    }

    public static func commandShortcutScancode(for macKeyCode: UInt16) -> UInt16? {
        commandShortcutMap[macKeyCode]
    }

    /// The Han/Yeong and Hanja scancodes of `profile`, or nil when it has none. The only place
    /// that picks them, so a different Korean keyboard subtype changes this function alone.
    public static func imeToggleScancodes(for profile: RDPKeyboardProfile) -> (hangul: UInt16, hanja: UInt16)? {
        switch profile {
        case .standard: return nil
        case .korean: return (rightAlt, rightControl)
        }
    }

    /// True for the Mac key codes in the IME switch-key table, whatever the profile. Their
    /// auto-repeat is never sent (design I11).
    public static func isIMEToggleKey(_ macKeyCode: UInt16) -> Bool {
        imeToggleKeyCodes[macKeyCode] != nil
    }

    /// The scancode to tap for `macKeyCode` on `profile`, or nil when it is not an IME key there.
    public static func imeToggleScancode(forMacKeyCode macKeyCode: UInt16, profile: RDPKeyboardProfile) -> UInt16? {
        guard let toggle = imeToggleKeyCodes[macKeyCode], let scancodes = imeToggleScancodes(for: profile) else {
            return nil
        }
        switch toggle {
        case .hangul: return scancodes.hangul
        case .hanja: return scancodes.hanja
        }
    }

    /// True when Option is held by the right key alone. Flags without device bits, as in a
    /// synthetic event, count as the left key.
    public static func isRightOptionOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option) && rightOnly(flags, right: deviceRightAlt, left: deviceLeftAlt)
    }

    /// True when Control is held by the right key alone, by the same rule as Option.
    public static func isRightControlOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.control) && rightOnly(flags, right: deviceRightControl, left: deviceLeftControl)
    }

    /// The held Shift, Control and Option as scancodes, in that order. Control and Option use the
    /// right-hand scancode only when the right key alone is down (design D3).
    public static func modifierScancodes(for flags: NSEvent.ModifierFlags) -> [UInt16] {
        var scancodes: [UInt16] = []
        if flags.contains(.shift) {
            scancodes.append(leftShift)
        }
        if flags.contains(.control) {
            scancodes.append(isRightControlOnly(flags) ? rightControl : leftControl)
        }
        if flags.contains(.option) {
            scancodes.append(isRightOptionOnly(flags) ? rightAlt : leftAlt)
        }
        return scancodes
    }

    private static func rightOnly(_ flags: NSEvent.ModifierFlags, right: UInt, left: UInt) -> Bool {
        flags.rawValue & right != 0 && flags.rawValue & left == 0
    }
}
