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
            logFileURL: parsedLogFileURL(environment[Key.logFilePath])
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
}
