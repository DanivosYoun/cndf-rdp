import Foundation

public enum FileTransferStagingError: Error, Equatable {
    case sourceDoesNotExist(URL)
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

        return try urls.flatMap { sourceURL in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
                throw FileTransferStagingError.sourceDoesNotExist(sourceURL)
            }
            if isDirectory.boolValue {
                return try stageLocalDirectoryForRemotePaste(sourceURL)
            }

            return [try stageLocalFileForRemotePaste(sourceURL, fileName: sourceURL.lastPathComponent)]
        }
    }

    public func makeRemoteDropDestination(fileName: String) throws -> URL {
        try prepare()
        return availableStagedURL(for: fileName)
    }

    private func availableStagedURL(for fileName: String) -> URL {
        let normalizedName = FileNameNormalization.normalizeForTransfer(fileName)
        let safeName = normalizedName.isEmpty ? "untitled" : normalizedName
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

    private func stageLocalDirectoryForRemotePaste(_ directoryURL: URL) throws -> [StagedFile] {
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [StagedFile] = []
        let rootName = FileNameNormalization.normalizeForTransfer(directoryURL.lastPathComponent)
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values.isDirectory == true {
                continue
            }
            let relativePath = relativeTransferPath(fileURL: fileURL, rootURL: directoryURL, rootName: rootName)
            files.append(try stageLocalFileForRemotePaste(fileURL, fileName: relativePath))
        }
        return files.sorted { $0.fileName < $1.fileName }
    }

    private func stageLocalFileForRemotePaste(_ sourceURL: URL, fileName: String) throws -> StagedFile {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw FileTransferStagingError.unableToReadFileSize(sourceURL)
        }

        return StagedFile(
            sourceURL: sourceURL,
            stagedURL: sourceURL,
            fileName: normalizedTransferPath(fileName),
            byteCount: UInt64(size)
        )
    }

    private func relativeTransferPath(fileURL: URL, rootURL: URL, rootName: String) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let filePath = fileURL.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let relative = filePath.hasPrefix(prefix) ? String(filePath.dropFirst(prefix.count)) : fileURL.lastPathComponent
        return ([rootName] + relative.split(separator: "/").map(String.init)).joined(separator: "\\")
    }

    private func normalizedTransferPath(_ path: String) -> String {
        path
            .split(separator: "\\", omittingEmptySubsequences: false)
            .map { FileNameNormalization.normalizeForTransfer(String($0)) }
            .joined(separator: "\\")
    }
}
