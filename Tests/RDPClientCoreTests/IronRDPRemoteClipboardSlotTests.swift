import AppKit
import FileTransferStaging
import Foundation
import IronRDPBridge
import XCTest
@testable import RDPClientCore

/// Design K7 (I6): server clipboard callbacks while main is busy leave at most one queued main
/// block, deliver only the newest value, and drop deliveries whose connection ended.
/// Session tests are "stub" tests (see `IronRDPSessionTests`). The test thread is main, so
/// callbacks fired from the test body all arrive while main is busy.
final class IronRDPRemoteClipboardSlotTests: XCTestCase {
    private static let burst = 1000

    func testSlotQueuesOneDeliveryAndKeepsTheNewestValue() {
        let slot = IronRDPRemoteClipboardSlot<Int>()
        var queued = 0
        for value in 0..<Self.burst where slot.store(value) { queued += 1 }
        XCTAssertEqual(queued, 1)
        XCTAssertEqual(slot.take(), Self.burst - 1)
        XCTAssertNil(slot.take())
        XCTAssertTrue(slot.store(0))
    }

    func testMaterializationQueueRunsOneJobAndKeepsTheNewestWaitingList() {
        let queue = IronRDPRemoteFileMaterializationQueue<Int>()
        XCTAssertTrue(queue.submit(0))
        XCTAssertEqual(queue.next(), 0)
        var workersStarted = 0
        for job in 1...Self.burst where queue.submit(job) { workersStarted += 1 }
        XCTAssertEqual(workersStarted, 0, "a second worker started while one runs")
        XCTAssertEqual(queue.next(), Self.burst)
        XCTAssertNil(queue.next())
        XCTAssertTrue(queue.submit(0), "the stopped worker must let the next list start one")
    }

    // S1
    func testFreshnessAdvancesMonotonicallyAndOnlyTheLastValueIsNewest() {
        let freshness = IronRDPRemoteClipboardFreshness()
        XCTAssertTrue(freshness.isNewest(0))
        var previous: UInt64 = 0
        for _ in 0..<Self.burst {
            let value = freshness.advance()
            XCTAssertGreaterThan(value, previous)
            XCTAssertTrue(freshness.isNewest(value))
            XCTAssertFalse(freshness.isNewest(previous))
            previous = value
        }
    }

    // stub, S2: an older materialization finishing after newer text must not overwrite it, and
    // the list waiting behind it must not start.
    func testOlderMaterializationFinishingAfterNewerTextLeavesTheText() throws {
        let (session, recorder, board) = try connectStub()
        defer { try? session.disconnect(); board.releaseGlobally() }
        let gate = MaterializationGate(holding: "A.txt")
        session.materializeRemoteFileList = gate.materialize

        sendRemoteFile("A.txt", to: session)
        drainMain()
        XCTAssertTrue(waitUntil(timeout: 5) { gate.started == ["A.txt"] })
        sendRemoteFile("B.txt", to: session)
        drainMain()
        sendRemoteText("T", to: session)
        drainMain()
        XCTAssertEqual(board.string(forType: .string), "T")

        gate.release()
        XCTAssertTrue(waitUntil(timeout: 5) { recorder.superseded >= 1 })
        _ = waitUntil(timeout: 0.5) { false }
        drainMain()

        XCTAssertEqual(board.string(forType: .string), "T")
        XCTAssertEqual(recorder.superseded, 1)
        XCTAssertEqual(gate.started, ["A.txt"], "a list older than the newest text started")
        XCTAssertTrue(boardFileNames(board).isEmpty)
    }

    // stub, S3: a newer list waiting behind a held one replaces it on the pasteboard.
    func testNewerListWaitingBehindAHeldMaterializationWins() throws {
        let (session, recorder, board) = try connectStub()
        defer { try? session.disconnect(); board.releaseGlobally() }
        let gate = MaterializationGate(holding: "A.txt")
        session.materializeRemoteFileList = gate.materialize

        sendRemoteFile("A.txt", to: session)
        drainMain()
        XCTAssertTrue(waitUntil(timeout: 5) { gate.started == ["A.txt"] })
        sendRemoteFile("B.txt", to: session)
        drainMain()

        gate.release()
        XCTAssertTrue(waitUntil(timeout: 5) { self.boardFileNames(board) == ["B.txt"] })
        XCTAssertEqual(recorder.superseded, 1)
        XCTAssertEqual(gate.started, ["A.txt", "B.txt"])
    }

    // stub, S4: a callback from an ended generation takes no freshness value.
    func testStaleGenerationCallbackDoesNotAdvanceFreshness() throws {
        let (session, _, board) = try connectStub()
        defer { try? session.disconnect(); board.releaseGlobally() }

        XCTAssertTrue(session.remoteClipboardFreshness.isNewest(0))
        sendRemoteText("stale", to: session, generation: 2)
        sendRemoteFile("stale.txt", to: session, generation: 2)
        XCTAssertTrue(session.remoteClipboardFreshness.isNewest(0))
        sendRemoteText("current", to: session)
        XCTAssertFalse(session.remoteClipboardFreshness.isNewest(0))
        drainMain()
    }

    // stub
    func testRemoteTextBurstWhileMainIsBusyDeliversOnlyTheNewest() throws {
        let (session, recorder, board) = try connectStub()
        defer { try? session.disconnect(); board.releaseGlobally() }

        for index in 0..<Self.burst { sendRemoteText("text-\(index)", to: session) }
        drainMain()

        XCTAssertEqual(recorder.texts, ["text-\(Self.burst - 1)"])
        XCTAssertEqual(session.statistics.remoteClipboardTextsReceived, 1)
        XCTAssertEqual(board.string(forType: .string), "text-\(Self.burst - 1)")
    }

