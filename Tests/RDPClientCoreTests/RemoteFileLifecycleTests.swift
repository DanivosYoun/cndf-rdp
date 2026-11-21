import AppKit
import ClipboardBridge
import FileTransferStaging
import Foundation
import FreeRDPBridge
import IronRDPBridge
import XCTest
@testable import RDPClientCore

/// Design K3 (D2, D3): a materialization ends when the remote clipboard changes or the
/// connection ends, removes what it made when it will not reach the pasteboard, and never
/// overwrites a newer local copy. IronRDP session tests are "stub" tests (see `IronRDPSessionTests`).
final class RemoteFileLifecycleTests: XCTestCase {
    private var root: URL!
    private var staging: FileTransferStaging!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-lifecycle-\(UUID().uuidString)", isDirectory: true)
        staging = FileTransferStaging(rootURL: root.appendingPathComponent("staging", isDirectory: true))
        try staging.prepare()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var stagedNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: staging.rootURL.path)) ?? [])
            .map(\.precomposedStringWithCanonicalMapping).sorted()
    }

    // MARK: Manager

    func testCancelOutstandingFailsTheWaitingRangeAndRemovesThePartialFile() throws {
        let server = RangeServer()
        let manager = server.manager(staging: staging)
        let failed = expectation(description: "materialize failed")
        DispatchQueue.global().async {
            do {
                _ = try manager.materialize([RDPFileListEntry(fileName: "a.txt", byteCount: 3, localURL: nil)])
                XCTFail("materialize succeeded")
            } catch {}
            failed.fulfill()
        }
        XCTAssertTrue(waitUntil { server.requests.count == 1 })
        XCTAssertEqual(stagedNames, ["a.txt"])
        manager.cancelOutstanding()
        wait(for: [failed], timeout: 2)
        XCTAssertEqual(stagedNames, [])
    }

    func testFolderEntriesRequestNoRangesAndFilesKeepTheirListIndex() throws {
        let server = RangeServer(answer: true)
        let manager = server.manager(staging: staging)
        let urls = try manager.materialize([
            RDPFileListEntry(fileName: "폴더W", byteCount: 0, localURL: nil, isDirectory: true),
            RDPFileListEntry(fileName: "폴더W\\빈폴더", byteCount: 0, localURL: nil, isDirectory: true),
            RDPFileListEntry(fileName: "폴더W\\a.txt", byteCount: 3, localURL: nil),
        ])
        XCTAssertEqual(server.requests.map(\.index), [2])
        XCTAssertEqual(urls.map { $0.lastPathComponent.precomposedStringWithCanonicalMapping }, ["폴더W"])
        XCTAssertEqual(stagedNames, ["폴더W"])
        XCTAssertEqual(try Data(contentsOf: urls[0].appendingPathComponent("a.txt")), Data("abc".utf8))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: urls[0].appendingPathComponent("빈폴더").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testStoppingBetweenChunksRemovesEverythingThisListMade() throws {
        let server = RangeServer(answer: true)
        let manager = server.manager(staging: staging)
        var checks = 0
        XCTAssertThrowsError(try manager.materialize(
            [
                RDPFileListEntry(fileName: "first.txt", byteCount: 1, localURL: nil),
                RDPFileListEntry(fileName: "d\\second.txt", byteCount: 1, localURL: nil),
            ],
            shouldContinue: { checks += 1; return checks < 2 }
        ))
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(stagedNames, [])
    }

    func testDiscardRemovesOnlyItemsDirectlyUnderTheStagingRoot() throws {
        let server = RangeServer(answer: true)
        let manager = server.manager(staging: staging)
        let urls = try manager.materialize([RDPFileListEntry(fileName: "d\\x.txt", byteCount: 3, localURL: nil)])
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep".utf8).write(to: outside)
        manager.discard([outside])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        manager.discard(urls)
        XCTAssertEqual(stagedNames, [])
    }

    // MARK: FreeRDP session

    private func freeRDPSession(_ server: RangeServer) throws -> (RDPSession, FakePasteboard, FakeSink, LogRecorder) {
        let session = try RDPSession(staging: staging)
        let pasteboard = FakePasteboard()
        let sink = FakeSink()
        session.clipboardCoordinator = ClipboardCoordinator(pasteboard: pasteboard, remoteSink: sink)
        session.remoteFileDownloadManager = server.manager(staging: staging)
        let recorder = LogRecorder()
        session.delegate = recorder
        return (session, pasteboard, sink, recorder)
    }

    private func sendFreeRDPList(_ files: [(String, UInt64)], to session: RDPSession) {
        let data = descriptor(files)
        data.withUnsafeBytes { bytes in
            session.callbacks.remoteFileList?(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, session.callbacks.context)
        }
    }

    // S1: L1 is waiting on a range when L2 arrives. L1 fails, only L2 reaches the pasteboard,
    // and one copy is staged.
    func testFreeRDPNewListEndsTheWaitingMaterialization() throws {
        let server = RangeServer()
        let (session, pasteboard, _, recorder) = try freeRDPSession(server)

        sendFreeRDPList([("a.txt", 3)], to: session)
        XCTAssertTrue(waitUntil { server.requests.count == 1 })
        server.answering = true
        sendFreeRDPList([("a.txt", 3)], to: session)

        XCTAssertTrue(waitUntil { pasteboard.fileURLs?.count == 1 })
        XCTAssertEqual(recorder.count(prefix: "Remote file materialization failed:"), 1)
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertEqual(stagedNames, ["a.txt"])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(pasteboard.fileURLs?.first)), Data("abc".utf8))
    }

    // S1: two lists back to back. Only the newest one is materialized.
    func testFreeRDPDuplicateListsBackToBackMaterializeOnce() throws {
        let server = RangeServer(answer: true)
        let (session, pasteboard, _, recorder) = try freeRDPSession(server)

        sendFreeRDPList([("a.txt", 3)], to: session)
        sendFreeRDPList([("a.txt", 3)], to: session)

        XCTAssertTrue(waitUntil { pasteboard.fileURLs?.count == 1 })
        _ = waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(stagedNames, ["a.txt"])
        XCTAssertEqual(recorder.count(prefix: "Remote files materialized"), 1)
    }

    // S1: a list that finished after newer server text is not written and its copy is removed.
    func testFreeRDPResultFinishedAfterNewerTextIsDiscarded() throws {
        let server = RangeServer(answer: true)
        let (session, pasteboard, _, recorder) = try freeRDPSession(server)
        let finished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        session.materializeRemoteFileList = { manager, entries, shouldContinue in
            let urls = try manager.materialize(entries, shouldContinue: shouldContinue)
            finished.signal()
            release.wait()
            return urls
        }

        sendFreeRDPList([("a.txt", 3)], to: session)
        XCTAssertTrue(waitUntil { finished.wait(timeout: .now()) == .success })
        XCTAssertEqual(stagedNames, ["a.txt"])
        Array("T".utf8).withUnsafeBufferPointer {
            session.callbacks.remoteText?($0.baseAddress, $0.count, session.callbacks.context)
        }
        release.signal()

        XCTAssertTrue(waitUntil { recorder.count(prefix: "Remote file materialization superseded") == 1 })
        XCTAssertEqual(pasteboard.text, "T")
        XCTAssertEqual(stagedNames, [])
    }

    // S3 (FreeRDP): disconnect while a range waits ends it at once and leaves nothing staged.
    func testFreeRDPDisconnectEndsTheWaitingMaterialization() throws {
        for viaCallback in [false, true] {
            let server = RangeServer()
            let (session, pasteboard, _, recorder) = try freeRDPSession(server)
            sendFreeRDPList([("a.txt", 3)], to: session)
            XCTAssertTrue(waitUntil { server.requests.count == 1 })
            if viaCallback {
                session.callbacks.disconnect?(RDPBridgeDisconnectServer, 0, session.callbacks.context)
            } else {
                try? session.disconnect()
            }
            XCTAssertTrue(waitUntil(timeout: 2) { recorder.count(prefix: "Remote file materialization failed:") == 1 }, "\(viaCallback)")
            XCTAssertEqual(stagedNames, [])
            XCTAssertNil(pasteboard.fileURLs)
        }
    }

    // S4 (6b): a local copy made while A materializes wins even after a poll ran.
    func testFreeRDPLocalCopyDuringMaterializationWins() throws {
        let server = RangeServer()
        let (session, pasteboard, sink, recorder) = try freeRDPSession(server)
        sendFreeRDPList([("a.txt", 3)], to: session)
        XCTAssertTrue(waitUntil { server.requests.count == 1 })

        pasteboard.copyLocally("local")
        try session.pollLocalClipboard()
        server.answerWaiting()

        XCTAssertTrue(waitUntil { recorder.count(prefix: "Remote file materialization discarded:") == 1 })
        XCTAssertEqual(pasteboard.text, "local")
        XCTAssertNil(pasteboard.fileURLs)
        XCTAssertEqual(stagedNames, [])
        XCTAssertEqual(sink.sentText, ["local"])
        XCTAssertEqual(recorder.count(prefix: "Remote files materialized"), 0)
    }

    // MARK: IronRDP session (stub)

    private func connectStub(_ server: RangeServer) throws -> (IronRDPSession, LogRecorder, NSPasteboard) {
        try skipUnlessStub()
        let board = NSPasteboard.withUniqueName()
        let session = try IronRDPSession(resizeCoordinator: DisplayResizeCoordinator(), certificateTrustTimeout: 5, staging: staging)
        let recorder = LogRecorder()
        session.delegate = recorder
        session.materializeRemoteFileList = { manager, entries, shouldContinue in
            manager.requestRange = server.handler(for: manager)
            return try manager.materialize(entries, shouldContinue: shouldContinue)
        }
        try session.connect(
            RDPConnectionOptions(host: "localhost", pasteboardName: board.name.rawValue),
            initialPointSize: CGSize(width: 800, height: 600),
            scale: 1
        )
        XCTAssertTrue(waitUntil { session.isConnected })
        board.clearContents()
        board.setString("unchanged", forType: .string)
        return (session, recorder, board)
    }

    private func sendIronList(_ files: [(String, UInt64)], to session: IronRDPSession) {
        let names = files.map { Array($0.0.utf8) }
        var pointers: [UnsafeMutableBufferPointer<UInt8>] = names.map { name in
            let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(name.count, 1))
            _ = buffer.initialize(from: name)
            return buffer
        }
        defer { pointers.forEach { $0.deallocate() }; pointers.removeAll() }
        var list = zip(pointers, files).map { buffer, file in
            CNDFIronRemoteFile(name_utf8: UnsafePointer(buffer.baseAddress), name_length: Array(file.0.utf8).count, size: file.1)
        }
        session.callbacks.remote_file_list?(1, &list, list.count, session.callbacks.context)
    }

    private func sendIronText(_ text: String, to session: IronRDPSession) {
        Array(text.utf8).withUnsafeBufferPointer {
            session.callbacks.remote_text?(1, $0.baseAddress, $0.count, session.callbacks.context)
        }
    }

    // S2: new server text while A waits on a range ends A; nothing is left; the text wins.
    func testIronRDPRemoteTextEndsTheWaitingMaterialization() throws {
        let server = RangeServer()
        let (session, recorder, board) = try connectStub(server)
        defer { try? session.disconnect(); board.releaseGlobally() }

        sendIronList([("A.txt", 3)], to: session)
        XCTAssertTrue(waitUntil { server.requests.count == 1 })
        XCTAssertEqual(stagedNames, ["A.txt"])
        sendIronText("T", to: session)

        XCTAssertTrue(waitUntil(timeout: 2) { recorder.count(prefix: "Remote file materialization failed:") == 1 })
        XCTAssertEqual(stagedNames, [])
        XCTAssertTrue(waitUntil { board.string(forType: .string) == "T" })
    }

    // S3 (IronRDP): disconnect while a range waits ends it at once and leaves nothing staged.
    func testIronRDPDisconnectEndsTheWaitingMaterialization() throws {
        let server = RangeServer()
        let (session, recorder, board) = try connectStub(server)
        defer { board.releaseGlobally() }

        sendIronList([("A.txt", 3)], to: session)
        XCTAssertTrue(waitUntil { server.requests.count == 1 })
        XCTAssertEqual(stagedNames, ["A.txt"])
        try session.disconnect()
        XCTAssertTrue(waitUntil(timeout: 2) { self.stagedNames.isEmpty })
        XCTAssertEqual(board.string(forType: .string), "unchanged")
        XCTAssertEqual(recorder.count(prefix: "Remote files materialized"), 0)
    }

    // S5 (6a): a failed range reply with no new list ends A; the pasteboard keeps its value.
    func testIronRDPFailedRangeReplyLeavesNothing() throws {
        let server = RangeServer()
        let (session, recorder, board) = try connectStub(server)
        defer { try? session.disconnect(); board.releaseGlobally() }

        sendIronList([("A.txt", 3)], to: session)
        XCTAssertTrue(waitUntil { server.requests.count == 1 })
        let stream = try XCTUnwrap(server.requests.first?.stream)
        session.callbacks.remote_file_contents?(1, stream, false, nil, 0, session.callbacks.context)

        XCTAssertTrue(waitUntil(timeout: 2) { recorder.count(prefix: "Remote file materialization failed:") == 1 })
        XCTAssertEqual(stagedNames, [])
        XCTAssertEqual(board.string(forType: .string), "unchanged")
    }

    // S6: the backend's trailing "\" marks a folder entry, which becomes a directory.
    func testIronRDPFolderMarkerBuildsADirectoryTree() throws {
        let server = RangeServer(answer: true)
        let (session, _, board) = try connectStub(server)
        defer { try? session.disconnect(); board.releaseGlobally() }

        sendIronList([("폴더W\\", 0), ("폴더W\\빈폴더\\", 0), ("폴더W\\a.txt", 3)], to: session)

        XCTAssertTrue(waitUntil { (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count == 1 })
        let url = try XCTUnwrap((board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first)
        XCTAssertEqual(url.lastPathComponent.precomposedStringWithCanonicalMapping, "폴더W")
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("a.txt")), Data("abc".utf8))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.appendingPathComponent("빈폴더").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(server.requests.map(\.index), [2])
        XCTAssertEqual(stagedNames, ["폴더W"])
    }

    // S4 (IronRDP): a local copy made while A materializes wins.
    func testIronRDPLocalCopyDuringMaterializationWins() throws {
        let server = RangeServer()
        let (session, recorder, board) = try connectStub(server)
        defer { try? session.disconnect(); board.releaseGlobally() }

        sendIronList([("A.txt", 3)], to: session)
        XCTAssertTrue(waitUntil { server.requests.count == 1 })
        board.clearContents()
        board.setString("local", forType: .string)
        server.answerWaiting()

        XCTAssertTrue(waitUntil { recorder.count(prefix: "Remote file materialization discarded:") == 1 })
        XCTAssertEqual(board.string(forType: .string), "local")
        XCTAssertEqual(stagedNames, [])
    }
}

