import ClipboardBridge
import FileTransferStaging
import Foundation
import FreeRDPBridge

public enum RDPSessionError: Error, Equatable {
    case unableToCreateBridgeSession
    case bridgeRejectedOperation(Int32)
}

public protocol RDPSessionDelegate: AnyObject {
    func rdpSession(_ session: RDPSession, didLog message: String)
    func rdpSession(_ session: RDPSession, didReceiveRemoteText text: String)
    func rdpSession(_ session: RDPSession, didReceiveRemoteFiles files: [RDPRemoteFile])
    func rdpSession(_ session: RDPSession, didReceiveFrame frame: RDPFrame)
}

public final class RDPSession {
    public weak var delegate: RDPSessionDelegate?

    private var bridgeSession: OpaquePointer?
    private let staging: FileTransferStaging
    private let resizeCoordinator: DisplayResizeCoordinator
    private var clipboardCoordinator: ClipboardCoordinator?
    private var remoteClipboardSink: RemoteClipboardSink?
    private var remoteFileDownloadManager: RDPRemoteFileDownloadManager?
    private var callbacks: RDPBridgeCallbacks

    public init(
        staging: FileTransferStaging = FileTransferStaging(),
        resizeCoordinator: DisplayResizeCoordinator = DisplayResizeCoordinator()
    ) throws {
        self.staging = staging
        self.resizeCoordinator = resizeCoordinator
        self.callbacks = RDPBridgeCallbacks()

        let retainedSelf = Unmanaged.passUnretained(self).toOpaque()
        callbacks.context = retainedSelf
        callbacks.log = { message, context in
            guard let message, let context else { return }
            let session = Unmanaged<RDPSession>.fromOpaque(context).takeUnretainedValue()
            session.delegate?.rdpSession(session, didLog: String(cString: message))
        }
        callbacks.remoteText = { bytes, length, context in
            guard let context else { return }
            let session = Unmanaged<RDPSession>.fromOpaque(context).takeUnretainedValue()
            let data: Data
            if length == 0 {
                data = Data()
            } else {
                guard let bytes else { return }
                data = Data(bytes: bytes, count: length)
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            session.clipboardCoordinator?.receiveRemoteText(text)
            session.delegate?.rdpSession(session, didReceiveRemoteText: text)
        }
        callbacks.remoteFileList = { bytes, length, context in
            guard let bytes, let context else { return }
            let session = Unmanaged<RDPSession>.fromOpaque(context).takeUnretainedValue()
            let data = Data(bytes: bytes, count: length)
            let decoded = (try? RDPFileListPayload.decode(data))
                ?? (try? WindowsFileGroupDescriptor.decode(data))
                ?? []
            let files = decoded.map(RDPRemoteFile.init(entry:))
            session.delegate?.rdpSession(session, didReceiveRemoteFiles: files)
            session.materializeRemoteFiles(decoded)
        }
        callbacks.remoteFileContents = { streamId, bytes, length, context in
            guard let context else { return }
            let session = Unmanaged<RDPSession>.fromOpaque(context).takeUnretainedValue()
            let data: Data
            if length == 0 {
                data = Data()
            } else {
                guard let bytes else { return }
                data = Data(bytes: bytes, count: length)
            }
            session.remoteFileDownloadManager?.receive(streamId: streamId, data: data)
        }
        callbacks.frame = { bytes, width, height, stride, context in
            guard let bytes, let context else { return }
            let byteCount = Int(stride) * Int(height)
            guard byteCount > 0 else { return }
            let session = Unmanaged<RDPSession>.fromOpaque(context).takeUnretainedValue()
            let frame = RDPFrame(
                bgra: Data(bytes: bytes, count: byteCount),
                width: Int(width),
                height: Int(height),
                stride: Int(stride)
            )
            session.delegate?.rdpSession(session, didReceiveFrame: frame)
        }

        self.bridgeSession = rdp_bridge_session_create(&callbacks)
        guard let bridgeSession else {
            throw RDPSessionError.unableToCreateBridgeSession
        }

        let sink = FreeRDPClipboardBridge(session: bridgeSession, staging: staging)
        self.remoteClipboardSink = sink
        self.remoteFileDownloadManager = RDPRemoteFileDownloadManager(session: bridgeSession, staging: staging)
        self.clipboardCoordinator = ClipboardCoordinator(
            pasteboard: SystemPasteboardClient(),
            remoteSink: sink
        )
    }

    deinit {
        if let bridgeSession {
            rdp_bridge_disconnect(bridgeSession)
            rdp_bridge_session_destroy(bridgeSession)
        }
    }

    public var isConnected: Bool {
        guard let bridgeSession else { return false }
        return rdp_bridge_is_connected(bridgeSession)
    }

    public func connect(_ options: RDPConnectionOptions) throws {
        guard let bridgeSession else {
            throw RDPSessionError.unableToCreateBridgeSession
        }

        let status = options.host.withCString { hostPointer in
            withOptionalCString(options.username) { usernamePointer in
                withOptionalCString(options.password) { passwordPointer in
                    withOptionalCString(options.domain) { domainPointer in
                        withOptionalCString(options.redirectedFolderPath) { folderPathPointer in
                            withOptionalCString(options.redirectedFolderName) { folderNamePointer in
                                var bridgeOptions = RDPBridgeConnectionOptions(
                                    host: hostPointer,
                                    port: options.port,
                                    username: usernamePointer,
                                    password: passwordPointer,
                                    domain: domainPointer,
                                    enableClipboard: options.enableClipboard,
                                    enableDriveRedirection: options.enableDriveRedirection || options.redirectedFolderPath != nil,
                                    redirectedFolderPath: folderPathPointer,
                                    redirectedFolderName: folderNamePointer,
                                    audioPlaybackMode: RDPBridgeAudioPlaybackMode(rawValue: options.audioPlaybackMode.rawValue)
                                )
                                return rdp_bridge_connect(bridgeSession, &bridgeOptions)
                            }
                        }
                    }
                }
            }
        }

        try throwIfNeeded(status)
    }

    public func disconnect() throws {
        guard let bridgeSession else {
            throw RDPSessionError.unableToCreateBridgeSession
        }
        try throwIfNeeded(rdp_bridge_disconnect(bridgeSession))
    }

    public func pollLocalClipboard() throws {
        do {
            try clipboardCoordinator?.pollLocalPasteboard()
        } catch ClipboardBridgeError.noSupportedPasteboardContent {
            return
        } catch {
            delegate?.rdpSession(self, didLog: "Local clipboard sync failed: \(error)")
            throw error
        }
    }

    public func sendLocalFiles(_ urls: [URL]) throws {
        delegate?.rdpSession(self, didLog: "Local files offered to remote clipboard: \(urls.count).")
        do {
            try remoteClipboardSink?.sendLocalFiles(urls)
        } catch {
            delegate?.rdpSession(self, didLog: "Local file offer failed: \(error)")
            throw error
        }
    }

    public func sendLocalText(_ text: String) throws {
        try remoteClipboardSink?.sendLocalText(text)
    }

    public func updateDesktopSize(pointWidth: Double, pointHeight: Double, scale: Double, force: Bool = false) throws {
        guard let bridgeSession else {
            throw RDPSessionError.unableToCreateBridgeSession
        }
        guard let size = resizeCoordinator.sizeToSend(
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            scale: scale,
            force: force
        ) else {
            return
        }

        try throwIfNeeded(
            rdp_bridge_update_desktop_size(
                bridgeSession,
                size.pixelWidth,
                size.pixelHeight,
                size.scale
            )
        )
    }

    public func sendPointerMove(_ location: RDPPointerLocation) throws {
        guard let bridgeSession else {
            throw RDPSessionError.unableToCreateBridgeSession
        }
        try throwIfNeeded(rdp_bridge_send_pointer_move(bridgeSession, location.pixelX, location.pixelY))
    }

    public func sendPointerButton(_ button: RDPPointerButton, at location: RDPPointerLocation, pressed: Bool) throws {
        guard let bridgeSession else {
            throw RDPSessionError.unableToCreateBridgeSession
        }
        try throwIfNeeded(
            rdp_bridge_send_pointer_button(
                bridgeSession,
                location.pixelX,
                location.pixelY,
                button.bridgeValue,
                pressed
            )
        )
    }

    public func sendScroll(deltaX: Int32, deltaY: Int32) throws {
        guard let bridgeSession else {
            throw RDPSessionError.unableToCreateBridgeSession
        }
        try throwIfNeeded(rdp_bridge_send_scroll(bridgeSession, deltaX, deltaY))
    }

    public func sendKey(keyCode: UInt16, pressed: Bool) throws {
        guard let bridgeSession else {
            throw RDPSessionError.unableToCreateBridgeSession
        }
        try throwIfNeeded(rdp_bridge_send_key(bridgeSession, keyCode, pressed))
    }

    private func throwIfNeeded(_ status: RDPBridgeStatus) throws {
        guard status == RDPBridgeStatusOK else {
            throw RDPSessionError.bridgeRejectedOperation(Int32(status.rawValue))
        }
    }

    private func materializeRemoteFiles(_ entries: [RDPFileListEntry]) {
        guard !entries.isEmpty, let remoteFileDownloadManager else {
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self, weak remoteFileDownloadManager] in
            guard let self, let remoteFileDownloadManager else { return }
            do {
                let urls = try remoteFileDownloadManager.materialize(entries)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.clipboardCoordinator?.receiveRemoteFiles(urls)
                    let fileNames = urls
                        .map { FileNameNormalization.normalizeForTransfer($0.lastPathComponent) }
                        .joined(separator: ", ")
                    self.delegate?.rdpSession(
                        self,
                        didLog: "Remote files materialized to local pasteboard: \(fileNames)."
                    )
                }
            } catch {
                self.delegate?.rdpSession(self, didLog: "Remote file materialization failed: \(error)")
            }
        }
    }
}

private extension RDPPointerButton {
    var bridgeValue: RDPBridgePointerButton {
        switch self {
        case .left:
            return RDPBridgePointerButtonLeft
        case .right:
            return RDPBridgePointerButtonRight
        case .middle:
            return RDPBridgePointerButtonMiddle
        }
    }
}

private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let string else {
        return body(nil)
    }
    return string.withCString(body)
}

public struct RDPRemoteFile: Equatable, Sendable {
    public let fileName: String
    public let byteCount: UInt64
    public let localURL: URL?

    fileprivate init(entry: RDPFileListEntry) {
        self.fileName = entry.fileName
        self.byteCount = entry.byteCount
        self.localURL = entry.localURL
    }
}
