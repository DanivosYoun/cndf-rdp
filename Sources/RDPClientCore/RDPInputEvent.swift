import Foundation

public enum RDPPointerButton: Equatable, Sendable {
    case left
    case right
    case middle
}

public struct RDPPointerLocation: Equatable, Sendable {
    public let pixelX: UInt32
    public let pixelY: UInt32

    public init(pixelX: UInt32, pixelY: UInt32) {
        self.pixelX = pixelX
        self.pixelY = pixelY
    }
}
