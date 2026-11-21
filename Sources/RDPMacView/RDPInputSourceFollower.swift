import Foundation

/// Coarse language bucket for Mac input-source following (design H1, H2).
/// Transitions within the same bucket (e.g., 2-bulsik to 3-bulsik, ABC to US) never toggle Windows.
public enum RDPInputLanguage: String, Sendable, Equatable {
    case korean = "ko"
    case other = "other"
}

/// How an input-source observation reached the follower (design H2, H4).
public enum RDPInputSourceObservationCause: String, Sendable, Equatable {
    case async = "async"
    case switchKey = "switchKey"
}

/// Reason attached to a follower decision for diagnostics and one-line logging.
public enum RDPInputSourceFollowReason: String, Sendable, Equatable {
    case unfocused
    case settling
    case unchanged
    case mergedWithRawToggle
    case languageFlipped
}

/// Outcome of `RDPInputSourceFollower.observe(_:at:cause:)`.
public enum RDPInputSourceFollowDecision: Sendable, Equatable {
    case none(RDPInputSourceFollowReason)
    case sendToggle(RDPInputSourceFollowReason)

    public var reason: RDPInputSourceFollowReason {
        switch self {
        case .none(let reason), .sendToggle(let reason):
            return reason
        }
    }

    public var sendsToggle: Bool {
        if case .sendToggle = self {
            return true
        }
        return false
    }

    public var sentLogValue: String {
        sendsToggle ? "toggle" : "none"
    }
}

/// Pure state machine for Mac-to-Windows Korean/English input-source following (design H4, R1–R6).
///
/// The follower never estimates or stores Windows IME state (H1, I-F8). It only emits a toggle
/// when the Mac language bucket flips while focused, outside the post-focus settle window, and
/// not already accounted for by a raw Hangul toggle key.
public struct RDPInputSourceFollower: Sendable {
    /// Post-focus settle window confirmed by F0b measurement (observed max 292 ms * 2, rounded to 600 ms).
    public static let defaultSettleInterval: TimeInterval = 0.600
    /// Merge/suppression window between raw toggle keys and async flips confirmed by F0b (300 ms).
    public static let defaultMergeInterval: TimeInterval = 0.300

    public let settleInterval: TimeInterval
    public let mergeInterval: TimeInterval

    public private(set) var isFocused: Bool = false
    public private(set) var baseline: RDPInputLanguage?

    private var settleUntil: TimeInterval?
    private var rawToggleActive: Bool = false
    private var rawToggleMergeUntil: TimeInterval?
    private var rawToggleMerged: Bool = false
    private var lastAsyncToggleAt: TimeInterval?

    public init(
        settleInterval: TimeInterval = RDPInputSourceFollower.defaultSettleInterval,
        mergeInterval: TimeInterval = RDPInputSourceFollower.defaultMergeInterval
    ) {
        self.settleInterval = settleInterval
        self.mergeInterval = mergeInterval
    }

    /// R1 & R2: Establish a fresh baseline on focus gain and open the settle window. Sends nothing.
    public mutating func focusGained(at now: TimeInterval, language: RDPInputLanguage) {
        isFocused = true
        baseline = language
        settleUntil = now + settleInterval
        rawToggleActive = false
        rawToggleMergeUntil = nil
        rawToggleMerged = false
        lastAsyncToggleAt = nil
    }

    /// R1: Drop focus and clear baseline and transient merge windows.
    public mutating func focusLost() {
        isFocused = false
        baseline = nil
        settleUntil = nil
        rawToggleActive = false
        rawToggleMergeUntil = nil
        rawToggleMerged = false
        lastAsyncToggleAt = nil
    }

    /// R2: Re-baseline once at the end of `T_settle` so late focus-induced changes do not toggle.
    public mutating func settleElapsed(at now: TimeInterval, language: RDPInputLanguage) {
        guard isFocused, settleUntil != nil else {
            return
        }
        baseline = language
        settleUntil = nil
    }

    /// R4: Record the press of a raw Hangul toggle key (right Option alone or PC Han/Yeong 104).
    public mutating func rawToggleBegan(at now: TimeInterval) {
        guard isFocused else { return }
        rawToggleActive = true
        rawToggleMergeUntil = nil
        rawToggleMerged = false
    }

    /// R4: Record the release of a raw Hangul toggle key and open the post-release merge window.
    public mutating func rawToggleEnded(at now: TimeInterval) {
        guard isFocused else { return }
        rawToggleActive = false
        rawToggleMergeUntil = now + mergeInterval
    }

    /// R6: True when a raw Hangul toggle key pressed at `now` should be suppressed because an
    /// asynchronous follow toggle was just sent within `T_merge`.
    public func shouldSuppressRawToggle(at now: TimeInterval) -> Bool {
        guard isFocused, let lastAsyncToggleAt else {
            return false
        }
        return now >= lastAsyncToggleAt && now < lastAsyncToggleAt + mergeInterval
    }

    /// Evaluate the current Mac language bucket under rules R1–R6.
    public mutating func observe(
        _ language: RDPInputLanguage,
        at now: TimeInterval,
        cause: RDPInputSourceObservationCause
    ) -> RDPInputSourceFollowDecision {
        // R1: Focused check.
        guard isFocused, let currentBaseline = baseline else {
            return .none(.unfocused)
        }

        // R2: Settle window absorbs async observations; sync switch-key observations bypass it.
        if let deadline = settleUntil {
            if now < deadline {
                if cause == .async {
                    baseline = language
                    return .none(.settling)
                }
            } else {
                settleUntil = nil
            }
        }

        // R3: Same language classification never sends a toggle and does not consume R4's merge slot.
        if language == currentBaseline {
            return .none(.unchanged)
        }

        // R4: First async flip while a raw toggle is active or within T_merge after its release.
        if cause == .async && !rawToggleMerged {
            let inRawWindow = rawToggleActive || (rawToggleMergeUntil.map { now < $0 } ?? false)
            if inRawWindow {
                baseline = language
                rawToggleMerged = true
                return .none(.mergedWithRawToggle)
            }
        }

        // R5: Flip detected; emit one toggle and update baseline.
        baseline = language
        if cause == .async {
            lastAsyncToggleAt = now
        }
        return .sendToggle(.languageFlipped)
    }
}
