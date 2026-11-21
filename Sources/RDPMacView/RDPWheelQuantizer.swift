import AppKit

/// Turns a stream of AppKit scroll deltas into integer wheel values, one axis at a time, without
/// losing the fractions in between. Each axis computes `delta × scale + residual`, sends the nearest
/// integer (an exact half goes to the even neighbour) and keeps the difference as the residual, so
/// the running sum of the sent values stays within half a unit of the running input.
///
/// The local RDP view and the shared viewer use this same routine, so the same AppKit event stream
/// produces the same rotation stream on both paths. Values are AppKit-signed; the horizontal RDP
/// sign flip (`rdpHorizontalWheelRotation`) is applied once, later, by whoever injects.
///
/// Residual lifetime follows the gesture: a new gesture (`began`/`mayBegin`) starts from zero, the
/// residual of a direct gesture carries into its momentum, and a cancelled gesture or the end of
/// momentum clears it. Callers clear it with `reset()` when their input segment ends.
public struct RDPWheelQuantizer {
    /// One RDP wheel notch (WHEEL_DELTA) per AppKit line.
    public static let rotationUnitsPerLine: Double = 120
    /// Largest magnitude the 9-bit RDP wheel field carries symmetrically (it encodes −256…+255).
    public static let rotationLimit: Int32 = 255

    public let scale: Double
    public let limit: Int32
    private var residualX: Double = 0
    private var residualY: Double = 0

    /// Defaults to RDP wheel rotation: 120 units per line, saturating at ±255.
    public init(scale: Double = RDPWheelQuantizer.rotationUnitsPerLine,
                limit: Int32 = RDPWheelQuantizer.rotationLimit) {
        self.scale = scale
        self.limit = limit
    }

    public mutating func reset() {
        residualX = 0
        residualY = 0
    }

    public mutating func quantize(_ event: NSEvent) -> (x: Int32, y: Int32) {
        quantize(deltaX: Double(event.deltaX), deltaY: Double(event.deltaY),
                 phase: event.phase, momentumPhase: event.momentumPhase)
    }

    public mutating func quantize(deltaX: Double, deltaY: Double,
                                  phase: NSEvent.Phase = [],
                                  momentumPhase: NSEvent.Phase = []) -> (x: Int32, y: Int32) {
        if phase.contains(.began) || phase.contains(.mayBegin) {
            reset()
        }
        let result = (x: Self.take(deltaX, scale: scale, limit: limit, residual: &residualX),
                      y: Self.take(deltaY, scale: scale, limit: limit, residual: &residualY))
        if phase.contains(.cancelled) || momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) {
            reset()
        }
        return result
    }

    /// A non-finite input is dropped before it reaches the residual. The part cut off by saturation
    /// is dropped too: only the rounding fraction carries over.
    private static func take(_ delta: Double, scale: Double, limit: Int32, residual: inout Double) -> Int32 {
        let scaled = delta * scale
        guard scaled.isFinite else { return 0 }
        let value = residual + scaled
        let rounded = value.rounded(.toNearestOrEven)
        residual = value - rounded
        let bound = Double(limit)
        return Int32(max(-bound, min(bound, rounded)))
    }
}
