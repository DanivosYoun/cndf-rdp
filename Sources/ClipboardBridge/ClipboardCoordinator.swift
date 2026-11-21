import Foundation

public final class ClipboardCoordinator {
    private let pasteboard: PasteboardClient
    private let remoteSink: RemoteClipboardSink
    private var lastObservedChangeCount: Int

    public init(pasteboard: PasteboardClient, remoteSink: RemoteClipboardSink) {
        self.pasteboard = pasteboard
        self.remoteSink = remoteSink
        self.lastObservedChangeCount = pasteboard.changeCount
    }

    public func pollLocalPasteboard() throws {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastObservedChangeCount else {
            return
        }

        lastObservedChangeCount = changeCount

        guard let payload = pasteboard.readPayload() else {
            throw ClipboardBridgeError.noSupportedPasteboardContent
        }

        switch payload {
        case .text(let text):
            try remoteSink.sendLocalText(text)
        case .fileURLs(let urls):
            try remoteSink.sendLocalFiles(urls)
        }
    }

    public func receiveRemoteText(_ text: String) {
        pasteboard.writeText(text)
        lastObservedChangeCount = pasteboard.changeCount
    }

    public func receiveRemoteFiles(_ urls: [URL]) {
        pasteboard.writeFileURLs(urls)
        lastObservedChangeCount = pasteboard.changeCount
    }

    /// The pasteboard's change count now. A remote file job takes it when it is queued.
    public var pasteboardChangeCount: Int {
        pasteboard.changeCount
    }

    /// Writes remote files only if the pasteboard has not changed since `changeCount` (design D3,
    /// INV-B1). When it has, nothing is written and the local change stays unobserved, so the
    /// next poll still offers it to the server.
    @discardableResult
    public func receiveRemoteFiles(_ urls: [URL], ifUnchangedSince changeCount: Int) -> Bool {
        guard pasteboard.changeCount == changeCount else {
            return false
        }
        receiveRemoteFiles(urls)
        return true
    }
}
