import Foundation
import RDPClientCore

struct ExternalCredentialProvider {
    enum Key {
        static let host = "RDP_MAC_HOST"
        static let port = "RDP_MAC_PORT"
        static let username = "RDP_MAC_USERNAME"
        static let password = "RDP_MAC_PASSWORD"
        static let domain = "RDP_MAC_DOMAIN"
        static let redirectedFolderPath = "RDP_MAC_REDIRECT_FOLDER_PATH"
        static let redirectedFolderName = "RDP_MAC_REDIRECT_FOLDER_NAME"
        static let audioPlaybackMode = "RDP_MAC_AUDIO_MODE"
        static let logFilePath = "RDP_MAC_LOG_FILE"
        static let logLevel = "RDP_MAC_LOG_LEVEL"
        static let logFilters = "RDP_MAC_LOG_FILTERS"
        static let preferDeviceNativeResolution = "RDP_MAC_PREFER_NATIVE_RESOLUTION"
        static let colorDepth = "RDP_MAC_COLOR_DEPTH"
        static let forcedDesktopSize = "RDP_MAC_FORCED_DESKTOP_SIZE"
        static let autoConnect = "RDP_MAC_AUTOCONNECT"
    }

    let environment: [String: String]

    init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    var shouldAutoConnect: Bool {
        let value = environment[Key.autoConnect]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    func connectionOptions() -> RDPConnectionOptions? {
        guard let host = trimmed(environment[Key.host]), !host.isEmpty else {
            return nil
        }

        return RDPConnectionOptions(
            host: host,
            port: parsedPort(environment[Key.port]),
            username: nilIfEmpty(trimmed(environment[Key.username])),
            password: nilIfEmpty(environment[Key.password]),
            domain: nilIfEmpty(trimmed(environment[Key.domain])),
            redirectedFolderPath: nilIfEmpty(trimmed(environment[Key.redirectedFolderPath])),
            redirectedFolderName: nilIfEmpty(trimmed(environment[Key.redirectedFolderName])),
            audioPlaybackMode: parsedAudioPlaybackMode(environment[Key.audioPlaybackMode]),
            logFileURL: parsedLogFileURL(environment[Key.logFilePath]),
            logLevel: parsedLogLevel(environment[Key.logLevel]),
            logFilters: parsedLogFilters(environment[Key.logFilters]),
            preferDeviceNativeResolution: parsedBool(environment[Key.preferDeviceNativeResolution], defaultValue: true),
            colorDepth: parsedColorDepth(environment[Key.colorDepth]),
            forcedDesktopSize: parsedDesktopSize(environment[Key.forcedDesktopSize])
        )
    }

    private func parsedPort(_ value: String?) -> UInt16 {
        guard let value, let port = UInt16(value), port > 0 else {
            return 3389
        }
        return port
    }

    private func trimmed(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func nilIfEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private func parsedAudioPlaybackMode(_ value: String?) -> RDPAudioPlaybackMode {
        switch trimmed(value)?.lowercased() {
        case "local", "play-locally", "playlocally", "mac", "1":
            return .playLocally
        case "remote", "play-on-remote", "playonremote", "server", "2":
            return .playOnRemote
        default:
            return .disabled
        }
    }

    private func parsedLogFileURL(_ value: String?) -> URL? {
        guard let path = nilIfEmpty(trimmed(value)) else {
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    private func parsedLogLevel(_ value: String?) -> RDPLogLevel {
        guard let value = nilIfEmpty(trimmed(value))?.lowercased(),
              let level = RDPLogLevel(rawValue: value) else {
            return .info
        }
        return level
    }

    private func parsedLogFilters(_ value: String?) -> [String: RDPLogLevel] {
        guard let value = nilIfEmpty(trimmed(value)) else {
            return [:]
        }

        var filters: [String: RDPLogLevel] = [:]
        for entry in value.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, let level = RDPLogLevel(rawValue: parts[1].lowercased()) else {
                continue
            }
            filters[parts[0]] = level
        }
        return filters
    }

    private func parsedBool(_ value: String?, defaultValue: Bool) -> Bool {
        switch trimmed(value)?.lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return defaultValue
        }
    }

    private func parsedColorDepth(_ value: String?) -> RDPColorDepth {
        switch trimmed(value) {
        case "16":
            return .depth16
        case "24":
            return .depth24
        default:
            return .depth32
        }
    }

    private func parsedDesktopSize(_ value: String?) -> CGSize? {
        guard let value = nilIfEmpty(trimmed(value))?.lowercased() else {
            return nil
        }
        let parts = value
            .replacingOccurrences(of: "×", with: "x")
            .split(separator: "x", maxSplits: 1)
            .compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else {
            return nil
        }
        return CGSize(width: parts[0], height: parts[1])
    }
}
