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
