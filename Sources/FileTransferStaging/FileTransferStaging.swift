import Foundation

public enum FileTransferStagingError: Error, Equatable {
    case sourceDoesNotExist(URL)
    case sourceIsDirectory(URL)
    case unableToCreateStagingDirectory(URL)
    case unableToReadFileSize(URL)
}

public final class FileTransferStaging {
    public let rootURL: URL
    private let fileManager: FileManager

    public init(
        rootURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("rdp-mac-file-staging", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    public func prepare() throws {
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) {
            if !isDirectory.boolValue {
                throw FileTransferStagingError.unableToCreateStagingDirectory(rootURL)
            }
            return
        }

        do {
            try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            throw FileTransferStagingError.unableToCreateStagingDirectory(rootURL)
        }
    }

    public func stageLocalFilesForRemotePaste(_ urls: [URL]) throws -> [StagedFile] {
        try prepare()

        return try urls.map { sourceURL in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                throw FileTransferStagingError.sourceDoesNotExist(sourceURL)
            }
            guard !isDirectory.boolValue else {
                throw FileTransferStagingError.sourceIsDirectory(sourceURL)
            }

            let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
            guard let size = values.fileSize else {
                throw FileTransferStagingError.unableToReadFileSize(sourceURL)
            }

            return StagedFile(
                sourceURL: sourceURL,
                stagedURL: sourceURL,
                fileName: sourceURL.lastPathComponent,
                byteCount: UInt64(size)
            )
        }
    }

    public func makeRemoteDropDestination(fileName: String) throws -> URL {
        try prepare()
        return availableStagedURL(for: fileName)
    }

    private func availableStagedURL(for fileName: String) -> URL {
        let safeName = fileName.isEmpty ? "untitled" : fileName
        let baseURL = rootURL.appendingPathComponent(safeName, isDirectory: false)
        guard fileManager.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let name = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension

        for index in 1...Int.max {
            let candidateName = ext.isEmpty ? "\(name) \(index)" : "\(name) \(index).\(ext)"
            let candidate = rootURL.appendingPathComponent(candidateName, isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return rootURL.appendingPathComponent(UUID().uuidString, isDirectory: false)
    }
}
