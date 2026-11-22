import Foundation

public enum FileTransferStagingError: Error, Equatable {
    case sourceDoesNotExist(URL)
    case unableToCreateStagingDirectory(URL)
    case unableToReadFileSize(URL)
    case unsafeRemoteFileName(String)
    case unableToCreateRemoteDropFile(URL, errno: Int32)
    case refusedToRemove(URL)
}

public struct LocalFileStagingResult {
    public let files: [StagedFile]
    public let omittedCount: Int
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
        try stageLocalSelection(urls).files
    }

    public func stageLocalSelection(_ urls: [URL]) throws -> LocalFileStagingResult {
        try stageLocalSelection(urls) { root, keys, reportError in
            fileManager.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: reportError)
        }
    }

    func stageLocalSelection(
        _ urls: [URL],
        enumerate: (URL, [URLResourceKey], @escaping (URL, Error) -> Bool) -> FileManager.DirectoryEnumerator?
    ) throws -> LocalFileStagingResult {
        try prepare()
        var files: [StagedFile] = []
        var names: Set<String> = []
        var omitted = 0
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]

        func append(_ url: URL, name: String, values: URLResourceValues) throws -> Bool {
            guard let isLink = values.isSymbolicLink, let isDirectory = values.isDirectory,
                  let isRegularFile = values.isRegularFile else {
                throw FileTransferStagingError.unableToReadFileSize(url)
            }
            guard !isLink, isDirectory || isRegularFile, !name.isEmpty, name.utf16.count <= 259,
                  !name.hasPrefix("/"), name.utf8.dropFirst().first != 0x3A,
                  names.insert(name).inserted else {
                omitted += 1
                return false
            }
            let size = isDirectory ? 0 : values.fileSize
            guard let size, size >= 0 else {
                throw FileTransferStagingError.unableToReadFileSize(url)
            }
            files.append(StagedFile(sourceURL: url, stagedURL: url, fileName: name,
                                    byteCount: UInt64(size), isDirectory: isDirectory))
            return isDirectory
        }

        for selected in urls {
            // Resolve only the parent. The selected item itself must still be classified.
            let parent = selected.deletingLastPathComponent()
            guard let physicalPath = parent.withUnsafeFileSystemRepresentation({ path in
                path.flatMap { realpath($0, nil) }
            }) else {
                throw FileTransferStagingError.sourceDoesNotExist(selected)
            }
            let root = URL(fileURLWithPath: String(cString: physicalPath), isDirectory: true)
                .appendingPathComponent(selected.lastPathComponent)
            free(physicalPath)
            let rootName = Self.sanitizeLocalTransferComponent(selected.lastPathComponent)
            let first = files.count
            guard try append(root, name: rootName, values: root.resourceValues(forKeys: keys)) else { continue }

            var enumerationError: Error?
            guard let enumerator = enumerate(root, Array(keys), { _, error in
                enumerationError = error
                return false
            }) else {
                throw FileTransferStagingError.sourceDoesNotExist(root)
            }
            let prefix = root.pathComponents
            for case let child as URL in enumerator {
                let components = child.pathComponents
                guard components.count > prefix.count, components.starts(with: prefix) else {
                    throw FileTransferStagingError.unsafeRemoteFileName(rootName)
                }
                let name = ([rootName] + components.dropFirst(prefix.count).map(Self.sanitizeLocalTransferComponent))
                    .joined(separator: "\\")
                let values = try child.resourceValues(forKeys: keys)
                if try !append(child, name: name, values: values), values.isDirectory == true {
                    enumerator.skipDescendants()
                }
            }
            if let enumerationError { throw enumerationError }
            files.replaceSubrange(first..., with: files[first...].sorted { $0.fileName < $1.fileName })
        }
        return LocalFileStagingResult(files: files, omittedCount: omitted)
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

    private static func sanitizeLocalTransferComponent(_ component: String) -> String {
        FileNameNormalization.normalizeForTransfer(component).replacingOccurrences(of: "\\", with: "_")
    }

    /// Starts materializing one remote file list. Folder entries become directories (design D1).
    public func beginRemoteDrop() throws -> RemoteDropTree {
        try prepare()
        return RemoteDropTree(staging: self, rootPath: rootURL.standardizedFileURL.path)
    }

    /// Removes staged items that will not reach the pasteboard (design D2, INV-L3).
    ///
    /// Only items directly under `rootURL` are accepted; the whole batch is refused before
    /// anything is removed if one is the root itself or lies elsewhere. Symbolic links are
    /// removed, never followed. Items that no longer exist are skipped.
    public func removeRemoteDropItems(_ urls: [URL]) throws {
        let rootPath = rootURL.standardizedFileURL.path
        let paths = try urls.map { url -> String in
            let standardized = url.standardizedFileURL
            let name = standardized.lastPathComponent
            guard !name.isEmpty, name != ".", name != "..", name != "/",
                  standardized.deletingLastPathComponent().standardizedFileURL.path == rootPath else {
                throw FileTransferStagingError.refusedToRemove(url)
            }
            return standardized.path
        }
        for path in paths {
            var stats = stat()
            guard lstat(path, &stats) == 0 else { continue }
            try fileManager.removeItem(atPath: path)
        }
    }

    /// Path components of a remote name: split on "\\", empty components dropped, each one
    /// reduced to one safe name by `safeRemoteFileName`.
    fileprivate static func remoteDropComponents(_ path: String) -> [String] {
        let components = path.split(separator: "\\", omittingEmptySubsequences: true)
            .map { safeRemoteFileName(String($0)) }
        return components.isEmpty ? ["untitled"] : components
    }

    /// Creates a new top-level directory directly under the root (`mkdir 0700`, " N" on EEXIST).
    fileprivate func createRemoteDropTopDirectory(_ name: String, rootPath: String) throws -> (path: String, url: URL) {
        for index in 0...Int.max {
            let candidateName = Self.fitFileSystemNameLimit(base: name, suffix: index == 0 ? "" : " \(index)", ext: "")
            let candidatePath = rootPath + "/" + candidateName
            let candidate = URL(fileURLWithPath: candidatePath, isDirectory: true)
            guard candidate.lastPathComponent == candidateName,
                  candidate.deletingLastPathComponent().standardizedFileURL.path == rootPath else {
                throw FileTransferStagingError.unsafeRemoteFileName(name)
            }
            if candidatePath.withCString({ mkdir($0, 0o700) }) == 0 {
                return (candidatePath, candidate)
            }
            let error = errno
            guard error == EEXIST else {
                throw FileTransferStagingError.unableToCreateRemoteDropFile(candidate, errno: error)
            }
        }
        throw FileTransferStagingError.unsafeRemoteFileName(name)
    }

    /// Creates a new file in an open directory (`O_EXCL | O_NOFOLLOW`, " N" on EEXIST).
    fileprivate static func createRemoteDropFile(named name: String, in directory: Int32, directoryURL: URL) throws -> RemoteDropFile {
        let (base, ext) = splitExtension(name)
        let directoryPath = directoryURL.standardizedFileURL.path
        for index in 0...Int.max {
            let candidateName = fitFileSystemNameLimit(base: base, suffix: index == 0 ? "" : " \(index)", ext: ext)
            let candidate = URL(fileURLWithPath: directoryPath + "/" + candidateName, isDirectory: false)
            let descriptor = candidateName.withCString {
                openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o666)
            }
            if descriptor >= 0 {
                return RemoteDropFile(url: candidate, handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
            }
            let error = errno
            guard error == EEXIST else {
                throw FileTransferStagingError.unableToCreateRemoteDropFile(candidate, errno: error)
            }
        }
        throw FileTransferStagingError.unsafeRemoteFileName(name)
    }
}

