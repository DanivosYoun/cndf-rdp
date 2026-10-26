import Foundation

/// The pointer shape the server asked the client to show.
public enum RDPRemotePointer: Equatable, Sendable {
    case image(RDPPointerImage)
    case hidden
    case systemDefault
}

/// Server pointer pixels: top-down BGRA with straight (not premultiplied) alpha.
/// Sizes and hot spot are in remote desktop pixels.
public struct RDPPointerImage: Equatable, Sendable {
    public let bgra: Data
    public let width: Int
    public let height: Int
    public let stride: Int
    public let hotSpotX: Int
    public let hotSpotY: Int

    public init(bgra: Data, width: Int, height: Int, stride: Int, hotSpotX: Int, hotSpotY: Int) {
        self.bgra = bgra
        self.width = width
        self.height = height
        self.stride = stride
        self.hotSpotX = hotSpotX
        self.hotSpotY = hotSpotY
    }
}
