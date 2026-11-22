@testable import FileTransferStaging
import XCTest

final class FileTransferStagingTests: XCTestCase {
    func testPreparesLocalFileWithoutCopyingIntoStagingDirectory() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = temp.appendingPathComponent("source.txt")
        let stagingRoot = temp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "hello".data(using: .utf8)!.write(to: source)
        defer { try? FileManager.default.removeItem(at: temp) }

        let staging = FileTransferStaging(rootURL: stagingRoot)
        let files = try staging.stageLocalFilesForRemotePaste([source])

        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].fileName, "source.txt")
        XCTAssertEqual(files[0].byteCount, 5)
        XCTAssertEqual(try Data(contentsOf: files[0].stagedURL), Data("hello".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingRoot.appendingPathComponent("source.txt").path))
    }

    func testNormalizesLocalFileNameToNFCForRemotePaste() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let decomposedName = "한글.txt".decomposedStringWithCanonicalMapping
        let source = temp.appendingPathComponent(decomposedName)
        let stagingRoot = temp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        try "hello".data(using: .utf8)!.write(to: source)
        defer { try? FileManager.default.removeItem(at: temp) }

        let staging = FileTransferStaging(rootURL: stagingRoot)
        let files = try staging.stageLocalFilesForRemotePaste([source])

        XCTAssertEqual(files[0].fileName, "한글.txt")
        XCTAssertEqual(files[0].fileName.unicodeScalars.map(\.value), "한글.txt".unicodeScalars.map(\.value))
    }

    func testStagesFolderContentsWithRelativeTransferPaths() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = temp.appendingPathComponent("Folder", isDirectory: true)
        let nested = folder.appendingPathComponent("Sub", isDirectory: true)
        let sourceA = folder.appendingPathComponent("a.txt")
        let sourceB = nested.appendingPathComponent("한글.txt".decomposedStringWithCanonicalMapping)
        let stagingRoot = temp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "a".data(using: .utf8)!.write(to: sourceA)
        try "hello".data(using: .utf8)!.write(to: sourceB)
        defer { try? FileManager.default.removeItem(at: temp) }

        let staging = FileTransferStaging(rootURL: stagingRoot)
        let files = try staging.stageLocalFilesForRemotePaste([folder])

        XCTAssertEqual(files.map(\.fileName), [
            "Folder",
            "Folder\\Sub",
            "Folder\\Sub\\한글.txt",
            "Folder\\a.txt"
        ])
        XCTAssertEqual(files.map(\.isDirectory), [true, true, false, false])
        XCTAssertEqual(files.map(\.byteCount), [0, 0, 5, 1])
        XCTAssertEqual(
            files.map { $0.stagedURL.standardizedFileURL.path },
            [folder, nested, sourceB, sourceA].map { $0.standardizedFileURL.path }
        )
    }

    func testStagesMixedFilesAndFolders() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = temp.appendingPathComponent("Folder", isDirectory: true)
        let nestedFile = folder.appendingPathComponent("nested.txt")
        let standalone = temp.appendingPathComponent("standalone.txt")
        let stagingRoot = temp.appendingPathComponent("staging", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "nested".data(using: .utf8)!.write(to: nestedFile)
        try "standalone".data(using: .utf8)!.write(to: standalone)
        defer { try? FileManager.default.removeItem(at: temp) }

        let staging = FileTransferStaging(rootURL: stagingRoot)
        let files = try staging.stageLocalFilesForRemotePaste([standalone, folder])

        XCTAssertEqual(files.map(\.fileName), [
            "standalone.txt",
            "Folder",
            "Folder\\nested.txt"
        ])
    }

    private func makeTemp() throws -> URL {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        return temp
    }

    /// T-M1: empty and nested folders become directory entries (size 0) next to the files.
    func testStagesEveryFolderIncludingEmptyOnesAsDirectoryEntries() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("M", isDirectory: true)
        for dir in ["M/empty", "M/a/b"] {
            try FileManager.default.createDirectory(at: temp.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try Data("x".utf8).write(to: root.appendingPathComponent("f.txt"))
        try Data("yy".utf8).write(to: root.appendingPathComponent("a/b/g.txt"))

        let files = try FileTransferStaging(rootURL: temp.appendingPathComponent("staging")).stageLocalFilesForRemotePaste([root])

        let directories = files.filter(\.isDirectory)
        XCTAssertEqual(Set(directories.map(\.fileName)), ["M", "M\\empty", "M\\a", "M\\a\\b"])
        XCTAssertTrue(directories.allSatisfy { $0.byteCount == 0 })
        XCTAssertEqual(Set(files.filter { !$0.isDirectory }.map(\.fileName)), ["M\\f.txt", "M\\a\\b\\g.txt"])
        XCTAssertEqual(files.count, 6)
    }

    /// T-M2: every parent comes before all of its descendants.
    func testParentFoldersPrecedeTheirDescendants() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("R", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("z/y/x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: root.appendingPathComponent("z/y/x/k.txt"))
        try Data("1".utf8).write(to: root.appendingPathComponent("A/0.txt"))

        let files = try FileTransferStaging(rootURL: temp.appendingPathComponent("staging")).stageLocalFilesForRemotePaste([root])

        let names = files.map(\.fileName)
        for (index, entry) in files.enumerated() where entry.isDirectory {
            for (other, name) in names.enumerated() where name.hasPrefix(entry.fileName + "\\") {
                XCTAssertLessThan(index, other, "\(entry.fileName) must precede \(name)")
            }
        }
        XCTAssertEqual(names.first, "R")
    }

    /// T-M3: packages and their contents are offered with ordinary files.
    func testPackageInsideFolderIncludesContents() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("P", isDirectory: true)
        let app = root.appendingPathComponent("X.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: app.appendingPathComponent("Info.plist"))

        let files = try FileTransferStaging(rootURL: temp.appendingPathComponent("staging")).stageLocalFilesForRemotePaste([root])

        XCTAssertEqual(files.map(\.fileName), ["P", "P\\X.app", "P\\X.app\\Contents", "P\\X.app\\Contents\\Info.plist"])
    }

    func testMixedPackageAndLinksRetainsOrdinaryFiles() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fm = FileManager.default
        let root = temp.appendingPathComponent("P", isDirectory: true)
        let packages = ["X.app/Contents", "X.app/Contents/Helper.app", "Note.rtfd",
                        "Plugin.bundle", "Project.xcodeproj", ".bundle"]
        for package in packages {
            let folder = root.appendingPathComponent(package, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent("data"))
        }
        let empty = temp.appendingPathComponent("Empty.app", isDirectory: true)
        try fm.createDirectory(at: empty, withIntermediateDirectories: false)
        let plain = temp.appendingPathComponent("plain")
        try Data([9]).write(to: plain)
        let rootLink = temp.appendingPathComponent("root-link")
        try fm.createSymbolicLink(at: rootLink, withDestinationURL: root)
        let bin = root.appendingPathComponent(".bin", isDirectory: true)
        try fm.createDirectory(at: bin, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: bin.appendingPathComponent("tool"), withDestinationURL: plain)
        try fm.createSymbolicLink(at: root.appendingPathComponent("broken"), withDestinationURL: temp.appendingPathComponent("missing"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("package-link"),
                                  withDestinationURL: root.appendingPathComponent("X.app"))

        let staging = FileTransferStaging(rootURL: temp.appendingPathComponent("staging"))
        let selection = [plain, root, empty, rootLink]
        var expected: [String: UInt64] = ["plain": 1, "P": 0, "P\\.bin": 0, "P\\X.app": 0, "Empty.app": 0]
        for package in packages {
            let name = "P\\" + package.replacingOccurrences(of: "/", with: "\\")
            expected[name] = 0
            expected[name + "\\data"] = 3
        }
        for urls in [selection, Array(selection.reversed())] {
            let result = try staging.stageLocalSelection(urls)
            XCTAssertEqual(result.omittedCount, 4)
            XCTAssertEqual(Set(result.files.map(\.fileName)), Set(expected.keys))
            for file in result.files {
                XCTAssertEqual(file.byteCount, expected[file.fileName])
            }
        }
    }

    func testSelectionThroughParentAliasesUsesPhysicalSourcePath() throws {
        #if os(macOS)
        let fm = FileManager.default
        let temp = try makeTemp()
        defer { try? fm.removeItem(at: temp) }
        let physicalParent = temp.resolvingSymlinksInPath()
        let source = physicalParent.appendingPathComponent("file")
        try Data([1]).write(to: source)
        let link = temp.appendingPathComponent("parent-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: physicalParent)
        let volume = try XCTUnwrap(fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)
            .first { (try? fm.destinationOfSymbolicLink(atPath: $0.path)) == "/" })
        let parents = [link, URL(fileURLWithPath: "/tmp"), fm.temporaryDirectory,
                       URL(fileURLWithPath: volume.path + temp.path, isDirectory: true)]
        for parent in parents {
            let work = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: work, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: work) }
            let selected = work.appendingPathComponent("file")
            try Data([1]).write(to: selected)
            let files = try FileTransferStaging(rootURL: temp.appendingPathComponent("staging"))
                .stageLocalFilesForRemotePaste([selected])
            let staged = try XCTUnwrap(files.first)
            XCTAssertEqual(staged.sourceURL.lastPathComponent, "file")
            let fd = open(staged.sourceURL.path, O_RDONLY | O_NOFOLLOW_ANY)
            XCTAssertGreaterThanOrEqual(fd, 0, selected.path)
            if fd >= 0 { close(fd) }
        }
        #endif
    }

    func testUnrepresentableNamesOmitOnlyTheirSubtreeAndKeepFirstCollision() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let fm = FileManager.default
        let root = temp.appendingPathComponent(String(repeating: "a", count: 180), isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let fit = String(repeating: "한", count: 78)
        let over = fit + "한"
        try Data([1]).write(to: root.appendingPathComponent(fit))
        let tooLong = root.appendingPathComponent(over, isDirectory: true)
        try fm.createDirectory(at: tooLong, withIntermediateDirectories: false)
        try Data([2]).write(to: tooLong.appendingPathComponent("child"))
        let first = temp.appendingPathComponent("a\\b")
        let second = temp.appendingPathComponent("a_b", isDirectory: true)
        try Data([3]).write(to: first)
        try fm.createDirectory(at: second, withIntermediateDirectories: false)
        try Data([4]).write(to: second.appendingPathComponent("child"))
        let drive = temp.appendingPathComponent("C:invalid")
        try Data([5]).write(to: drive)

        let result = try FileTransferStaging(rootURL: temp.appendingPathComponent("staging"))
            .stageLocalSelection([root, first, second, drive])
        XCTAssertEqual(result.omittedCount, 3)
        XCTAssertEqual(result.files.map(\.fileName), [root.lastPathComponent, root.lastPathComponent + "\\" + fit, "a_b"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(result.files.last).sourceURL), Data([3]))
    }

    func testDirectoryFailuresRejectTheWholeSelection() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let ordinary = temp.appendingPathComponent("ordinary")
        try Data([1]).write(to: ordinary)
        let directory = temp.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let outside = temp.appendingPathComponent("outside")
        try Data([2]).write(to: outside)

        let staging = FileTransferStaging(rootURL: temp.appendingPathComponent("staging"))
        XCTAssertThrowsError(try staging.stageLocalSelection([ordinary, directory]) { _, _, _ in nil })
        XCTAssertThrowsError(try staging.stageLocalSelection([ordinary, directory]) { url, _, reportError in
            _ = reportError(url, CocoaError(.fileReadNoPermission))
            return StagingTestEnumerator(nil)
        })
        XCTAssertThrowsError(try staging.stageLocalSelection([ordinary, directory]) { physicalRoot, _, _ in
            StagingTestEnumerator(physicalRoot.appendingPathComponent("missing"))
        })
        XCTAssertThrowsError(try staging.stageLocalSelection([ordinary, directory]) { physicalRoot, _, _ in
            StagingTestEnumerator(physicalRoot.deletingLastPathComponent().appendingPathComponent(outside.lastPathComponent))
        })
    }

    /// T-M4: only folders end in `\` on the wire; a macOS file named `a\` becomes `a_`.
    func testWireNameMarksOnlyFoldersAndSanitizesTrailingBackslash() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("W", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("d"), withIntermediateDirectories: true)
        try Data("1".utf8).write(to: root.appendingPathComponent("a\\"))
        let loose = temp.appendingPathComponent("b\\")
        try Data("2".utf8).write(to: loose)

        let files = try FileTransferStaging(rootURL: temp.appendingPathComponent("staging")).stageLocalFilesForRemotePaste([root, loose])

        XCTAssertEqual(Set(files.map(\.wireName)), ["W\\", "W\\d\\", "W\\a_", "b_"])
        for file in files {
            XCTAssertEqual(file.wireName.hasSuffix("\\"), file.isDirectory, file.wireName)
        }
    }

    /// T-S3: backslashes in any Mac path component become `_`, so only the folder marker ends in `\`.
    func testWireNameSanitizesBackslashesInEveryMacComponent() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let dir = temp.appendingPathComponent("x\\", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: dir.appendingPathComponent("f.txt"))
        let mid = temp.appendingPathComponent("a\\b.txt")
        try Data("2".utf8).write(to: mid)
        let leading = temp.appendingPathComponent("\\c")
        try Data("3".utf8).write(to: leading)

        let files = try FileTransferStaging(rootURL: temp.appendingPathComponent("staging"))
            .stageLocalFilesForRemotePaste([dir, mid, leading])

        XCTAssertEqual(Set(files.map(\.wireName)), ["x_\\", "x_\\f.txt", "a_b.txt", "_c"])
        for file in files {
            XCTAssertEqual(file.wireName.hasSuffix("\\"), file.isDirectory, file.wireName)
        }
    }

    func testNormalizesRemoteDropDestinationToNFC() throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let staging = FileTransferStaging(rootURL: temp)
        let decomposedName = "한글.txt".decomposedStringWithCanonicalMapping
        let destination = try staging.createRemoteDropFile(fileName: decomposedName)
        try destination.handle.close()

        XCTAssertEqual(FileNameNormalization.normalizeForTransfer(destination.url.lastPathComponent), "한글.txt")
        // The stored entry is NFC too (Darwin `URL.path` reports NFD, so read the directory).
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: temp.path).map { $0.unicodeScalars.map(\.value) },
            ["한글.txt".unicodeScalars.map(\.value)]
        )
    }

    func testPayloadRoundTrip() throws {
        let staged = StagedFile(
            sourceURL: URL(fileURLWithPath: "/tmp/a.txt"),
            stagedURL: URL(fileURLWithPath: "/tmp/staged/a.txt"),
            fileName: "a.txt",
            byteCount: 10
        )

        let payload = try RDPFileListPayload.encode([staged])
        let decoded = try RDPFileListPayload.decode(payload)

        XCTAssertEqual(decoded, [
            RDPFileListEntry(
                fileName: "a.txt",
                byteCount: 10,
                localURL: URL(fileURLWithPath: "/tmp/staged/a.txt")
            )
        ])
    }
}

private final class StagingTestEnumerator: FileManager.DirectoryEnumerator {
    private var url: URL?

    init(_ url: URL?) {
        self.url = url
        super.init()
    }

    override func nextObject() -> Any? {
        defer { url = nil }
        return url
    }
}