/// Answers or holds range requests for one manager. Answers are the bytes "abc…" cut to length.
private final class RangeServer {
    struct Request { let stream: UInt32; let index: UInt32; let offset: UInt64; let length: UInt32 }
    private let lock = NSLock()
    private var storedRequests: [Request] = []
    private var storedAnswering: Bool
    private weak var waitingManager: RDPRemoteFileDownloadManager?

    init(answer: Bool = false) { storedAnswering = answer }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return storedRequests }
    var answering: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storedAnswering }
        set { lock.lock(); storedAnswering = newValue; lock.unlock() }
    }

    func manager(staging: FileTransferStaging) -> RDPRemoteFileDownloadManager {
        let manager = RDPRemoteFileDownloadManager(staging: staging) { _, _, _, _ in }
        manager.requestRange = handler(for: manager)
        return manager
    }

    func handler(for manager: RDPRemoteFileDownloadManager) -> (UInt32, UInt32, UInt64, UInt32) throws -> Void {
        { [weak self, weak manager] stream, index, offset, length in
            guard let self, let manager else { return }
            self.lock.lock()
            self.storedRequests.append(Request(stream: stream, index: index, offset: offset, length: length))
            let answer = self.storedAnswering
            self.waitingManager = answer ? nil : manager
            self.lock.unlock()
            if answer { manager.receive(streamId: stream, data: Self.bytes(length)) }
        }
    }

    /// Answers the last held request.
    func answerWaiting() {
        lock.lock()
        let manager = waitingManager
        let request = storedRequests.last
        waitingManager = nil
        lock.unlock()
        if let manager, let request { manager.receive(streamId: request.stream, data: Self.bytes(request.length)) }
    }

    private static func bytes(_ length: UInt32) -> Data {
        Data((0..<Int(length)).map { UInt8(ascii: "a") + UInt8($0 % 26) })
    }
}