/// One remote file list being materialized under the staging root (design D1, INV-F1).
///
/// Names are remote "\\"-separated paths. Each first component gets one directory of this list,
/// created exclusively; deeper directories are made with `mkdirat` and opened with
/// `O_DIRECTORY | O_NOFOLLOW`, so nothing outside that directory is ever reached. A name with
/// one component is a top-level file and is created by `createRemoteDropFile`.
public final class RemoteDropTree {
    private let staging: FileTransferStaging
    private let rootPath: String
    private var directories: [String: (path: String, url: URL)] = [:]
    /// The list's top-level items (directories and files), in first-seen order.
    public private(set) var topLevelURLs: [URL] = []

    fileprivate init(staging: FileTransferStaging, rootPath: String) {
        self.staging = staging
        self.rootPath = rootPath
    }

    public func createDirectory(path: String) throws {
        let opened = try openDirectory(FileTransferStaging.remoteDropComponents(path)[...])
        close(opened.descriptor)
    }

    public func createFile(path: String) throws -> RemoteDropFile {
        let components = FileTransferStaging.remoteDropComponents(path)
        guard components.count > 1 else {
            let file = try staging.createRemoteDropFile(fileName: components[0])
            topLevelURLs.append(file.url)
            return file
        }
        let parent = try openDirectory(components.dropLast())
        defer { close(parent.descriptor) }
        return try FileTransferStaging.createRemoteDropFile(named: components[components.count - 1], in: parent.descriptor, directoryURL: parent.url)
    }

    /// Opens the directory for `components`, creating missing levels. Caller closes the returned descriptor.
    private func openDirectory(_ components: ArraySlice<String>) throws -> (descriptor: Int32, url: URL) {
        let top = components[components.startIndex]
        let topDirectory: (path: String, url: URL)
        if let existing = directories[top] {
            topDirectory = existing
        } else {
            topDirectory = try staging.createRemoteDropTopDirectory(top, rootPath: rootPath)
            directories[top] = topDirectory
            topLevelURLs.append(topDirectory.url)
        }

        let topDescriptor = topDirectory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard topDescriptor >= 0 else {
            throw FileTransferStagingError.unableToCreateRemoteDropFile(topDirectory.url, errno: errno)
        }

        var current = (descriptor: topDescriptor, url: topDirectory.url)
        for name in components.dropFirst() {
            let url = URL(fileURLWithPath: current.url.standardizedFileURL.path + "/" + name, isDirectory: true)
            let made = name.withCString { mkdirat(current.descriptor, $0, 0o700) }
            if made != 0, errno != EEXIST {
                let error = errno
                close(current.descriptor)
                throw FileTransferStagingError.unableToCreateRemoteDropFile(url, errno: error)
            }
            let next = name.withCString { openat(current.descriptor, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            let error = errno
            close(current.descriptor)
            guard next >= 0 else {
                throw FileTransferStagingError.unableToCreateRemoteDropFile(url, errno: error)
            }
            current = (next, url)
        }
        return current
    }
}
