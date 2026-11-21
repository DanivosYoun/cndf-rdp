import AppKit
import Carbon.HIToolbox
import Foundation

/// Read-only abstraction over macOS keyboard input-source state (design H2, I-F7).
/// Implementations must never call `TISSelectInputSource` or modify system settings.
public protocol RDPInputSourceReading: AnyObject {
    func currentLanguage() -> RDPInputLanguage
    func currentSourceID() -> String?
}

/// Reads the current macOS keyboard input source via Carbon TIS read-only APIs.
public final class RDPMacInputSourceReader: RDPInputSourceReading {
    public init() {}

    public func currentLanguage() -> RDPInputLanguage {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let rawLanguages = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) else {
            return .other
        }
        let languages = Unmanaged<CFArray>.fromOpaque(rawLanguages).takeUnretainedValue() as? [String] ?? []
        return Self.classifyLanguage(from: languages)
    }

    public func currentSourceID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
            return nil
        }
        return Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
    }

    /// Classifies a TIS language list: first element `ko` or `ko-*` is Korean; everything else is other.
    public static func classifyLanguage(from languages: [String]) -> RDPInputLanguage {
        guard let first = languages.first?.lowercased() else {
            return .other
        }
        if first == "ko" || first.hasPrefix("ko-") {
            return .korean
        }
        return .other
    }
}

/// Subscribes to `kTISNotifySelectedKeyboardInputSourceChanged` on the distributed notification center.
public final class RDPMacInputSourceObserver {
    public static let notificationName = NSNotification.Name(
        kTISNotifySelectedKeyboardInputSourceChanged as String
    )

    private let center: NotificationCenter
    private var token: NSObjectProtocol?

    public init(center: NotificationCenter = DistributedNotificationCenter.default()) {
        self.center = center
    }

    deinit {
        stop()
    }

    public func start(handler: @escaping () -> Void) {
        stop()
        token = center.addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: .main
        ) { _ in
            handler()
        }
    }

    public func stop() {
        if let token {
            center.removeObserver(token)
            self.token = nil
        }
    }
}

/// A macOS input-source switch shortcut (e.g. symbolic hotkeys 60 and 61).
public struct RDPSwitchHotkey: Equatable, Sendable {
    private static let relevantModifierMask: UInt = NSEvent.ModifierFlags([
        .shift, .control, .option, .command
    ]).rawValue

    public let keyCode: UInt16
    public let modifierRawValue: UInt

    public var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: modifierRawValue)
    }

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifierRawValue = modifiers.rawValue & Self.relevantModifierMask
    }

    public func matches(keyCode: UInt16, modifierFlags: NSEvent.ModifierFlags) -> Bool {
        self.keyCode == keyCode
            && (modifierFlags.rawValue & Self.relevantModifierMask) == modifierRawValue
    }
}

/// Read-only parser for macOS `com.apple.symbolichotkeys` entries 60 (previous) and 61 (next).
public enum RDPSymbolicHotKeys {
    /// Default macOS switch hotkeys: 60 = Control+Space, 61 = Control+Option+Space.
    public static let defaultPreviousHotkey = RDPSwitchHotkey(keyCode: 49, modifiers: [.control])
    public static let defaultNextHotkey = RDPSwitchHotkey(keyCode: 49, modifiers: [.control, .option])
    public static let defaultSwitchHotkeys: [RDPSwitchHotkey] = [
        defaultPreviousHotkey,
        defaultNextHotkey
    ]

    /// Reads enabled symbolic hotkeys 60 and 61 from user preferences without modifying anything.
    /// Falls back to Control+Space and Control+Option+Space when preferences cannot be read.
    public static func readEnabledSwitchHotkeys() -> [RDPSwitchHotkey] {
        let raw = CFPreferencesCopyAppValue(
            "AppleSymbolicHotKeys" as CFString,
            "com.apple.symbolichotkeys" as CFString
        )
        return parseEnabledSwitchHotkeys(from: raw)
    }

    public static func parseEnabledSwitchHotkeys(from raw: Any?) -> [RDPSwitchHotkey] {
        guard let root = raw as? [String: Any] else {
            return defaultSwitchHotkeys
        }
        let defaults: [(String, RDPSwitchHotkey)] = [
            ("60", defaultPreviousHotkey),
            ("61", defaultNextHotkey)
        ]
        var result: [RDPSwitchHotkey] = []
        for (key, fallback) in defaults {
            guard let entry = root[key] as? [String: Any] else {
                result.append(fallback)
                continue
            }
            if let enabled = parseBool(entry["enabled"]), !enabled {
                continue
            }
            if let parsed = parseHotkey(from: entry) {
                result.append(parsed)
            } else {
                result.append(fallback)
            }
        }
        return result
    }

    private static func parseBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        return nil
    }

    private static func parseHotkey(from entry: [String: Any]) -> RDPSwitchHotkey? {
        guard let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [Any],
              parameters.count >= 3,
              let keyCode = (parameters[1] as? NSNumber)?.intValue,
              let modifierMask = (parameters[2] as? NSNumber)?.uintValue,
              keyCode >= 0, keyCode < 0xFFFF else {
            return nil
        }
        return RDPSwitchHotkey(
            keyCode: UInt16(keyCode),
            modifiers: NSEvent.ModifierFlags(rawValue: modifierMask)
        )
    }
}