private final class LogRecorder: RDPSessionDelegate {
    private let lock = NSLock()
    private var logs: [String] = []

    func count(prefix: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return logs.filter { $0.hasPrefix(prefix) }.count
    }

    func rdpSession(_ session: RDPEngineSession, didLog message: String) {
        lock.lock()
        logs.append(message)
        lock.unlock()
    }

    func rdpSession(
        _ session: RDPEngineSession,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool { true }

    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteText text: String) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveFrame frame: RDPFrame) {}
}

private final class FakePasteboard: PasteboardClient {
    private let lock = NSLock()
    private var count = 0
    private var payload: ClipboardPayload?

    var changeCount: Int { lock.lock(); defer { lock.unlock() }; return count }
    var text: String? { if case .text(let text)? = readPayload() { return text }; return nil }
    var fileURLs: [URL]? { if case .fileURLs(let urls)? = readPayload() { return urls }; return nil }

    func copyLocally(_ text: String) { writeText(text) }
    func readPayload() -> ClipboardPayload? { lock.lock(); defer { lock.unlock() }; return payload }
    func writeText(_ text: String) { lock.lock(); payload = .text(text); count += 1; lock.unlock() }
    func writeFileURLs(_ urls: [URL]) { lock.lock(); payload = .fileURLs(urls); count += 1; lock.unlock() }
}

private final class FakeSink: RemoteClipboardSink {
    private(set) var sentText: [String] = []
    func sendLocalText(_ text: String) throws { sentText.append(text) }
    func sendLocalFiles(_ urls: [URL]) throws {}
}

/// A CF_FILEGROUPDESCRIPTORW with `FD_FILESIZE` entries.
private func descriptor(_ files: [(String, UInt64)]) -> Data {
    var data = Data(count: 4 + 592 * files.count)
    func put(_ value: UInt32, _ offset: Int) {
        for byte in 0..<4 { data[offset + byte] = UInt8((value >> (8 * UInt32(byte))) & 0xFF) }
    }
    put(UInt32(files.count), 0)
    for (index, file) in files.enumerated() {
        let base = 4 + 592 * index
        put(0x40, base)
        put(UInt32(file.1 >> 32), base + 64)
        put(UInt32(file.1 & 0xFFFF_FFFF), base + 68)
        for (unit, value) in Array(file.0.utf16).enumerated() {
            data[base + 72 + unit * 2] = UInt8(value & 0xFF)
            data[base + 72 + unit * 2 + 1] = UInt8(value >> 8)
        }
    }
    return data
}
