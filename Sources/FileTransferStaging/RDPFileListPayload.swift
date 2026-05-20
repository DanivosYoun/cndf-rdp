import Foundation

public struct RDPFileListEntry: Equatable, Sendable {
    public let fileName: String
    public let byteCount: UInt64
    public let localURL: URL?

    public init(fileName: String, byteCount: UInt64, localURL: URL?) {
        self.fileName = fileName
        self.byteCount = byteCount
        self.localURL = localURL
    }
}

public enum RDPFileListPayloadError: Error, Equatable {
    case invalidPayload
    case unsupportedVersion(Int)
}

public enum RDPFileListPayload {
    private struct Envelope: Codable {
        let version: Int
        let files: [Entry]
    }

    private struct Entry: Codable {
        let fileName: String
        let byteCount: UInt64
        let localPath: String?
    }

    public static func encode(_ files: [StagedFile]) throws -> Data {
        let entries = files.map {
            Entry(fileName: $0.fileName, byteCount: $0.byteCount, localPath: $0.stagedURL.path)
        }
        return try JSONEncoder().encode(Envelope(version: 1, files: entries))
    }

    public static func decode(_ data: Data) throws -> [RDPFileListEntry] {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            throw RDPFileListPayloadError.invalidPayload
        }

        guard envelope.version == 1 else {
            throw RDPFileListPayloadError.unsupportedVersion(envelope.version)
        }

        return envelope.files.map {
            RDPFileListEntry(
                fileName: $0.fileName,
                byteCount: $0.byteCount,
                localURL: $0.localPath.map(URL.init(fileURLWithPath:))
            )
        }
    }
}
