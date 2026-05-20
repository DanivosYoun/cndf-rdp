import Foundation
import FreeRDPBridge
import FileTransferStaging

public protocol RemoteClipboardSink: AnyObject {
    func sendLocalText(_ text: String) throws
    func sendLocalFiles(_ urls: [URL]) throws
}

public final class FreeRDPClipboardBridge: RemoteClipboardSink {
    private let session: OpaquePointer
    private let staging: FileTransferStaging

    public init(session: OpaquePointer, staging: FileTransferStaging) {
        self.session = session
        self.staging = staging
    }

    public func sendLocalText(_ text: String) throws {
        let status = text.withCString { pointer in
            rdp_bridge_send_local_text(session, UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), strlen(pointer))
        }
        try throwIfNeeded(status)
    }

    public func sendLocalFiles(_ urls: [URL]) throws {
        let stagedFiles = try staging.stageLocalFilesForRemotePaste(urls)
        let status = try stagedFiles.withBridgeLocalFiles { files in
            rdp_bridge_send_local_files(session, files.baseAddress, files.count)
        }
        try throwIfNeeded(status)
    }

    private func throwIfNeeded(_ status: RDPBridgeStatus) throws {
        guard status == RDPBridgeStatusOK else {
            throw ClipboardBridgeError.bridgeRejectedOperation(Int32(status.rawValue))
        }
    }
}

private extension Array where Element == StagedFile {
    func withBridgeLocalFiles<T>(_ body: (UnsafeBufferPointer<RDPBridgeLocalFile>) throws -> T) throws -> T {
        let paths = map { strdup($0.stagedURL.path) }
        let names = map { strdup($0.fileName) }
        defer {
            paths.forEach { free($0) }
            names.forEach { free($0) }
        }

        let files = zip(self, zip(paths, names)).map { staged, pointers in
            RDPBridgeLocalFile(path: pointers.0, fileName: pointers.1, size: staged.byteCount)
        }
        return try files.withUnsafeBufferPointer(body)
    }
}
