import Foundation

public enum FileTransferStagingError: Error, Equatable {
    case sourceDoesNotExist(URL)
    case unableToCreateStagingDirectory(URL)
    case unableToReadFileSize(URL)
    case unsafeRemoteFileName(String)
    case unableToCreateRemoteDropFile(URL, errno: Int32)
}

/// A new, empty file created exclusively inside the staging root for a remote clipboard file.
public struct RemoteDropFile {
    public let url: URL
    public let handle: FileHandle
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

    /// Creates a new file for a remote (server-supplied) file name directly under `rootURL`.
    ///
    /// The name is untrusted: it is reduced to one safe path component, and the file is created
    /// with `O_CREAT | O_EXCL | O_NOFOLLOW`, so an existing file or a planted symbolic link is
    /// never opened or followed — the next free " N" name is used instead.
    public func createRemoteDropFile(fileName: String) throws -> RemoteDropFile {
        try prepare()

        let safeName = Self.safeRemoteFileName(fileName)
        let (base, ext) = Self.splitExtension(safeName)
        let rootPath = rootURL.standardizedFileURL.path

        for index in 0...Int.max {
            let candidateName = Self.fitFileSystemNameLimit(
                base: base,
                suffix: index == 0 ? "" : " \(index)",
                ext: ext
            )
            // Open by this composed string, not by `URL.path`: Darwin file URLs hand back
            // decomposed (NFD) paths, which would store Korean names decomposed on disk.
            let candidatePath = rootPath + "/" + candidateName
            let candidate = URL(fileURLWithPath: candidatePath, isDirectory: false)
            guard candidate.lastPathComponent == candidateName,
                  candidate.deletingLastPathComponent().standardizedFileURL.path == rootPath else {
                throw FileTransferStagingError.unsafeRemoteFileName(fileName)
            }

            let descriptor = candidatePath.withCString {
                open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
            }
            if descriptor >= 0 {
                return RemoteDropFile(url: candidate, handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
            }
            let error = errno
            guard error == EEXIST else {
                throw FileTransferStagingError.unableToCreateRemoteDropFile(candidate, errno: error)
            }
        }

        throw FileTransferStagingError.unsafeRemoteFileName(fileName)
    }

    /// NFC, with path separators ("/", "\\"), NUL and other control characters replaced by "_".
    /// ".", ".." and the empty name become "untitled".
    private static func safeRemoteFileName(_ fileName: String) -> String {
        let scalars = FileNameNormalization.normalizeForTransfer(fileName).unicodeScalars.map { scalar -> Unicode.Scalar in
            scalar == "/" || scalar == "\\" || scalar.value < 0x20 || scalar.value == 0x7F ? "_" : scalar
        }
        let replaced = FileNameNormalization.normalizeForTransfer(String(String.UnicodeScalarView(scalars)))
        return replaced.isEmpty || replaced == "." || replaced == ".." ? "untitled" : replaced
    }

    private static let maxExtensionUTF8Length = 32
    private static let maxFileNameUTF8Length = 255

    private static func splitExtension(_ name: String) -> (base: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return (name, "")
        }
        let ext = String(name[name.index(after: dot)...])
        guard !ext.isEmpty, ext.utf8.count <= maxExtensionUTF8Length else {
            return (name, "")
        }
        return (String(name[..<dot]), ext)
    }

    /// Truncates `base` on character boundaries so the whole name fits NAME_MAX (255 UTF-8 bytes).
    private static func fitFileSystemNameLimit(base: String, suffix: String, ext: String) -> String {
        let tail = suffix + (ext.isEmpty ? "" : "." + ext)
        var base = base
        while !base.isEmpty, base.utf8.count + tail.utf8.count > maxFileNameUTF8Length {
            base.removeLast()
        }
        return base + tail
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
