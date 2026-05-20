import Foundation

public struct RDPFrame: Equatable, Sendable {
    public let bgra: Data
    public let width: Int
    public let height: Int
    public let stride: Int

    public init(bgra: Data, width: Int, height: Int, stride: Int) {
        self.bgra = bgra
        self.width = width
        self.height = height
        self.stride = stride
    }
}
