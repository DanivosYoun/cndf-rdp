import AppKit
import ClipboardBridge
import FileTransferStaging
import Foundation
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

    // MARK: Chunk length (design D-5, INV-C1)

    /// A manager whose range replies come from `replies` in order.
    private func scriptedManager(_ replies: [Data]) -> (RDPRemoteFileDownloadManager, () -> [UInt32]) {
        let lock = NSLock()
        var queue = replies
        var lengths: [UInt32] = []
        let manager = RDPRemoteFileDownloadManager(staging: staging) { _, _, _, _ in }
        manager.requestRange = { [weak manager] stream, _, _, length in
            lock.lock()
            lengths.append(length)
            let reply = queue.isEmpty ? Data() : queue.removeFirst()
            lock.unlock()
            manager?.receive(streamId: stream, data: reply)
        }
        return (manager, { lock.lock(); defer { lock.unlock() }; return lengths })
    }

    // T-C1
    func testEmptyChunkFailsTheListAndLeavesNothing() throws {
        let (manager, _) = scriptedManager([Data()])
        XCTAssertThrowsError(try manager.materialize([RDPFileListEntry(fileName: "a.txt", byteCount: 3, localURL: nil)])) {
            XCTAssertEqual($0 as? RDPRemoteFileDownloadManager.ChunkError, .truncated)
        }
        XCTAssertEqual(stagedNames, [])
    }

    // T-C2
    func testEmptyChunkAfterAShortChunkFailsTheList() throws {
        let (manager, lengths) = scriptedManager([Data("ab".utf8), Data()])
        XCTAssertThrowsError(try manager.materialize([RDPFileListEntry(fileName: "a.txt", byteCount: 3, localURL: nil)])) {
            XCTAssertEqual($0 as? RDPRemoteFileDownloadManager.ChunkError, .truncated)
        }
        XCTAssertEqual(lengths(), [3, 1])
        XCTAssertEqual(stagedNames, [])
    }

    // T-C3
    func testShortNonEmptyChunksAreAccepted() throws {
        let (manager, lengths) = scriptedManager([Data("a".utf8), Data("b".utf8), Data("c".utf8)])
        let urls = try manager.materialize([RDPFileListEntry(fileName: "a.txt", byteCount: 3, localURL: nil)])
        XCTAssertEqual(lengths(), [3, 2, 1])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), Data("abc".utf8))
    }

    // T-C4
    func testOverlongChunkFailsTheListAndWritesNothing() throws {
        let (manager, _) = scriptedManager([Data("abcd".utf8)])
        XCTAssertThrowsError(try manager.materialize([RDPFileListEntry(fileName: "a.txt", byteCount: 3, localURL: nil)])) {
            XCTAssertEqual($0 as? RDPRemoteFileDownloadManager.ChunkError, .overlong)
        }
        XCTAssertEqual(stagedNames, [])
    }

    // S-G1 (design D-G4, INV-G5): the stream is registered before the freshness check, so a
    // newer list's cancel that lands right after the check fails it, and the reply the server
    // sends anyway ("B", the new copy's bytes) is not written.
    func testCancelAfterTheCheckFailsTheRegisteredRangeAndWritesNothing() throws {
        let manager = RDPRemoteFileDownloadManager(staging: staging) { _, _, _, _ in }
        manager.requestRange = { [weak manager] stream, _, offset, _ in
            manager?.receive(streamId: stream, data: Data(offset == 0 ? "A".utf8 : "B".utf8))
        }
        var checks = 0
        XCTAssertThrowsError(try manager.materialize(
            [RDPFileListEntry(fileName: "a.txt", byteCount: 2, localURL: nil)],
            chunkSize: 1,
            shouldContinue: {
                checks += 1
                if checks == 2 { manager.cancelOutstanding() }
                return true
            }
        )) {
            XCTAssertEqual(
                $0 as? RDPSessionError,
                .bridgeRejectedOperation(3)
            )
        }
        XCTAssertEqual(checks, 2)
        XCTAssertEqual(stagedNames, [])
    }

    // MARK: IronRDP session (stub)

    private func connectStub(_ server: RangeServer, logFileURL: URL? = nil) throws -> (IronRDPSession, LogRecorder, NSPasteboard) {
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
            RDPConnectionOptions(host: "localhost", logFileURL: logFileURL, pasteboardName: board.name.rawValue),
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

    // S-G4 (design D-G7, INV-T3): a result that finishes as the session goes is removed.
    func testIronRDPResultFinishedAsTheSessionGoesIsRemoved() throws {
        let server = RangeServer(answer: true)
        var session: IronRDPSession?
        let board: NSPasteboard
        do {
            let (created, _, createdBoard) = try connectStub(server)
            session = created
            board = createdBoard
        }
        defer { board.releaseGlobally() }
        let finished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        session?.materializeRemoteFileList = { manager, entries, shouldContinue in
            let urls = try manager.materialize(entries, shouldContinue: shouldContinue)
            finished.signal()
            release.wait()
            return urls
        }

        sendIronList([("deinit.txt", 0)], to: try XCTUnwrap(session))
        XCTAssertTrue(waitUntil { finished.wait(timeout: .now()) == .success })
        XCTAssertEqual(stagedNames, ["deinit.txt"])
        weak var released = session
        session = nil
        XCTAssertNil(released)
        release.signal()

        XCTAssertTrue(waitUntil(timeout: 2) { self.stagedNames.isEmpty })
        XCTAssertEqual(board.string(forType: .string), "unchanged")
    }

    // MARK: Session log file (design D-T3, INV-LOG1)

    private var logURL: URL { root.appendingPathComponent("session.log") }

    private func logLines(containing text: String) -> Int {
        ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0.contains(text) }.count
    }

    /// Holds the materialization until `release`, then lets it run, so it ends after the test
    /// has closed or cut the connection.
    private func holdMaterialization(
        _ set: (@escaping (RDPRemoteFileDownloadManager, [RDPFileListEntry], () -> Bool) throws -> [URL]) -> Void
    ) -> (started: DispatchSemaphore, release: DispatchSemaphore) {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        set { manager, entries, shouldContinue in
            started.signal()
            release.wait()
            return try manager.materialize(entries, shouldContinue: shouldContinue)
        }
        return (started, release)
    }

    // L-1 (IronRDP close): the view detaches the delegate, disconnects and lets the session go
    // while a materialization runs. Its failure still writes one line to the session log file.
    func testIronRDPFailureAfterCloseWritesOneLogFileLine() throws {
        let server = RangeServer(answer: true)
        var session: IronRDPSession?
        let recorder: LogRecorder
        let board: NSPasteboard
        do {
            let (created, createdRecorder, createdBoard) = try connectStub(server, logFileURL: logURL)
            session = created
            recorder = createdRecorder
            board = createdBoard
        }
        defer { board.releaseGlobally() }
        let held = holdMaterialization { session?.materializeRemoteFileList = $0 }

        sendIronList([("secret-name.txt", 3)], to: try XCTUnwrap(session))
        XCTAssertTrue(waitUntil { held.started.wait(timeout: .now()) == .success })
        session?.delegate = nil
        try session?.disconnect()
        weak var released = session
        session = nil
        XCTAssertNil(released)
        held.release.signal()

        XCTAssertTrue(waitUntil(timeout: 2) { self.logLines(containing: "Remote file materialization failed:") == 1 })
        _ = waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(logLines(containing: "Remote file materialization"), 1)
        XCTAssertEqual(logLines(containing: "secret-name"), 0)
        XCTAssertEqual(recorder.count(prefix: "Remote file materialization failed:"), 0)
        XCTAssertEqual(stagedNames, [])
    }

    // L-2 (IronRDP cut): the server ends the connection while a materialization runs. One line
    // goes to the file and one to the delegate that is still attached.
    func testIronRDPFailureAfterServerDisconnectWritesOneLineToEach() throws {
        let server = RangeServer(answer: true)
        let (session, recorder, board) = try connectStub(server, logFileURL: logURL)
        defer { try? session.disconnect(); board.releaseGlobally() }
        let held = holdMaterialization { session.materializeRemoteFileList = $0 }

        sendIronList([("A.txt", 3)], to: session)
        XCTAssertTrue(waitUntil { held.started.wait(timeout: .now()) == .success })
        session.callbacks.disconnect?(1, CNDF_IRON_DISCONNECT_SERVER, 0, session.callbacks.context)
        held.release.signal()

        XCTAssertTrue(waitUntil(timeout: 2) { recorder.count(prefix: "Remote file materialization failed:") == 1 })
        XCTAssertTrue(waitUntil(timeout: 2) { self.logLines(containing: "Remote file materialization failed:") == 1 })
        _ = waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(logLines(containing: "Remote file materialization"), 1)
        XCTAssertEqual(recorder.count(prefix: "Remote file materialization failed:"), 1)
        XCTAssertEqual(stagedNames, [])
    }

    // L-6 (IronRDP cut): shutdown in response to disconnect leaves the file log and staging
    // cleanup independent of the main queue.
    func testIronRDPFailureAfterDisconnectAndDelegateDetachFinishesWithoutMainQueue() throws {
        XCTAssertTrue(Thread.isMainThread)
        let server = RangeServer(answer: true)
        var session: IronRDPSession?
        let recorder: LogRecorder
        let board: NSPasteboard
        do {
            let (created, createdRecorder, createdBoard) = try connectStub(server, logFileURL: logURL)
            session = created
            recorder = createdRecorder
            board = createdBoard
        }
        defer { board.releaseGlobally() }
        let held = holdMaterialization { session?.materializeRemoteFileList = $0 }

        sendIronList([("A.txt", 3)], to: try XCTUnwrap(session))
        let started = waitUntil { held.started.wait(timeout: .now()) == .success }
        guard started else {
            held.release.signal()
            return XCTFail("Materialization did not start")
        }
        let callbacks = try XCTUnwrap(session?.callbacks)
        callbacks.disconnect?(1, CNDF_IRON_DISCONNECT_SERVER, 0, callbacks.context)
        session?.delegate = nil
        held.release.signal()

        let failure = "Remote file materialization failed:"
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline,
              !stagedNames.isEmpty || logLines(containing: failure) != 1 {
            Thread.sleep(forTimeInterval: 0.005)
        }
        XCTAssertEqual(stagedNames, [])
        XCTAssertEqual(logLines(containing: failure), 1)

        weak var released = session
        session = nil
        XCTAssertNil(released)

        _ = waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(recorder.count(prefix: failure), 0)
        XCTAssertEqual(logLines(containing: "Remote file materialization"), 1)
        XCTAssertEqual(stagedNames, [])
    }

    /// Lets a materialization finish, then holds its result until `release`.
    private func holdResult(
        _ set: (@escaping (RDPRemoteFileDownloadManager, [RDPFileListEntry], () -> Bool) throws -> [URL]) -> Void
    ) -> (finished: DispatchSemaphore, release: DispatchSemaphore) {
        let finished = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        set { manager, entries, shouldContinue in
            let urls = try manager.materialize(entries, shouldContinue: shouldContinue)
            finished.signal()
            release.wait()
            return urls
        }
        return (finished, release)
    }

    // L-4 (IronRDP): a result that finished as the session went, or as the connection ended,
    // is removed with one `discarded` line.
    func testIronRDPResultAfterTheConnectionEndedWritesOneDiscardedLine() throws {
        for releaseSession in [true, false] {
            try? FileManager.default.removeItem(at: logURL)
            let server = RangeServer(answer: true)
            var session: IronRDPSession?
            let board: NSPasteboard
            do {
                let (created, _, createdBoard) = try connectStub(server, logFileURL: logURL)
                session = created
                board = createdBoard
            }
            defer { board.releaseGlobally() }
            let held = holdResult { session?.materializeRemoteFileList = $0 }

            // Zero bytes: no range request, so the replaced closure needs no range server.
            sendIronList([("done.txt", 0)], to: try XCTUnwrap(session))
            XCTAssertTrue(waitUntil { held.finished.wait(timeout: .now()) == .success })
            XCTAssertEqual(stagedNames, ["done.txt"])
            if releaseSession {
                weak var released = session
                session = nil
                XCTAssertNil(released)
            } else {
                try session?.disconnect()
            }
            held.release.signal()

            XCTAssertTrue(waitUntil(timeout: 2) { self.stagedNames.isEmpty }, "\(releaseSession)")
            XCTAssertTrue(waitUntil(timeout: 2) {
                self.logLines(containing: "Remote file materialization discarded: the connection ended.") == 1
            }, "\(releaseSession)")
            _ = waitUntil(timeout: 0.3) { false }
            XCTAssertEqual(logLines(containing: "Remote file materialization"), 1, "\(releaseSession)")
            XCTAssertEqual(board.string(forType: .string), "unchanged", "\(releaseSession)")
            session = nil
        }
    }

    func testMaterializationLogsUseOnlySafeReasons() throws {
        let marker = "private-name-marker"
        let path = URL(fileURLWithPath: "/private/" + marker)
        let failures: [(Error, String)] = [
            (FileTransferStagingError.unableToCreateRemoteDropFile(path, errno: EACCES), "staging-create errno=\(EACCES)"),
            (NSError(domain: marker, code: 1, userInfo: [NSLocalizedDescriptionKey: marker]), "unknown")
        ]
        for (failure, reason) in failures {
            for detached in [false, true] {
                try? FileManager.default.removeItem(at: logURL)
                let server = RangeServer()
                let prefix = "Remote file materialization failed:"
                let message = "\(prefix) reason=\(reason)"
                let (session, recorder, board) = try connectStub(server, logFileURL: logURL)
                defer { try? session.disconnect(); board.releaseGlobally() }
                let changeCount = board.changeCount
                session.materializeRemoteFileList = { _, _, _ in throw failure }
                if detached { session.delegate = nil }
                sendIronList([("fixture.txt", 3)], to: session)
                XCTAssertTrue(waitUntil { self.logLines(containing: prefix) == 1 })
                if !detached { XCTAssertTrue(waitUntil { recorder.count(prefix: prefix) == 1 }) }
                XCTAssertEqual(recorder.count(prefix: message), detached ? 0 : 1)
                XCTAssertEqual(recorder.count(prefix: prefix), detached ? 0 : 1)
                XCTAssertEqual(board.changeCount, changeCount)

                XCTAssertEqual(logLines(containing: message), 1)
                XCTAssertEqual(logLines(containing: marker), 0)
                XCTAssertTrue(stagedNames.isEmpty)
            }
        }
    }

    // L-5 (IronRDP): a failure on a live connection is one line in the file, not two.
    func testIronRDPFailureOnALiveConnectionWritesOneLine() throws {
        let server = RangeServer()
        let (session, recorder, board) = try connectStub(server, logFileURL: logURL)
        defer { try? session.disconnect(); board.releaseGlobally() }

        sendIronList([("A.txt", 3)], to: session)
        XCTAssertTrue(waitUntil { server.requests.count == 1 })
        let stream = try XCTUnwrap(server.requests.first?.stream)
        session.callbacks.remote_file_contents?(1, stream, false, nil, 0, session.callbacks.context)

        XCTAssertTrue(waitUntil(timeout: 2) { recorder.count(prefix: "Remote file materialization failed:") == 1 })
        _ = waitUntil(timeout: 0.3) { false }
        XCTAssertEqual(logLines(containing: "Remote file materialization failed:"), 1)
        XCTAssertEqual(recorder.count(prefix: "Remote file materialization failed:"), 1)
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
