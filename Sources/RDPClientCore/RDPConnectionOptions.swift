import CoreGraphics
import Foundation
import IronRDPBridge

public struct RDPConnectionOptions: Equatable, Sendable {
    public let host: String
    public let port: UInt16
    public let username: String?
    public let password: String?
    public let securePassword: RDPSecureString?
    public let domain: String?
    public let enableClipboard: Bool
    /// A named pasteboard for isolated sessions. Nil uses the system pasteboard.
    public let pasteboardName: String?
    public let enableDriveRedirection: Bool
    public let redirectedFolderPath: String?
    public let redirectedFolderName: String?
    public let audioPlaybackMode: RDPAudioPlaybackMode
    public let logFileURL: URL?
    public let logLevel: RDPLogLevel
    public let logFilters: [String: RDPLogLevel]
    public let preferDeviceNativeResolution: Bool
    public let colorDepth: RDPColorDepth
    public let forcedDesktopSize: CGSize?
    /// Lets the server run RDP network auto-detection (RTT/bandwidth). Off by default.
    public let networkAutoDetect: Bool
    public let graphicsMode: RDPGraphicsMode
    /// The engine `RDPConnectionView.connect` creates the session with. Fixed for the session.
    public let engine: RDPEngineKind
    /// GCC keyboard fields both engines advertise. Fixed for the session.
    public let keyboardProfile: RDPKeyboardProfile

    public init(
        host: String,
        port: UInt16 = 3389,
        username: String? = nil,
        password: String? = nil,
        securePassword: RDPSecureString? = nil,
        domain: String? = nil,
        enableClipboard: Bool = true,
        enableDriveRedirection: Bool = false,
        redirectedFolderPath: String? = nil,
        redirectedFolderName: String? = nil,
        audioPlaybackMode: RDPAudioPlaybackMode = .disabled,
        logFileURL: URL? = nil,
        logLevel: RDPLogLevel = .info,
        logFilters: [String: RDPLogLevel] = [:],
        preferDeviceNativeResolution: Bool = true,
        colorDepth: RDPColorDepth = .depth32,
        forcedDesktopSize: CGSize? = nil,
        networkAutoDetect: Bool = false,
        graphicsMode: RDPGraphicsMode = .automatic,
        engine: RDPEngineKind = .freeRDP,
        pasteboardName: String? = nil,
        keyboardProfile: RDPKeyboardProfile = .standard
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.securePassword = securePassword
        self.domain = domain
        self.enableClipboard = enableClipboard
        self.pasteboardName = pasteboardName
        self.enableDriveRedirection = enableDriveRedirection
        self.redirectedFolderPath = redirectedFolderPath
        self.redirectedFolderName = redirectedFolderName
        self.audioPlaybackMode = audioPlaybackMode
        self.logFileURL = logFileURL
        self.logLevel = logLevel
        self.logFilters = logFilters
        self.preferDeviceNativeResolution = preferDeviceNativeResolution
        self.colorDepth = colorDepth
        self.forcedDesktopSize = forcedDesktopSize
        self.networkAutoDetect = networkAutoDetect
        self.graphicsMode = graphicsMode
        self.engine = engine
        self.keyboardProfile = keyboardProfile
    }
}

/// The keyboard a connection reports in GCC Client Core Data (design D2). The server's keyboard
/// driver for this type and subtype decides which scancodes become VK_HANGUL and VK_HANJA.
public enum RDPKeyboardProfile: String, Codable, Sendable {
    /// What both engines sent before profiles existed.
    case standard
    /// Korean 101-key Type 1: right Alt is Han/Yeong and right Ctrl is Hanja.
    case korean

    public var keyboardLayout: UInt32 { gccFields.layout }
    public var keyboardType: UInt32 { gccFields.type }
    public var keyboardSubType: UInt32 { gccFields.subType }
    public var keyboardFunctionKey: UInt32 { gccFields.functionKey }

    // The one table of GCC keyboard values. The IME file name stays empty for every profile.
    private var gccFields: (layout: UInt32, type: UInt32, subType: UInt32, functionKey: UInt32) {
        switch self {
        case .standard: return (0, 4, 0, 12)
        case .korean: return (0x412, 8, 3, 12)
        }
    }
}

public enum RDPGraphicsMode: String, Codable, Sendable {
    case automatic = "auto"
    case compatibility = "compat"
}

public enum RDPEngineKind: String, Codable, Sendable {
    case freeRDP = "freerdp"
    case ironRDP = "ironrdp"

    /// Whether this engine has a clipboard channel (`RDPEngineSession.supportsClipboard`).
    /// Known before connecting, so callers can compute the effective clipboard setting
    /// (design I11) before the session exists.
    public var supportsClipboard: Bool {
        supportsIronCapability(CNDF_IRON_CAP_CLIPBOARD)
    }

    public var supportsDriveRedirection: Bool {
        supportsIronCapability(CNDF_IRON_CAP_DRIVE)
    }

    public func supportsAudioPlayback(_ mode: RDPAudioPlaybackMode) -> Bool {
        switch mode {
        case .disabled: return true
        case .playLocally: return supportsIronCapability(CNDF_IRON_CAP_AUDIO_LOCAL)
        case .playOnRemote: return supportsIronCapability(CNDF_IRON_CAP_AUDIO_REMOTE)
        }
    }

    private func supportsIronCapability(_ bit: UInt32) -> Bool {
        self == .freeRDP || (cndf_iron_capabilities() & bit) != 0
    }
}

public enum RDPAudioPlaybackMode: UInt32, Equatable, Sendable {
    case disabled = 0
    case playLocally = 1
    case playOnRemote = 2
}

public enum RDPColorDepth: UInt32, Equatable, Sendable {
    case depth16 = 16
    case depth24 = 24
    case depth32 = 32
}

public enum RDPLogLevel: String, Equatable, Sendable {
    case trace
    case debug
    case info
    case warn
    case error
    case fatal
    case off
}

extension RDPConnectionOptions {
    var channelLogMessage: String {
        let audio: String
        switch audioPlaybackMode {
        case .disabled: audio = "off"
        case .playLocally: audio = "local"
        case .playOnRemote: audio = "remote"
        }
        let folder = redirectedFolderPath?.isEmpty == false
        return "RDP channels clipboard=\(enableClipboard ? "on" : "off") folder=\(folder ? "on" : "off") audio=\(audio)"
    }

    /// Both engines log this line, so their GCC keyboard fields can be diffed (design I4).
    var keyboardLogMessage: String {
        let profile = keyboardProfile
        return "RDP keyboard profile=\(profile.rawValue) layout=0x\(String(profile.keyboardLayout, radix: 16))"
            + " type=\(profile.keyboardType) subtype=\(profile.keyboardSubType) fn=\(profile.keyboardFunctionKey)"
    }
}
