import ClipboardBridge
import Foundation
import XCTest

final class ClipboardCoordinatorTests: XCTestCase {
    func testPollSendsChangedText() throws {
        let pasteboard = MockPasteboard(payload: .text("hello"))
        let sink = MockRemoteSink()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard, remoteSink: sink)

        pasteboard.bump()
        try coordinator.pollLocalPasteboard()

        XCTAssertEqual(sink.sentText, ["hello"])
    }

    func testRemoteTextWritesPasteboardAndSuppressesEcho() throws {
        let pasteboard = MockPasteboard(payload: nil)
        let sink = MockRemoteSink()
        let coordinator = ClipboardCoordinator(pasteboard: pasteboard, remoteSink: sink)

        coordinator.receiveRemoteText("remote")
        try coordinator.pollLocalPasteboard()

        XCTAssertEqual(pasteboard.payload, .text("remote"))
        XCTAssertTrue(sink.sentText.isEmpty)
    }
}

private final class MockPasteboard: PasteboardClient {
    var changeCount: Int = 0
    var payload: ClipboardPayload?

    init(payload: ClipboardPayload?) {
        self.payload = payload
    }

    func bump() {
        changeCount += 1
    }

    func readPayload() -> ClipboardPayload? {
        payload
    }

    func writeText(_ text: String) {
        payload = .text(text)
        bump()
    }

    func writeFileURLs(_ urls: [URL]) {
        payload = .fileURLs(urls)
        bump()
    }
}

private final class MockRemoteSink: RemoteClipboardSink {
    var sentText: [String] = []
    var sentFiles: [[URL]] = []

    func sendLocalText(_ text: String) throws {
        sentText.append(text)
    }

    func sendLocalFiles(_ urls: [URL]) throws {
        sentFiles.append(urls)
    }
}
