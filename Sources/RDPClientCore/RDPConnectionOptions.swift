import Foundation

public struct RDPConnectionOptions: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let username: String?
    public let password: String?
    public let domain: String?
    public let enableClipboard: Bool
    public let enableDriveRedirection: Bool

    public init(
        host: String,
        port: UInt16 = 3389,
        username: String? = nil,
        password: String? = nil,
        domain: String? = nil,
        enableClipboard: Bool = true,
        enableDriveRedirection: Bool = false
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.domain = domain
        self.enableClipboard = enableClipboard
        self.enableDriveRedirection = enableDriveRedirection
    }
}
