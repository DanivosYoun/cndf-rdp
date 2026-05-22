import Foundation

public enum RDPPointerButton: Equatable, Sendable {
    case left
    case right
    case middle
}

public struct RDPMouseFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let move = RDPMouseFlags(rawValue: 1 << 0)
    public static let down = RDPMouseFlags(rawValue: 1 << 1)
    public static let up = RDPMouseFlags(rawValue: 1 << 2)
}

public enum RDPMouseButton: UInt8, Equatable, Sendable {
    case left = 0
    case right = 1
    case middle = 2
}

public struct RDPKeyFlags: OptionSet, Equatable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let down = RDPKeyFlags(rawValue: 1 << 0)
    public static let up = RDPKeyFlags(rawValue: 1 << 1)
    public static let extended = RDPKeyFlags(rawValue: 1 << 2)
}

public struct RDPPointerLocation: Equatable, Sendable {
    public let pixelX: UInt32
    public let pixelY: UInt32

    public init(pixelX: UInt32, pixelY: UInt32) {
        self.pixelX = pixelX
        self.pixelY = pixelY
    }
}
