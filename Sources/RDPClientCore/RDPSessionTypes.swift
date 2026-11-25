import AppKit
import ClipboardBridge
import FileTransferStaging
import Foundation

/// Connection stage reported when a session fails.
public enum RDPConnectStage: Equatable, Sendable {
    case unknown
    case initial
    case negotiation
    case authentication
    case channelSetup
    case licensing
    case capabilities
    case finalization
    case active
}

public enum RDPSessionError: Error, Equatable, Sendable {
    case unableToCreateBridgeSession
    case bridgeRejectedOperation(Int32)
    case networkUnreachable(underlying: String, code: UInt32, stage: RDPConnectStage)
    case tlsHandshakeFailed(reason: String, code: UInt32, stage: RDPConnectStage)
    case authenticationFailed
    case certificateRejected
    case configurationInvalid(reason: String)
    /// An IronRDP failure outside the shared categories; `code` is in the 0x4952xxxx range.
    case ironrdp(code: UInt32, description: String)
}

public enum RDPDisconnectReason: Equatable, Sendable {
    case localRequest
    case serverDisconnect(code: UInt32?)
    case timeout
    case error
}

public struct RDPConnectionStatistics: Equatable, Sendable {
    public let framesReceived: UInt64
    public let frameBytesReceived: UInt64
    public let remoteClipboardTextsReceived: UInt64
    public let remoteFilesReceived: UInt64
    public let remoteFileBytesReceived: UInt64
    public let localClipboardTextsSent: UInt64
    public let localFilesOffered: UInt64
    public let localFileBytesOffered: UInt64
    public let audioWavesReceived: UInt64
    public let startedAt: Date?
    public let lastActivityAt: Date?
}

public protocol RDPSessionDelegate: AnyObject {
    func rdpSession(_ session: RDPEngineSession, didLog message: String)
    func rdpSession(
        _ session: RDPEngineSession,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool
    func rdpSession(_ session: RDPEngineSession, didFailWith error: RDPSessionError)
    func rdpSession(_ session: RDPEngineSession, didDisconnectWith reason: RDPDisconnectReason)
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteText text: String)
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteFiles files: [RDPRemoteFile])
    func rdpSession(_ session: RDPEngineSession, didReceiveFrame frame: RDPFrame)
    func rdpSession(_ session: RDPEngineSession, didUpdatePointer pointer: RDPRemotePointer)
    func rdpSessionOutputResumedForInput(_ session: RDPEngineSession)
}

public extension RDPSessionDelegate {
    func rdpSession(
        _ session: RDPEngineSession,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool { false }  // fail closed: a conformer that omits this must NOT auto-trust certs

    func rdpSession(_ session: RDPEngineSession, didFailWith error: RDPSessionError) {}
    func rdpSession(_ session: RDPEngineSession, didDisconnectWith reason: RDPDisconnectReason) {}
    func rdpSession(_ session: RDPEngineSession, didUpdatePointer pointer: RDPRemotePointer) {}
    func rdpSessionOutputResumedForInput(_ session: RDPEngineSession) {}
}

struct MutableRDPConnectionStatistics {
    var framesReceived: UInt64 = 0
    var frameBytesReceived: UInt64 = 0
    var remoteClipboardTextsReceived: UInt64 = 0
    var remoteFilesReceived: UInt64 = 0
    var remoteFileBytesReceived: UInt64 = 0
    var localClipboardTextsSent: UInt64 = 0
    var localFilesOffered: UInt64 = 0
    var localFileBytesOffered: UInt64 = 0
    var audioWavesReceived: UInt64 = 0
    var startedAt: Date?
    var lastActivityAt: Date?

    func snapshot() -> RDPConnectionStatistics {
        RDPConnectionStatistics(
            framesReceived: framesReceived,
            frameBytesReceived: frameBytesReceived,
            remoteClipboardTextsReceived: remoteClipboardTextsReceived,
            remoteFilesReceived: remoteFilesReceived,
            remoteFileBytesReceived: remoteFileBytesReceived,
            localClipboardTextsSent: localClipboardTextsSent,
            localFilesOffered: localFilesOffered,
            localFileBytesOffered: localFileBytesOffered,
            audioWavesReceived: audioWavesReceived,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt
        )
    }
}

public struct RDPRemoteFile: Equatable, Sendable {
    public let fileName: String
    public let byteCount: UInt64
    public let localURL: URL?

    init(entry: RDPFileListEntry) {
        self.fileName = entry.fileName
        self.byteCount = entry.byteCount
        self.localURL = entry.localURL
    }
}

extension RDPConnectionOptions {
    var clipboardPasteboard: SystemPasteboardClient {
        let pasteboard = pasteboardName.map { NSPasteboard(name: NSPasteboard.Name($0)) } ?? .general
        return SystemPasteboardClient(pasteboard: pasteboard)
    }
}
