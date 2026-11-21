import FileTransferStaging
import Foundation
import FreeRDPBridge

final class RDPRemoteFileDownloadManager {
    private let requestRange: (UInt32, UInt32, UInt64, UInt32) throws -> Void
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

    func materialize(_ files: [RDPFileListEntry], chunkSize: UInt32 = 1024 * 1024) throws -> [URL] {
        try staging.prepare()

        var urls: [URL] = []
        for (index, file) in files.enumerated() {
            let destination = try staging.createRemoteDropFile(fileName: file.fileName)
            let handle = destination.handle
            defer { try? handle.close() }

            var offset: UInt64 = 0
            while offset < file.byteCount {
                let remaining = file.byteCount - offset
                let requestLength = UInt32(min(UInt64(chunkSize), remaining))
                let chunk = try requestChunk(
                    listIndex: UInt32(index),
                    offset: offset,
                    length: requestLength
                )
                try handle.write(contentsOf: chunk)
                offset += UInt64(chunk.count)

                if chunk.isEmpty {
                    break
                }
            }
            urls.append(destination.url)
        }

        return urls
    }

    private func requestChunk(listIndex: UInt32, offset: UInt64, length: UInt32) throws -> Data {
        let streamId = allocateStreamId()
        defer {
            condition.lock()
            responses.removeValue(forKey: streamId)
            condition.unlock()
        }

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
        throw RDPSessionError.bridgeRejectedOperation(Int32(RDPBridgeStatusBackendUnavailable.rawValue))
    }
}
