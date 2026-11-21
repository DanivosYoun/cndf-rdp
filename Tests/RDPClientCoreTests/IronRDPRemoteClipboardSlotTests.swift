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

    private func sendRemoteText(_ text: String, to session: IronRDPSession) {
        Array(text.utf8).withUnsafeBufferPointer {
            session.callbacks.remote_text?(1, $0.baseAddress, $0.count, session.callbacks.context)
        }
    }

    private func sendRemoteFile(_ name: String, to session: IronRDPSession) {
        Array(name.utf8).withUnsafeBufferPointer { bytes in
            var file = CNDFIronRemoteFile(name_utf8: bytes.baseAddress, name_length: bytes.count, size: 1)
            session.callbacks.remote_file_list?(1, &file, 1, session.callbacks.context)
        }
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
    var materializationFailures: Int { locked { storedMaterializationFailures } }

    func rdpSession(_ session: RDPEngineSession, didLog message: String) {
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
