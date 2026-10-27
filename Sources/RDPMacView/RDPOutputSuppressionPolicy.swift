import Foundation

/// Decides when a hidden RDP window may ask the server to stop sending display updates.
/// Suppresses only while the feature is on, the session is connected, the window is not
/// visible (occluded, minimized, on another Space, screen locked) and no frame tap is
/// attached. Hiding is debounced; anything else releases immediately.
public struct RDPOutputSuppressionPolicy: Equatable {
    public static let hideDebounce: TimeInterval = 1.0

    public struct Inputs: Equatable {
        public var supported: Bool
        public var enabled: Bool
        public var connected: Bool
        public var visible: Bool
        public var frameTapAttached: Bool

        public init(enabled: Bool, supported: Bool = true, connected: Bool, visible: Bool, frameTapAttached: Bool) {
            self.enabled = enabled
            self.supported = supported
            self.connected = connected
            self.visible = visible
            self.frameTapAttached = frameTapAttached
        }

        var wantsSuppression: Bool {
            supported && enabled && connected && !visible && !frameTapAttached
        }
    }

    public enum Decision: Equatable {
        case none
        case suppress
        case release
        /// Evaluate again after this many seconds to finish the hide debounce.
        case recheck(after: TimeInterval)
    }

    public private(set) var isSuppressed = false
    private var hiddenSince: TimeInterval?

    public init() {}

    public mutating func evaluate(_ inputs: Inputs, now: TimeInterval) -> Decision {
        guard inputs.connected else {
            // Nothing to release on a dead connection; the next one starts unsuppressed.
            connectionDidReset()
            return .none
        }
        guard inputs.wantsSuppression else {
            hiddenSince = nil
            if isSuppressed {
                isSuppressed = false
                return .release
            }
            return .none
        }
        if isSuppressed {
            return .none
        }
        let since = hiddenSince ?? now
        hiddenSince = since
        let elapsed = now - since
        if elapsed >= Self.hideDebounce {
            isSuppressed = true
            return .suppress
        }
        return .recheck(after: Self.hideDebounce - elapsed)
    }

    /// A new connection starts with output allowed.
    public mutating func connectionDidReset() {
        isSuppressed = false
        hiddenSince = nil
    }
}
