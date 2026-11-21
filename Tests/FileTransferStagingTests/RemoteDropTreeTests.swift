import Darwin
import FileTransferStaging
import XCTest

/// Remote folder trees (design D1, INV-F1/F3) and removal of staged items (D2, INV-L3).
/// Every test works inside its own temporary directory.
final class RemoteDropTreeTests: XCTestCase {
    private var temp: URL!
    private var stagingRoot: URL!
    private var staging: FileTransferStaging!

    override func setUpWithError() throws {
        // temp/a/b/staging so that "../../.." still lands inside temp.
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-tree-\(UUID().uuidString)", isDirectory: true)
        stagingRoot = temp.appendingPathComponent("a/b/staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        staging = FileTransferStaging(rootURL: stagingRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func write(_ tree: RemoteDropTree, _ path: String, _ contents: String = "payload") throws -> URL {
        let file = try tree.createFile(path: path)
        defer { try? file.handle.close() }
        try file.handle.write(contentsOf: Data(contents.utf8))
        return file.url
    }

    private func realPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func isDirectory(_ url: URL) -> Bool {
        var stats = stat()
        return lstat(url.path, &stats) == 0 && (stats.st_mode & S_IFMT) == S_IFDIR
    }

    private func isRegularFile(_ url: URL) -> Bool {
        var stats = stat()
        return lstat(url.path, &stats) == 0 && (stats.st_mode & S_IFMT) == S_IFREG
    }

    /// Every item under the staging root, relative, sorted; directories end in "/".
    private func listing() throws -> [String] {
        let rootPath = realPath(stagingRoot) + "/"
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: stagingRoot.path))
        return enumerator.compactMap { $0 as? String }.map { relative in
            let url = stagingRoot.appendingPathComponent(relative)
            XCTAssertTrue(realPath(url).hasPrefix(rootPath), "\(relative) escaped the staging root")
            let name = relative.precomposedStringWithCanonicalMapping
            return isDirectory(url) ? name + "/" : name
        }.sorted()
    }

    // MARK: T2 — the six measured entries of c-w2m-folder

    func testMeasuredFolderBecomesOneDirectoryTree() throws {
        let tree = try staging.beginRemoteDrop()
        try tree.createDirectory(path: "폴더W")
        _ = try write(tree, "폴더W\\루트.txt", "root")
        try tree.createDirectory(path: "폴더W\\빈폴더")
        try tree.createDirectory(path: "폴더W\\하위")
        try tree.createDirectory(path: "폴더W\\하위\\깊은")
        _ = try write(tree, "폴더W\\하위\\깊은\\안쪽.txt", "inner")

        XCTAssertEqual(tree.topLevelURLs.map(\.lastPathComponent), ["폴더W"])
        XCTAssertTrue(isDirectory(tree.topLevelURLs[0]))
        XCTAssertEqual(try listing(), [
            "폴더W/", "폴더W/루트.txt", "폴더W/빈폴더/", "폴더W/하위/", "폴더W/하위/깊은/", "폴더W/하위/깊은/안쪽.txt"
        ].sorted())
        let inner = stagingRoot.appendingPathComponent("폴더W/하위/깊은/안쪽.txt")
        XCTAssertEqual(try String(contentsOf: inner, encoding: .utf8), "inner")
        // No zero-byte regular files (the flattened symptom).
        for relative in try listing() where !relative.hasSuffix("/") {
            let size = try FileManager.default.attributesOfItem(atPath: stagingRoot.appendingPathComponent(relative).path)[.size] as? Int
            XCTAssertNotEqual(size, 0, relative)
        }
    }

    func testTopLevelFilesKeepFlatCreationAndFirstSeenOrder() throws {
        let tree = try staging.beginRemoteDrop()
        let single = try write(tree, "a.txt")
        try tree.createDirectory(path: "d")
        _ = try write(tree, "b.txt")
        XCTAssertEqual(tree.topLevelURLs.map(\.lastPathComponent), ["a.txt", "d", "b.txt"])
        XCTAssertEqual(single.deletingLastPathComponent().standardizedFileURL.path, stagingRoot.standardizedFileURL.path)
    }

    // MARK: T5 — a file may come before its parent directory entry

    func testFileBeforeItsParentDirectoryEntryYieldsOneTopLevelItem() throws {
        let tree = try staging.beginRemoteDrop()
        _ = try write(tree, "폴더W\\하위\\안쪽.txt")
        try tree.createDirectory(path: "폴더W\\하위")
        try tree.createDirectory(path: "폴더W")
        XCTAssertEqual(tree.topLevelURLs.map(\.lastPathComponent), ["폴더W"])
        XCTAssertEqual(try listing(), ["폴더W/", "폴더W/하위/", "폴더W/하위/안쪽.txt"])
    }

    // MARK: T3 — collisions with existing staging items, including a planted symlink

    func testExistingFileDirectoryAndSymlinkNamesMoveTheNewTreeToTheNextName() throws {
        let outside = temp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        for existing in ["file", "directory", "symlink"] {
            let name = "폴더W-\(existing)"
            let planted = stagingRoot.appendingPathComponent(name)
            switch existing {
            case "file": try Data("old".utf8).write(to: planted)
            case "directory": try FileManager.default.createDirectory(at: planted, withIntermediateDirectories: false)
            default: try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: outside)
            }

            let tree = try staging.beginRemoteDrop()
            _ = try write(tree, "\(name)\\안쪽.txt", "new")
            XCTAssertEqual(tree.topLevelURLs.map(\.lastPathComponent), ["\(name) 1"], existing)
            XCTAssertTrue(isDirectory(tree.topLevelURLs[0]), existing)
            XCTAssertEqual(
                try String(contentsOf: stagingRoot.appendingPathComponent("\(name) 1/안쪽.txt"), encoding: .utf8),
                "new",
                existing
            )
        }
        // Nothing was written through the symlink, and the planted items are untouched.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
        XCTAssertEqual(try Data(contentsOf: stagingRoot.appendingPathComponent("폴더W-file")), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.appendingPathComponent("폴더W-directory").path), [])
    }

    func testPlantedSymlinkInsideATreeIsNeverFollowed() throws {
        // Two lists with the same folder: the second gets its own top-level directory, so the
        // first one's contents (even a symlink in it) are never reused.
        let outside = temp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let first = try staging.beginRemoteDrop()
        try first.createDirectory(path: "d")
        try FileManager.default.createSymbolicLink(
            at: stagingRoot.appendingPathComponent("d/sub"),
            withDestinationURL: outside
        )

        let second = try staging.beginRemoteDrop()
        _ = try write(second, "d\\sub\\x.txt")
        XCTAssertEqual(second.topLevelURLs.map(\.lastPathComponent), ["d 1"])
        XCTAssertTrue(isDirectory(stagingRoot.appendingPathComponent("d 1/sub")))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testSymlinkPlantedInsideThisListsDirectoryIsNotFollowed() throws {
        let outside = temp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let tree = try staging.beginRemoteDrop()
        try tree.createDirectory(path: "d")
        try FileManager.default.createSymbolicLink(at: stagingRoot.appendingPathComponent("d/sub"), withDestinationURL: outside)

        XCTAssertThrowsError(try tree.createFile(path: "d\\sub\\x.txt"))
        XCTAssertThrowsError(try tree.createDirectory(path: "d\\sub\\inner"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testDuplicateFileNamesInsideOneDirectoryGetTheNextName() throws {
        let tree = try staging.beginRemoteDrop()
        let first = try write(tree, "d\\x.txt", "1")
        let second = try write(tree, "d\\x.txt", "2")
        XCTAssertEqual(first.lastPathComponent, "x.txt")
        XCTAssertEqual(second.lastPathComponent, "x 1.txt")
        XCTAssertEqual(tree.topLevelURLs.count, 1)
    }

    // MARK: T4 — hostile components stay inside the root

    func testHostileComponentsStayInsideTheRoot() throws {
        let hostile = [
            "..\\..\\..\\escape.txt",
            ".\\dot.txt",
            "\\\\lead\\\\empty.txt",
            "a/b\\..\\c/d.txt",
            "nul\u{0}\\x\u{0}.txt",
            "ctl\u{1}\u{7F}\\\u{1B}e.txt",
            "/abs\\olute.txt",
            "..",
        ]
        let tree = try staging.beginRemoteDrop()
        for path in hostile {
            _ = try write(tree, path)
            try tree.createDirectory(path: path + "-d")
        }
        let rootPath = realPath(stagingRoot) + "/"
        for url in tree.topLevelURLs {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, stagingRoot.standardizedFileURL.path)
            XCTAssertTrue(realPath(url).hasPrefix(rootPath), url.path)
        }
        _ = try listing() // asserts every item's realpath is under the root
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("escape.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp.appendingPathComponent("a/escape.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/abs"))
        let direct = try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path)
        XCTAssertFalse(direct.contains { $0.contains("/") || $0 == "." || $0 == ".." || $0.isEmpty })
    }

    // MARK: T6 — removal

    func testRemoveDeletesWholeTreesAndTopLevelFiles() throws {
        let tree = try staging.beginRemoteDrop()
        _ = try write(tree, "폴더W\\하위\\깊은\\안쪽.txt")
        try tree.createDirectory(path: "폴더W\\빈폴더")
        _ = try write(tree, "top.txt")
        let keep = stagingRoot.appendingPathComponent("other.txt")
        try Data("other".utf8).write(to: keep)

        try staging.removeRemoteDropItems(tree.topLevelURLs)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path), ["other.txt"])
    }

    func testRemoveDoesNotFollowSymlinksInsideATree() throws {
        let outside = temp.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let tree = try staging.beginRemoteDrop()
        try tree.createDirectory(path: "d")
        try FileManager.default.createSymbolicLink(at: stagingRoot.appendingPathComponent("d/link"), withDestinationURL: outside)
        let topLink = stagingRoot.appendingPathComponent("toplink")
        try FileManager.default.createSymbolicLink(at: topLink, withDestinationURL: outside)

        try staging.removeRemoteDropItems(tree.topLevelURLs + [topLink])

        XCTAssertEqual(try Data(contentsOf: sentinel), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path), [])
    }

    func testRemoveRefusesTheRootAndAnythingNotDirectlyUnderIt() throws {
        let tree = try staging.beginRemoteDrop()
        _ = try write(tree, "d\\inner.txt")
        let outside = temp.appendingPathComponent("outside.txt")
        try Data("outside".utf8).write(to: outside)
        let refused: [URL] = [
            stagingRoot,
            stagingRoot.appendingPathComponent("."),
            stagingRoot.appendingPathComponent("d/inner.txt"),
            stagingRoot.appendingPathComponent("../sibling"),
            stagingRoot.appendingPathComponent("../../../outside.txt"),
            outside,
            temp,
        ]
        for url in refused {
            XCTAssertThrowsError(try staging.removeRemoteDropItems(tree.topLevelURLs + [url]), url.path) {
                XCTAssertEqual($0 as? FileTransferStagingError, .refusedToRemove(url))
            }
        }
        // A refused batch removes nothing.
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.appendingPathComponent("d/inner.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    // MARK: T-S1 / T-S2 — no held descriptors between calls and immediate registration

    private func openFileDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }

    func testManyTopLevelDirectoriesDoNotHoldDescriptorsBetweenCalls() throws {
        let tree = try staging.beginRemoteDrop()
        let before = try openFileDescriptorCount()
        for index in 0..<300 {
            try tree.createDirectory(path: "d\(index)")
        }
        let after = try openFileDescriptorCount()
        XCTAssertLessThanOrEqual(after - before, 3, "open fds grew from \(before) to \(after)")
        XCTAssertEqual(tree.topLevelURLs.count, 300)
    }

    func testTopLevelDirectoryIsRegisteredEvenWhenOpenFailsWithEMFILE() throws {
        let tree = try staging.beginRemoteDrop()
        var original = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &original), 0)

        let lowestFree = dup(0)
        XCTAssertGreaterThanOrEqual(lowestFree, 0)
        close(lowestFree)

        var caughtError: Error?
        do {
            var tight = rlimit(rlim_cur: rlim_t(lowestFree), rlim_max: original.rlim_max)
            XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &tight), 0)
            defer { _ = setrlimit(RLIMIT_NOFILE, &original) }

            do {
                try tree.createDirectory(path: "d-emfile")
                XCTFail("expected EMFILE when opening newly created top-level directory")
            } catch {
                caughtError = error
            }
        }

        guard case let .unableToCreateRemoteDropFile(url, errno: code)? = caughtError as? FileTransferStagingError else {
            return XCTFail("unexpected error: \(String(describing: caughtError))")
        }
        XCTAssertEqual(code, EMFILE)
        XCTAssertEqual(tree.topLevelURLs, [url])

        try staging.removeRemoteDropItems(tree.topLevelURLs)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stagingRoot.path), [])
    }
}
