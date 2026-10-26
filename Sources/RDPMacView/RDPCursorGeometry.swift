import CoreGraphics

/// Size and hot spot, in view points, of a server pointer drawn at the scale the remote
/// frame is displayed at.
public struct RDPCursorGeometry: Equatable {
    public let size: CGSize
    public let hotSpot: CGPoint

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        hotSpotX: Int,
        hotSpotY: Int,
        pointsPerRemotePixel: CGFloat
    ) {
        let scale = pointsPerRemotePixel > 0 ? pointsPerRemotePixel : 1
        let width = max(1, pixelWidth)
        let height = max(1, pixelHeight)
        // NSCursor needs the hot spot inside the image.
        let hotX = min(max(0, hotSpotX), width - 1)
        let hotY = min(max(0, hotSpotY), height - 1)
        size = CGSize(width: CGFloat(width) * scale, height: CGFloat(height) * scale)
        hotSpot = CGPoint(x: CGFloat(hotX) * scale, y: CGFloat(hotY) * scale)
    }
}
