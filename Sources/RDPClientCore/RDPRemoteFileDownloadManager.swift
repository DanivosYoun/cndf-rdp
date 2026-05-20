import ClipboardBridge
import FileTransferStaging
import Foundation
import FreeRDPBridge

final class RDPRemoteFileDownloadManager {
    private let session: OpaquePointer
    private let staging: FileTransferStaging
    private let condition = NSCondition()
    private var nextStreamId: UInt32 = 1
    private var responses: [UInt32: Data] = [:]

    init(session: OpaquePointer, staging: FileTransferStaging) {
        self.session = session
        self.staging = staging
    }

    func receive(streamId: UInt32, data: Data) {
        condition.lock()
        responses[streamId] = data
        condition.broadcast()
        condition.unlock()
    }

    func materialize(_ files: [RDPFileListEntry], chunkSize: UInt32 = 1024 * 1024) throws -> [URL] {
        try staging.prepare()

        var urls: [URL] = []
        for (index, file) in files.enumerated() {
            let destination = try staging.makeRemoteDropDestination(fileName: file.fileName)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
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
            urls.append(destination)
        }

        return urls
    }

    private func requestChunk(listIndex: UInt32, offset: UInt64, length: UInt32) throws -> Data {
        let streamId = allocateStreamId()
        let status = rdp_bridge_request_remote_file_range(session, streamId, listIndex, offset, length)
        guard status == RDPBridgeStatusOK else {
            throw RDPSessionError.bridgeRejectedOperation(Int32(status.rawValue))
        }

        return try waitForResponse(streamId: streamId, timeout: 15)
    }

    private func allocateStreamId() -> UInt32 {
        condition.lock()
        defer { condition.unlock() }
        let streamId = nextStreamId
        nextStreamId = nextStreamId == UInt32.max ? 1 : nextStreamId + 1
        return streamId
    }

    private func waitForResponse(streamId: UInt32, timeout: TimeInterval) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }

        while responses[streamId] == nil {
            if !condition.wait(until: deadline) {
                throw RDPSessionError.bridgeRejectedOperation(Int32(RDPBridgeStatusBackendUnavailable.rawValue))
            }
        }

        return responses.removeValue(forKey: streamId) ?? Data()
    }
}
