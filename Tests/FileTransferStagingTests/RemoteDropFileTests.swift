import FileTransferStaging
import XCTest

/// Remote (server-supplied) clipboard file names must never place a file outside the staging root.
/// Every test works inside its own temporary directory; nothing touches the real home folder.
final class RemoteDropFileTests: XCTestCase {
    private var temp: URL!
    private var stagingRoot: URL!
    private var staging: FileTransferStaging!

    override func setUpWithError() throws {
        // temp/a/b/staging so that "../../.." still lands inside temp.
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-drop-\(UUID().uuidString)", isDirectory: true)
        stagingRoot = temp.appendingPathComponent("a/b/staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        staging = FileTransferStaging(rootURL: stagingRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    /// The same sequence `RDPRemoteFileDownloadManager.materialize` runs for one remote file.
    private func drop(_ fileName: String, _ contents: String = "payload") throws -> URL {
        let file = try staging.createRemoteDropFile(fileName: fileName)
        defer { try? file.handle.close() }
        try file.handle.write(contentsOf: Data(contents.utf8))
        return file.url
    }

    private func assertDirectlyUnderRoot(_ url: URL, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(
            url.deletingLastPathComponent().standardizedFileURL.path,
            stagingRoot.standardizedFileURL.path,
            "\(url.path) is not directly under the staging root",
            file: file,
            line: line
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), file: file, line: line)
    }

    /// Every regular file in temp, relative to temp — proves nothing was written elsewhere.
    private func filesOutsideRoot() -> [String] {
        let enumerator = FileManager.default.enumerator(at: temp, includingPropertiesForKeys: nil)
        var result: [String] = []
        let rootPath = stagingRoot.standardizedFileURL.path + "/"
        while let url = enumerator?.nextObject() as? URL {
            let path = url.standardizedFileURL.path
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            if !path.hasPrefix(rootPath) {
                result.append(path)
            }
        }
        return result
    }

    func testDotDotTraversalIntoLaunchAgentsStaysInRoot() throws {
        let launchAgents = temp.appendingPathComponent("LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)

        let url = try drop("../../../LaunchAgents/evil.plist")

        assertDirectlyUnderRoot(url)
        XCTAssertEqual(url.lastPathComponent, ".._.._.._LaunchAgents_evil.plist")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: launchAgents.path), [])
        XCTAssertEqual(filesOutsideRoot(), [])
    }

    func testAbsolutePathStaysInRoot() throws {
        let outside = temp.appendingPathComponent("outside.txt")

        let url = try drop(outside.path)

        assertDirectlyUnderRoot(url)
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(filesOutsideRoot(), [])
    }

    func testBackslashSeparatorsBecomeOneFlatName() throws {
        // A Windows folder copy advertises "Folder\file"; before this fix the backslash was kept
        // literally in a flat file name, now it is replaced the same way as "/".
        let folderEntry = try drop("Folder\\Sub\\report.txt")
        let traversal = try drop("..\\..\\..\\LaunchAgents\\evil.plist")

        assertDirectlyUnderRoot(folderEntry)
        assertDirectlyUnderRoot(traversal)
        XCTAssertEqual(folderEntry.lastPathComponent, "Folder_Sub_report.txt")
        XCTAssertEqual(traversal.lastPathComponent, ".._.._.._LaunchAgents_evil.plist")
        XCTAssertEqual(filesOutsideRoot(), [])
    }

    func testUnicodeSeparatorLookalikesAreLiteralCharactersInRoot() throws {
        // DIVISION SLASH, FRACTION SLASH, FULLWIDTH SOLIDUS / REVERSE SOLIDUS are not path
        // separators on macOS; they must stay a single literal file name inside the root.
        let name = "..\u{2215}..\u{2044}x\u{FF0F}y\u{FF3C}z.txt"

        let url = try drop(name)

        assertDirectlyUnderRoot(url)
        XCTAssertEqual(url.lastPathComponent, name)
        XCTAssertEqual(filesOutsideRoot(), [])
    }

    func testNulAndControlCharactersAreReplaced() throws {
        let url = try drop("a\u{0000}b\nc\u{7F}.txt")

        assertDirectlyUnderRoot(url)
        XCTAssertEqual(url.lastPathComponent, "a_b_c_.txt")
    }

    func testDotNamesAndEmptyNameBecomeUntitled() throws {
        let dot = try drop(".")
        let dotDot = try drop("..")
        let empty = try drop("")

        [dot, dotDot, empty].forEach { assertDirectlyUnderRoot($0) }
        XCTAssertEqual([dot, dotDot, empty].map(\.lastPathComponent), ["untitled", "untitled 1", "untitled 2"])
        XCTAssertEqual(filesOutsideRoot(), [])
    }

    func testLongKoreanNameIsTruncatedToFileSystemLimitKeepingExtensionAndNFC() throws {
        let decomposed = (String(repeating: "한", count: 250) + ".txt").decomposedStringWithCanonicalMapping

        let first = try drop(decomposed)
        let second = try drop(decomposed)

        [first, second].forEach { assertDirectlyUnderRoot($0) }
        XCTAssertNotEqual(first, second)
        // Check the names as stored on disk (Darwin `URL.path` always reports NFD).
        let listed = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path).sorted()
        XCTAssertEqual(listed.count, 2)
        for name in listed {
            XCTAssertLessThanOrEqual(name.utf8.count, 255)
            XCTAssertTrue(name.hasPrefix("한한한"))
            XCTAssertTrue(name.hasSuffix(".txt"))
            XCTAssertEqual(name.unicodeScalars.map(\.value), name.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
        }
        XCTAssertTrue(listed.contains { $0.hasSuffix(" 1.txt") })
    }

    func testDuplicateNamesGetDistinctFilesWithoutOverwriting() throws {
        let first = try drop("report.txt", "first")
        let second = try drop("report.txt", "second")

        XCTAssertEqual(first.lastPathComponent, "report.txt")
        XCTAssertEqual(second.lastPathComponent, "report 1.txt")
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "second")
    }

    func testPlantedDanglingSymlinkIsNotFollowed() throws {
        let outside = temp.appendingPathComponent("outside-target.txt")
        try FileManager.default.createSymbolicLink(
            at: stagingRoot.appendingPathComponent("report.txt"),
            withDestinationURL: outside
        )

        let url = try drop("report.txt")

        assertDirectlyUnderRoot(url)
        XCTAssertEqual(url.lastPathComponent, "report 1.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertEqual(filesOutsideRoot(), [])
    }

    func testPlantedSymlinkToExistingFileIsNotWrittenThrough() throws {
        let outside = temp.appendingPathComponent("outside-existing.txt")
        try "original".write(to: outside, atomically: false, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: stagingRoot.appendingPathComponent("report.txt"),
            withDestinationURL: outside
        )

        let url = try drop("report.txt", "attacker")

        assertDirectlyUnderRoot(url)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "original")
    }

    func testPlantedSymlinkedDirectoryIsNotTraversed() throws {
        let outsideDir = temp.appendingPathComponent("outside-dir", isDirectory: true)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: stagingRoot.appendingPathComponent("sub"),
            withDestinationURL: outsideDir
        )

        let url = try drop("sub/evil.txt")

        assertDirectlyUnderRoot(url)
        XCTAssertEqual(url.lastPathComponent, "sub_evil.txt")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outsideDir.path), [])
    }
}
