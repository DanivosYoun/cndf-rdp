import ClipboardBridge
import FileTransferStaging
import Foundation
import IronRDPBridge

final class IronRDPClipboardSink: RemoteClipboardSink {
    private let staging: FileTransferStaging
    private let withConnection: ((OpaquePointer, UInt64) -> CNDFIronStatus) throws -> Void

    init(staging: FileTransferStaging, withConnection: @escaping ((OpaquePointer, UInt64) -> CNDFIronStatus) throws -> Void) {
        self.staging = staging
        self.withConnection = withConnection
    }

    func sendLocalText(_ text: String) throws {
        try text.withCString { pointer in
            try withConnection { session, generation in
                cndf_iron_clipboard_offer_text(
                    session, generation, UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), strlen(pointer)
                )
            }
        }
    }

    func sendLocalFiles(_ urls: [URL]) throws {
        let stagedFiles = try staging.stageLocalFilesForRemotePaste(urls)
        let paths = stagedFiles.map { strdup($0.stagedURL.path) }
        let names = stagedFiles.map { strdup($0.wireName) }
        defer {
            paths.forEach { free($0) }
            names.forEach { free($0) }
        }

        let files = zip(stagedFiles, zip(paths, names)).map { staged, pointers in
            CNDFIronLocalFile(path: pointers.0.map { UnsafePointer($0) }, name: pointers.1.map { UnsafePointer($0) }, size: staged.byteCount)
        }
        try files.withUnsafeBufferPointer { buffer in
            try withConnection { session, generation in
                cndf_iron_clipboard_offer_files(session, generation, buffer.baseAddress, buffer.count)
            }
        }
    }
}
