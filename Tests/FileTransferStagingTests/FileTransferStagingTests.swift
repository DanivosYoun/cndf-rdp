import FileTransferStaging
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
        XCTAssertEqual(files[0].stagedURL, source)
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

    /// T-M3: a package inside a folder yields no entry at all.
    func testPackageInsideFolderProducesNoEntries() throws {
        let temp = try makeTemp()
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = temp.appendingPathComponent("P", isDirectory: true)
        let app = root.appendingPathComponent("X.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data("1".utf8).write(to: app.appendingPathComponent("Info.plist"))

        let files = try FileTransferStaging(rootURL: temp.appendingPathComponent("staging")).stageLocalFilesForRemotePaste([root])

        XCTAssertEqual(files.map(\.fileName), ["P"])
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
