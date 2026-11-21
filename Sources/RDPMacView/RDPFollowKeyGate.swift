import AppKit

/// The key rules of input-source follow, shared by the local RDP view and the shared viewer
/// (design G1–G3, I-G2, I-G4, I-G5). Pure: it reads no input source, sends nothing and owns no
/// timer. Callers pass in what they observed and act on what it returns.
///
/// Its state is tied to the physical keys, not to what the remote side holds: the record of
/// what was actually sent belongs to the sender.
public struct RDPFollowKeyGate: Sendable {
    /// The fate of one press, fixed at its first non-repeat keyDown and kept until its keyUp.
    public enum Fate: Sendable, Equatable {
        case forwarded
        case suppressed
    }

    public enum KeyDownAction: Sendable, Equatable {
        /// Send the key as usual.
        case forward
        /// Send one IME tap (`RDPInputExecutor.imeTap`) instead of the key.
        case imeTap(RDPKeyboardMapper.IMEToggle)
        /// Send nothing.
        case drop
    }

    public enum KeyUpAction: Sendable, Equatable {
        case forward
        case drop
    }

    private enum RightCommand: Sendable, Equatable {
        case none
        /// Right Command alone is down and not yet sent.
        case held(down: NSEvent.ModifierFlags)
        /// Right Command was tapped alone; the tap is sent at `deadline` unless a flip merges it.
        case awaitingMerge(down: NSEvent.ModifierFlags, up: NSEvent.ModifierFlags, deadline: TimeInterval)
        /// A follow toggle took the place of the held right Command; it is never sent.
        case consumed
    }

    /// Whether a lone right Command is held back until `T_merge` passes (viewer only).
    public let holdsRightCommand: Bool
    public let mergeInterval: TimeInterval

    private var fates: [UInt16: Fate] = [:]
    private var rawToggleKeys: Set<UInt16> = []
    private var lastSourceID: String?
    private var lastFlags: NSEvent.ModifierFlags = []
    private var isRawRightOptionActive = false
    private var isSuppressingRightOption = false
    private var rightCommand: RightCommand = .none

    public init(
        holdsRightCommand: Bool = false,
        mergeInterval: TimeInterval = RDPInputSourceFollower.defaultMergeInterval
    ) {
        self.holdsRightCommand = holdsRightCommand
        self.mergeInterval = mergeInterval
    }

    // MARK: Source tracking

    /// Takes `id` as the source seen now, without reporting a change (focus gain, settle).
    public mutating func resetSource(to id: String?) {
        lastSourceID = id
    }

    /// True when the source changed since the last observation (design G2). Without an ID on
    /// either side the language bucket is compared with `baseline`.
    public mutating func sourceChanged(id: String?, language: RDPInputLanguage, baseline: RDPInputLanguage?) -> Bool {
        let changed: Bool
        if let id, let previous = lastSourceID {
            changed = id != previous
        } else {
            changed = language != baseline
        }
        lastSourceID = id
        return changed
    }

    // MARK: Keys

    /// The fate of the press `keyCode` is in, or nil when none is open.
    public func fate(of keyCode: UInt16) -> Fate? {
        fates[keyCode]
    }

    /// Decides a keyDown. `isSwitchCandidate` is whether it matches an enabled switch hotkey;
    /// it only matters together with `sourceChanged` (I-G5). `followActive` is true when follow
    /// is eligible and the follower is focused.
    public mutating func keyDown(
        keyCode: UInt16,
        isRepeat: Bool,
        sourceChanged: Bool,
        isSwitchCandidate: Bool,
        followActive: Bool,
        follower: inout RDPInputSourceFollower,
        now: TimeInterval
    ) -> KeyDownAction {
        let toggle = RDPKeyboardMapper.imeToggle(forMacKeyCode: keyCode)
        if isRepeat {
            // A repeat follows the fate of its press; an IME key's repeat never goes out (I-G4).
            if toggle != nil {
                return .drop
            }
            if let fate = fates[keyCode] {
                return fate == .forwarded ? .forward : .drop
            }
        }
        if rawToggleKeys.remove(keyCode) != nil {
            follower.rawToggleEnded(at: now)
        }
        if sourceChanged && isSwitchCandidate {
            fates[keyCode] = .suppressed
            return .drop
        }
        guard let toggle else {
            fates[keyCode] = .forwarded
            return .forward
        }
        if toggle == .hangul && followActive {
            if follower.shouldSuppressRawToggle(at: now) {
                fates[keyCode] = .suppressed
                return .drop
            }
            follower.rawToggleBegan(at: now)
            rawToggleKeys.insert(keyCode)
        }
        fates[keyCode] = .forwarded
        return .imeTap(toggle)
    }

    /// Ends the press. A forwarded key's keyUp always goes out; an IME key's never does.
    public mutating func keyUp(keyCode: UInt16, follower: inout RDPInputSourceFollower, now: TimeInterval) -> KeyUpAction {
        let fate = fates.removeValue(forKey: keyCode)
        if rawToggleKeys.remove(keyCode) != nil {
            follower.rawToggleEnded(at: now)
        }
        if fate == .suppressed || RDPKeyboardMapper.imeToggle(forMacKeyCode: keyCode) != nil {
            return .drop
        }
        return .forward
    }

