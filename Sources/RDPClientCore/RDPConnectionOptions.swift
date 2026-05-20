import Foundation

public struct RDPConnectionOptions: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let username: String?
    public let password: String?
    public let domain: String?
    public let enableClipboard: Bool
    public let enableDriveRedirection: Bool
    public let redirectedFolderPath: String?
    public let redirectedFolderName: String?
    public let audioPlaybackMode: RDPAudioPlaybackMode
    public let logFileURL: URL?

    public init(
        host: String,
        port: UInt16 = 3389,
        username: String? = nil,
        password: String? = nil,
        domain: String? = nil,
        enableClipboard: Bool = true,
        enableDriveRedirection: Bool = false,
        redirectedFolderPath: String? = nil,
        redirectedFolderName: String? = nil,
        audioPlaybackMode: RDPAudioPlaybackMode = .disabled,
        logFileURL: URL? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.domain = domain
        self.enableClipboard = enableClipboard
        self.enableDriveRedirection = enableDriveRedirection
        self.redirectedFolderPath = redirectedFolderPath
        self.redirectedFolderName = redirectedFolderName
        self.audioPlaybackMode = audioPlaybackMode
        self.logFileURL = logFileURL
    }
}

public enum RDPAudioPlaybackMode: UInt32, Equatable, Sendable {
    case disabled = 0
    case playLocally = 1
    case playOnRemote = 2
}
