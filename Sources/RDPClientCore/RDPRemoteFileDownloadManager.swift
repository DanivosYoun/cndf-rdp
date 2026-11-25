import FileTransferStaging
import Foundation

final class RDPRemoteFileDownloadManager {
    /// A range reply that cannot belong to the file the descriptor described (design D-5, INV-C1).
    enum ChunkError: Error, Equatable {
        case truncated
        case overlong
    }


    // Internal and settable so tests can hold or answer range requests.
    var requestRange: (UInt32, UInt32, UInt64, UInt32) throws -> Void
    private let staging: FileTransferStaging
    private let condition = NSCondition()
    private var nextStreamId: UInt32 = 1
    private enum Response {
        case waiting
        case received(Data)
        case failed
    }
    private var responses: [UInt32: Response] = [:]

    init(staging: FileTransferStaging, requestRange: @escaping (UInt32, UInt32, UInt64, UInt32) throws -> Void) {
        self.staging = staging
        self.requestRange = requestRange
    }

    func receive(streamId: UInt32, data: Data) {
        complete(streamId: streamId, with: .received(data))
    }

    func fail(streamId: UInt32) {
        complete(streamId: streamId, with: .failed)
    }

    private func complete(streamId: UInt32, with response: Response) {
        condition.lock()
        defer { condition.unlock() }
        guard case .waiting? = responses[streamId] else { return }
        responses[streamId] = response
        condition.broadcast()
    }

    /// Fails every range request that is still waiting (design D2, INV-L2/L4).
    func cancelOutstanding() {
        condition.lock()
        defer { condition.unlock() }
        for (streamId, response) in responses {
            if case .waiting = response {
                responses[streamId] = .failed
            }
        }
        condition.broadcast()
    }

    /// Removes finished results that will not reach the pasteboard (INV-L3).
    func discard(_ urls: [URL]) {
        try? staging.removeRemoteDropItems(urls)
    }

    /// Creates the list's items under the staging root and fills its files. Folder entries become
    /// directories and request no contents; `listIndex` stays each entry's position in `files`
    /// (INV-F2). Returns the top-level items. `shouldContinue` is checked before each range
    /// request, after its stream is registered (INV-G5). On any error every item this call
    /// created is removed (INV-L3).
    func materialize(
        _ files: [RDPFileListEntry],
        chunkSize: UInt32 = 1024 * 1024,
        shouldContinue: () -> Bool = { true }
    ) throws -> [URL] {
        let tree = try staging.beginRemoteDrop()
        do {
            for (index, file) in files.enumerated() {
                if file.isDirectory {
                    try tree.createDirectory(path: file.fileName)
                    continue
                }
                let destination = try tree.createFile(path: file.fileName)
                let handle = destination.handle
                defer { try? handle.close() }

                var offset: UInt64 = 0
                while offset < file.byteCount {
                    let remaining = file.byteCount - offset
                    let requestLength = UInt32(min(UInt64(chunkSize), remaining))
                    let chunk = try requestChunk(
                        listIndex: UInt32(index),
                        offset: offset,
                        length: requestLength,
                        shouldContinue: shouldContinue
                    )
                    // A reply must be 1…requestLength bytes; anything else fails the whole list (INV-C1).
                    if chunk.isEmpty { throw ChunkError.truncated }
                    if chunk.count > Int(requestLength) { throw ChunkError.overlong }
                    try handle.write(contentsOf: chunk)
                    offset += UInt64(chunk.count)
                }
            }
        } catch {
            discard(tree.topLevelURLs)
            throw error
        }

        return tree.topLevelURLs
    }

    private func requestChunk(
        listIndex: UInt32,
        offset: UInt64,
        length: UInt32,
        shouldContinue: () -> Bool
    ) throws -> Data {
        let streamId = allocateStreamId()
        defer {
            condition.lock()
            responses.removeValue(forKey: streamId)
            condition.unlock()
        }

        // Register, then check, then request (design D-G4): a cancel that comes with a newer list
        // after this check fails the registered stream, so no reply to it reaches the file.
        guard shouldContinue() else { throw CancellationError() }
        try requestRange(streamId, listIndex, offset, length)
        return try waitForResponse(streamId: streamId, timeout: 15)
    }

    private func allocateStreamId() -> UInt32 {
        condition.lock()
        defer { condition.unlock() }
        repeat {
            let streamId = nextStreamId
            nextStreamId = nextStreamId == UInt32.max ? 1 : nextStreamId + 1
            if responses[streamId] == nil {
                responses[streamId] = .waiting
                return streamId
            }
        } while true
    }

    private func waitForResponse(streamId: UInt32, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while case .waiting? = responses[streamId] {
            if !condition.wait(until: deadline) { break }
        }

        if case .received(let data)? = responses[streamId] { return data }
        // Preserve the shared range request error code for unavailable data.
        throw RDPSessionError.bridgeRejectedOperation(3)
    }
}