    // MARK: Modifiers

    /// Takes the physical flags of a flagsChanged event and returns the modifier frames to send,
    /// in order; each is already passed through `outbound`. Empty when nothing goes out now.
    public mutating func modifiersChanged(
        _ flags: NSEvent.ModifierFlags,
        followActive: Bool,
        follower: inout RDPInputSourceFollower,
        now: TimeInterval
    ) -> [NSEvent.ModifierFlags] {
        let previous = lastFlags
        lastFlags = flags
        if followActive {
            if RDPKeyboardMapper.isRightOptionOnly(flags) {
                if !isRawRightOptionActive && !isSuppressingRightOption {
                    if follower.shouldSuppressRawToggle(at: now) {
                        isSuppressingRightOption = true
                    } else {
                        isRawRightOptionActive = true
                        follower.rawToggleBegan(at: now)
                    }
                }
            } else {
                if isRawRightOptionActive {
                    isRawRightOptionActive = false
                    follower.rawToggleEnded(at: now)
                }
                isSuppressingRightOption = false
            }
        }

        var frames: [NSEvent.ModifierFlags] = []
        if holdsRightCommand {
            let startsHold = Self.isRightCommandOnly(flags) && !previous.contains(.command)
            switch rightCommand {
            case .none:
                if startsHold && followActive {
                    rightCommand = .held(down: flags)
                    return []
                }
            case let .held(down):
                if !flags.contains(.command) && flags.intersection([.shift, .control, .option]).isEmpty {
                    rightCommand = .awaitingMerge(down: down, up: flags, deadline: now + mergeInterval)
                    return []
                }
                rightCommand = .none
                frames.append(outbound(down))
            case let .awaitingMerge(down, up, _):
                rightCommand = .none
                frames.append(outbound(down))
                frames.append(outbound(up))
                if startsHold && followActive {
                    rightCommand = .held(down: flags)
                    return frames
                }
            case .consumed:
                if !flags.contains(.command) {
                    rightCommand = .none
                }
            }
        }
        frames.append(outbound(flags))
        return frames
    }

    /// The modifiers to put on any outgoing frame for the physical `flags` (I-G2): drops a
    /// suppressed right Option and a held or consumed right Command.
    public func outbound(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var raw = flags.rawValue
        if isSuppressingRightOption && RDPKeyboardMapper.isRightOptionOnly(flags) {
            raw &= ~(NSEvent.ModifierFlags.option.rawValue | Self.deviceRightAlt)
        }
        switch rightCommand {
        case .held, .consumed:
            raw &= ~(NSEvent.ModifierFlags.command.rawValue | Self.deviceLeftCommand | Self.deviceRightCommand)
        case .none, .awaitingMerge:
            break
        }
        return NSEvent.ModifierFlags(rawValue: raw)
    }

    /// When a held right Command tap is due to go out, or nil.
    public var rightCommandDeadline: TimeInterval? {
        if case let .awaitingMerge(_, _, deadline) = rightCommand {
            return deadline
        }
        return nil
    }

    /// Sends a held right Command before other input goes out; returns its frames, in order.
    public mutating func flushForOtherInput() -> [NSEvent.ModifierFlags] {
        switch rightCommand {
        case let .held(down):
            rightCommand = .none
            return [outbound(down)]
        case let .awaitingMerge(down, up, _):
            rightCommand = .none
            return [outbound(down), outbound(up)]
        case .none, .consumed:
            return []
        }
    }

    /// The held right Command tap once its deadline has passed.
    public mutating func flushIfExpired(at now: TimeInterval) -> [NSEvent.ModifierFlags] {
        guard case let .awaitingMerge(_, _, deadline) = rightCommand, now >= deadline else {
            return []
        }
        return flushForOtherInput()
    }

    /// A follow toggle went out: a pending right Command is never sent, and while it is still
    /// held it stays off every frame.
    public mutating func followToggleSent() {
        switch rightCommand {
        case .held:
            rightCommand = .consumed
        case .awaitingMerge:
            rightCommand = .none
        case .none, .consumed:
            break
        }
    }

    /// Forgets every press and latch (focus loss). The physical flags are forgotten too.
    public mutating func reset() {
        fates.removeAll()
        rawToggleKeys.removeAll()
        lastSourceID = nil
        lastFlags = []
        isRawRightOptionActive = false
        isSuppressingRightOption = false
        rightCommand = .none
    }

    // Device-dependent bits of `NSEvent.ModifierFlags.rawValue` (IOLLEvent.h).
    private static let deviceLeftCommand: UInt = 0x08
    private static let deviceRightCommand: UInt = 0x10
    private static let deviceRightAlt: UInt = 0x40

    private static func isRightCommandOnly(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command) && flags.rawValue & deviceRightCommand != 0 && flags.rawValue & deviceLeftCommand == 0
    }
}