    // stub
    func testRemoteFileListBurstWhileMainIsBusyDeliversAndMaterializesOnlyTheNewest() throws {
        let (session, recorder, board) = try connectStub()
        defer { try? session.disconnect(); board.releaseGlobally() }

        for index in 0..<Self.burst { sendRemoteFile("file-\(index).txt", to: session) }
        drainMain()

        XCTAssertEqual(recorder.files.map(\.fileName), ["file-\(Self.burst - 1).txt"])
        XCTAssertEqual(session.statistics.remoteFilesReceived, 1)
        // The stub has no file to serve, so the one materialization fails.
        XCTAssertTrue(waitUntil(timeout: 5) { recorder.materializationFailures >= 1 })
        _ = waitUntil(timeout: 0.5) { false }
        XCTAssertEqual(recorder.materializationFailures, 1)
    }

    // stub
    func testTextAndFileListShareOneSlotSoTheNewestKindWins() throws {
        let (session, recorder, board) = try connectStub()
        defer { try? session.disconnect(); board.releaseGlobally() }

        sendRemoteText("older", to: session)
        sendRemoteFile("older.txt", to: session)
        sendRemoteText("newest", to: session)
        drainMain()

        XCTAssertEqual(recorder.texts, ["newest"])
        XCTAssertTrue(recorder.files.isEmpty)
    }

    // stub
    func testWaitingDeliveryIsDroppedWhenTheConnectionEnds() throws {
        let (session, recorder, board) = try connectStub()
        defer { board.releaseGlobally() }

        for index in 0..<Self.burst { sendRemoteText("text-\(index)", to: session) }
        try session.disconnect()
        drainMain()

        XCTAssertTrue(recorder.texts.isEmpty)
        XCTAssertNotEqual(board.string(forType: .string), "text-\(Self.burst - 1)")
    }

    private func connectStub() throws -> (IronRDPSession, SlotRecorder, NSPasteboard) {
        try skipUnlessStub()
        let board = NSPasteboard.withUniqueName()
        let session = try IronRDPSession()
        let recorder = SlotRecorder()
        session.delegate = recorder
        try session.connect(
            RDPConnectionOptions(host: "localhost", pasteboardName: board.name.rawValue),
            initialPointSize: CGSize(width: 800, height: 600),
            scale: 1
        )
        XCTAssertTrue(waitUntil { session.isConnected })
        drainMain()
        return (session, recorder, board)
    }

    private func sendRemoteText(_ text: String, to session: IronRDPSession, generation: UInt64 = 1) {
        Array(text.utf8).withUnsafeBufferPointer {
            session.callbacks.remote_text?(generation, $0.baseAddress, $0.count, session.callbacks.context)
        }
    }

    private func sendRemoteFile(_ name: String, to session: IronRDPSession, generation: UInt64 = 1) {
        Array(name.utf8).withUnsafeBufferPointer { bytes in
            var file = CNDFIronRemoteFile(name_utf8: bytes.baseAddress, name_length: bytes.count, size: 1)
            session.callbacks.remote_file_list?(generation, &file, 1, session.callbacks.context)
        }
    }

    private func boardFileNames(_ board: NSPasteboard) -> [String] {
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return (urls ?? []).map(\.lastPathComponent)
    }

    private func drainMain() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }
}

private final class SlotRecorder: RDPSessionDelegate {
    private let lock = NSLock()
    private var storedTexts: [String] = []
    private var storedFiles: [RDPRemoteFile] = []
    private var storedMaterializationFailures = 0

    var texts: [String] { locked { storedTexts } }
    var files: [RDPRemoteFile] { locked { storedFiles } }
    private var storedSuperseded = 0
    var materializationFailures: Int { locked { storedMaterializationFailures } }
    var superseded: Int { locked { storedSuperseded } }

    func rdpSession(_ session: RDPEngineSession, didLog message: String) {
        if message.hasPrefix("Remote file materialization superseded") { locked { storedSuperseded += 1 } }
        guard message.hasPrefix("Remote file materialization failed:") else { return }
        locked { storedMaterializationFailures += 1 }
    }

    func rdpSession(
        _ session: RDPEngineSession,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool { true }

    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteText text: String) {
        XCTAssertTrue(Thread.isMainThread)
        locked { storedTexts.append(text) }
    }

    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {
        XCTAssertTrue(Thread.isMainThread)
        locked { storedFiles.append(contentsOf: files) }
    }

    func rdpSession(_ session: RDPEngineSession, didReceiveFrame frame: RDPFrame) {}

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

/// Stands in for `RDPRemoteFileDownloadManager.materialize`: records each list it starts, holds
/// the chosen one until `release()`, and returns a real temporary file per entry.
private final class MaterializationGate {
    private let lock = NSLock()
    private let held: String
    private let gate = DispatchSemaphore(value: 0)
    private var storedStarted: [String] = []
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("iron-freshness-\(UUID().uuidString)", isDirectory: true)

    init(holding name: String) { held = name }

    var started: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedStarted
    }

    func release() { gate.signal() }

    func materialize(_ manager: RDPRemoteFileDownloadManager, _ entries: [RDPFileListEntry]) throws -> [URL] {
        let names = entries.map(\.fileName)
        lock.lock()
        storedStarted.append(contentsOf: names)
        lock.unlock()
        if names.contains(held) { gate.wait() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try names.map { name in
            let url = directory.appendingPathComponent(name)
            try Data().write(to: url)
            return url
        }
    }

    deinit { try? FileManager.default.removeItem(at: directory) }
}
