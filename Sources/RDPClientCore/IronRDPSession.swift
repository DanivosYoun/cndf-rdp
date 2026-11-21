import ClipboardBridge
import FileTransferStaging
import CoreGraphics
import Foundation
import IronRDPBridge

/// IronRDP engine session over the `CNDFIronRDP.h` ABI v1. Mirrors `RDPSession`'s contract:
/// callbacks arrive on engine threads, frames are copied into `RDPFrame` and handed to the
/// existing `didReceiveFrame` path, and certificate trust uses the FreeRDP-compatible PEM key.
///
/// Output suppression is unsupported.
public final class IronRDPSession: RDPEngineSession {
    public weak var delegate: RDPSessionDelegate?

    /// `cndf_iron_version()`: crate version, pinned IronRDP SHA and patch count.
    public static var engineVersion: String {
        cndf_iron_version().map { String(cString: $0) } ?? "unknown"
    }

    private static let destroyJoinTimeoutMs: UInt32 = 2000
    private static let inputTimeoutMs: UInt32 = 1000

    private let resizeCoordinator: DisplayResizeCoordinator
    private let certificateTrustTimeout: TimeInterval
    // Internal so tests can drive the C callbacks with a chosen generation.
    private(set) var callbacks: CNDFIronCallbacks
    // Guarded by sessionLock. Every ABI call that takes the handle runs under the lock, so
    // disconnect can take the handle away before destroying it.
    private let sessionLock = NSRecursiveLock()
    private var nativeSession: OpaquePointer?
    private var nativeGeneration: UInt64 = 0
    private var inputConnectionGeneration: UInt64 = 0
    private var lastConnectionOptions: RDPConnectionOptions?
    private var currentDesktopSize: RDPDesktopSize?
    // Guarded by callbackLock, which is never held across an ABI call that waits for engine
    // threads: engine threads take it while holding the ABI callback gate.
    private let callbackLock = NSLock()
    private var callbackGeneration: UInt64?
    // Native generations restart when a handle is recreated. Keep a Swift connection
    // generation for work that can outlive a callback or a native handle.
    private var clipboardGeneration: UInt64 = 0
    private var remoteFileDownloadManager: RDPRemoteFileDownloadManager?
    private var pendingTrust: CertificateTrustDecision?
    private var trustClosed = false
    private var lastRemotePointer: RDPRemotePointer?
    private var logFileURL: URL?
    private let logLock = NSLock()
    private let statisticsLock = NSLock()
    private var statisticsStorage = MutableRDPConnectionStatistics()
    private let keyboardProfileLock = NSLock()
    private var keyboardProfileStorage = RDPKeyboardProfile.standard
    private let staging: FileTransferStaging
    private var clipboardCoordinator: ClipboardCoordinator?
    private var remoteClipboardSink: IronRDPClipboardSink?

    public convenience init(resizeCoordinator: DisplayResizeCoordinator = DisplayResizeCoordinator()) throws {
        try self.init(resizeCoordinator: resizeCoordinator, certificateTrustTimeout: 120)
    }

    init(
        resizeCoordinator: DisplayResizeCoordinator,
        certificateTrustTimeout: TimeInterval,
        staging: FileTransferStaging = FileTransferStaging()
    ) throws {
        self.staging = staging
        self.resizeCoordinator = resizeCoordinator
        self.certificateTrustTimeout = certificateTrustTimeout
        self.callbacks = CNDFIronCallbacks()
        guard cndf_iron_abi_version() == UInt32(CNDF_IRON_ABI_VERSION) else {
            throw RDPSessionError.unableToCreateBridgeSession
        }

        callbacks.context = Unmanaged.passUnretained(self).toOpaque()
        callbacks.log = { generation, _, bytes, length, context in
            guard let context else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard session.isCallbackCurrent(generation) else { return }
            session.emitLog(utf8String(bytes, length))
        }
        callbacks.certificate_trust = { generation, chain, context in
            guard let chain, let context else { return false }  // fail closed
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard session.isCallbackCurrent(generation) else { return false }
            let native = chain.pointee
            var certificates: [Data] = []
            if let der = native.der, let lengths = native.der_length {
                for index in 0..<native.count {
                    guard let bytes = der[index] else { return false }
                    certificates.append(Data(bytes: bytes, count: lengths[index]))
                }
            }
            return session.evaluateCertificateTrust(
                fingerprint: RDPCertificateTrustString.freeRDPCompatible(derChain: certificates),
                hostname: native.hostname.map(String.init(cString:)) ?? "",
                port: native.port
            )
        }
        callbacks.connected = { generation, context in
            guard let context else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard session.isCallbackCurrent(generation) else { return }
            session.emitLog("IronRDP connected.")
        }
        callbacks.failure = { generation, kind, code, stage, bytes, length, context in
            guard let context else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            // A failure ends the generation; the engine sends no disconnect after it. Report
            // the disconnect here, as FreeRDP does after its failure callback.
            guard session.endCallbackGeneration(generation) else { return }
            let description = utf8String(bytes, length)
            session.emitLog("IronRDP connect failed: \(description) [\(String(format: "0x%08x", code))].")
            session.delegate?.rdpSession(
                session,
                didFailWith: RDPSessionError(ironKind: kind, code: code, stage: RDPConnectStage(stage), description: description)
            )
            session.deliverDisconnect(.error)
        }
        callbacks.disconnect = { generation, kind, code, context in
            guard let context else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard session.endCallbackGeneration(generation) else { return }
            session.deliverDisconnect(RDPDisconnectReason(ironKind: kind, code: code))
        }
        callbacks.frame = { generation, bytes, width, height, stride, _, _, context in
            guard let bytes, let context else { return }
            let byteCount = Int(stride) * Int(height)
            guard byteCount > 0 else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard session.isCallbackCurrent(generation) else { return }
            let frame = RDPFrame(
                bgra: Data(bytes: bytes, count: byteCount),
                width: Int(width),
                height: Int(height),
                stride: Int(stride)
            )
            session.recordFrame(byteCount: byteCount)
            session.delegate?.rdpSession(session, didReceiveFrame: frame)
        }
        callbacks.pointer = { generation, kind, bytes, width, height, stride, hotX, hotY, context in
            guard let context else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard session.isCallbackCurrent(generation) else { return }
            let pointer: RDPRemotePointer
            switch kind {
            case CNDF_IRON_POINTER_IMAGE:
                guard let bytes, width > 0, height > 0, stride >= width * 4 else { return }
                pointer = .image(RDPPointerImage(
                    bgra: Data(bytes: bytes, count: Int(stride) * Int(height)),
                    width: Int(width),
                    height: Int(height),
                    stride: Int(stride),
                    hotSpotX: Int(hotX),
                    hotSpotY: Int(hotY)
                ))
            case CNDF_IRON_POINTER_HIDDEN:
                pointer = .hidden
            default:
                pointer = .systemDefault
            }
            session.deliverRemotePointer(pointer)
        }
        callbacks.remote_text = { generation, bytes, length, context in
            guard let context else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard let clipboard = session.clipboardContext(for: generation) else { return }
            let text = utf8String(bytes, length)
            session.deliverNewestRemoteClipboard(generation, connection: clipboard.connection) { session in
                session.updateStatistics { $0.remoteClipboardTextsReceived += 1 }
                session.clipboardCoordinator?.receiveRemoteText(text)
                session.delegate?.rdpSession(session, didReceiveRemoteText: text)
            }
        }
        callbacks.remote_file_list = { generation, files, count, context in
            guard let context, let files else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard let clipboard = session.clipboardContext(for: generation) else { return }
            let descriptors = UnsafeBufferPointer(start: files, count: count).map { file in
                (name: utf8String(file.name_utf8, file.name_length), size: file.size)
            }
            session.deliverNewestRemoteClipboard(generation, connection: clipboard.connection) { session in
                let entries = descriptors.map { file in
                    RDPFileListEntry(
                        fileName: FileNameNormalization.normalizeForTransfer(file.name),
                        byteCount: file.size,
                        localURL: nil
                    )
                }
                session.updateStatistics {
                    $0.remoteFilesReceived += UInt64(entries.count)
                    $0.remoteFileBytesReceived &+= entries.reduce(UInt64(0)) { $0 &+ $1.byteCount }
                }
                session.delegate?.rdpSession(session, didReceiveRemoteFiles: entries.map(RDPRemoteFile.init(entry:)))
                guard !entries.isEmpty, session.clipboardIsCurrent(generation, connection: clipboard.connection) else { return }
                session.materializeRemoteFiles(entries, with: clipboard.manager, generation: generation, connection: clipboard.connection)
            }
        }
        callbacks.remote_file_contents = { generation, stream, ok, bytes, length, context in
            guard let context else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard let clipboard = session.clipboardContext(for: generation) else { return }
            if ok {
                let data = bytes.map { Data(bytes: $0, count: length) } ?? Data()
                clipboard.manager.receive(streamId: stream, data: data)
            } else {
                clipboard.manager.fail(streamId: stream)
            }
        }
    }

    deinit {
        // No delegate call from deinit: `self` must not escape it.
        tearDownNativeSession(reportingDisconnect: false)
    }

    public var engine: RDPEngineKind { .ironRDP }
    public var supportsClipboard: Bool { engine.supportsClipboard }

    public var keyboardProfile: RDPKeyboardProfile {
        keyboardProfileLock.lock()
        defer { keyboardProfileLock.unlock() }
        return keyboardProfileStorage
    }

    public var supportsOutputSuppression: Bool { false }

    public var isConnected: Bool {
        withSessionLock {
            guard let nativeSession else { return false }
            return cndf_iron_is_connected(nativeSession, nativeGeneration)
        }
    }

    public var connectionGeneration: UInt64 {
        withSessionLock { inputConnectionGeneration }
    }

    public func isInputConnectionCurrent(generation: UInt64) -> Bool {
        withSessionLock { inputConnectionGeneration == generation && isConnected }
    }

    public func withInputConnection(generation: UInt64, _ body: () throws -> Void) throws {
        try withSessionLock {
            guard isInputConnectionCurrent(generation: generation) else {
                throw RDPSessionError.unableToCreateBridgeSession
            }
            try body()
        }
    }

    public var statistics: RDPConnectionStatistics {
        var nativeStats = CNDFIronStatistics()
        let hasNativeStats = withSessionLock {
            guard let nativeSession else { return false }
            return cndf_iron_get_statistics(nativeSession, &nativeStats)
        }
        statisticsLock.lock()
        defer { statisticsLock.unlock() }
        if hasNativeStats {
            statisticsStorage.audioWavesReceived = max(
                statisticsStorage.audioWavesReceived,
                nativeStats.audio_waves_received
            )
        }
        return statisticsStorage.snapshot()
    }

    public func connect(_ options: RDPConnectionOptions, initialPointSize: CGSize, scale: Double) throws {
        let initialDesktopSize = resizeCoordinator.candidateSize(
            pointWidth: Double(initialPointSize.width),
            pointHeight: Double(initialPointSize.height),
            scale: scale,
            preferDeviceNativeResolution: options.preferDeviceNativeResolution,
            forcedDesktopSize: options.forcedDesktopSize
        )
        try connect(options, desktopSize: initialDesktopSize)
    }

    private func connect(_ options: RDPConnectionOptions, desktopSize: RDPDesktopSize) throws {
        try withSessionLock {
            if nativeSession == nil {
                nativeSession = cndf_iron_session_create(&callbacks)
            }
            guard let nativeSession else {
                throw RDPSessionError.unableToCreateBridgeSession
            }

            logFileURL = options.logFileURL
            if let logFileURL {
                try? FileManager.default.createDirectory(at: logFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            }
            resetStatistics()
            emitLog("RDP engine=ironrdp version=\(Self.engineVersion)")

            emitLog(options.channelLogMessage)
            emitLog(options.keyboardLogMessage)
            keyboardProfileLock.lock()
            keyboardProfileStorage = options.keyboardProfile
            keyboardProfileLock.unlock()

            let connection = inputConnectionGeneration &+ 1
            let sink = IronRDPClipboardSink(staging: staging) { [weak self] command in
                guard let self else { throw Self.clipboardDisconnected }
                try self.withClipboardConnection(connection, command)
            }
            let manager = RDPRemoteFileDownloadManager(staging: staging) { [weak self] stream, index, offset, length in
                guard let self else { throw Self.clipboardDisconnected }
                try self.requestRemoteFileRange(connection: connection, stream: stream, index: index, offset: offset, length: length)
            }
            let coordinator = options.enableClipboard
                ? ClipboardCoordinator(pasteboard: options.clipboardPasteboard, remoteSink: sink)
                : nil

            // Held across connect so the first callbacks of the new generation wait for it
            // to be recorded instead of being dropped as stale.
            callbackLock.lock()
            trustClosed = false
            var generation: UInt64 = 0
            let status = options.host.withCString { hostPointer in
                (options.username ?? "").withCString { usernamePointer in
                    withOptionalCString(options.domain) { domainPointer in
                        withOptionalCString(options.redirectedFolderPath) { drivePath in
                            withOptionalCString(options.redirectedFolderName) { driveName in
                                withPasswordBytes(options) { passwordPointer, passwordLength in
                                    var nativeOptions = CNDFIronConnectOptions(
                                        struct_size: UInt32(MemoryLayout<CNDFIronConnectOptions>.stride),
                                        host: hostPointer,
                                        port: options.port,
                                        username: usernamePointer,
                                        domain: domainPointer,
                                        desktop_width: desktopSize.pixelWidth,
                                        desktop_height: desktopSize.pixelHeight,
                                        scale_percent: scalePercent(desktopSize.scale),
                                        color_depth: options.colorDepth.rawValue,
                                        graphics_pipeline: options.graphicsMode != .compatibility,
                                        log_level: options.logLevel.ironLogLevel,
                                        clipboard: options.enableClipboard,
                                        drive_path: drivePath,
                                        drive_name: driveName,
                                        audio_mode: CNDFIronAudioMode(rawValue: options.audioPlaybackMode.rawValue),
                                        keyboard_layout: options.keyboardProfile.keyboardLayout,
                                        keyboard_type: options.keyboardProfile.keyboardType,
                                        keyboard_subtype: options.keyboardProfile.keyboardSubType,
                                        keyboard_function_keys: options.keyboardProfile.keyboardFunctionKey
                                    )
                                    return cndf_iron_connect(nativeSession, &nativeOptions, passwordPointer, passwordLength, &generation)
                                }
                            }
                        }
                    }
                }
            }
            if status == CNDF_IRON_OK {
                callbackGeneration = generation
                clipboardGeneration = connection
                remoteFileDownloadManager = options.enableClipboard ? manager : nil
            }
            callbackLock.unlock()

            try throwIfNeeded(status)
            nativeGeneration = generation
            inputConnectionGeneration = connection
            clipboardCoordinator = coordinator
            remoteClipboardSink = sink
            lastConnectionOptions = options
            currentDesktopSize = desktopSize
        }
    }

    public func reconnect() throws {
        try withSessionLock {
            guard let lastConnectionOptions, let currentDesktopSize else {
                throw RDPSessionError.configurationInvalid(reason: "No previous RDP connection options are available.")
            }
            try disconnect()
            try connect(lastConnectionOptions, desktopSize: currentDesktopSize)
        }
    }

    /// Rejects a pending certificate decision, requests shutdown and destroys the native
    /// session. When this returns no further callback starts (ABI `cndf_iron_session_destroy`).
    /// If the connection had not ended yet, `didDisconnectWith(.localRequest)` is delivered
    /// once before returning, as FreeRDP's worker does while `disconnect()` waits for it.
    public func disconnect() throws {
        tearDownNativeSession(reportingDisconnect: true)
    }

    public func pollLocalClipboard() throws {
        try withSessionLock {
            do {
                try clipboardCoordinator?.pollLocalPasteboard()
            } catch ClipboardBridgeError.noSupportedPasteboardContent {
                return
            } catch {
                emitLog("Local clipboard sync failed: \(error)")
                throw error
            }
        }
    }

    public func sendLocalFiles(_ urls: [URL]) throws {
        delegate?.rdpSession(self, didLog: "Local files offered to remote clipboard: \(urls.count).")
        do {
            try withSessionLock {
                guard let remoteClipboardSink, clipboardCoordinator != nil else { throw Self.clipboardDisconnected }
                let offeredBytes = try urls.reduce(UInt64(0)) { total, url in
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    return total + UInt64(values.fileSize ?? 0)
                }
                try remoteClipboardSink.sendLocalFiles(urls)
                updateStatistics {
                    $0.localFilesOffered += UInt64(urls.count)
                    $0.localFileBytesOffered += offeredBytes
                }
            }
        } catch {
            emitLog("Local file offer failed: \(error)")
            throw error
        }
    }

    public func sendLocalText(_ text: String) throws {
        try withSessionLock {
            guard let remoteClipboardSink else { throw Self.clipboardDisconnected }
            try remoteClipboardSink.sendLocalText(text)
            updateStatistics { $0.localClipboardTextsSent += 1 }
        }
    }

    private static var clipboardDisconnected: RDPSessionError {
        .bridgeRejectedOperation(Int32(CNDF_IRON_NOT_CONNECTED.rawValue))
    }

    private func withClipboardConnection(
        _ connection: UInt64,
        _ command: (OpaquePointer, UInt64) -> CNDFIronStatus
    ) throws {
        try withSessionLock {
            guard let nativeSession, inputConnectionGeneration == connection,
                  clipboardIsCurrent(nativeGeneration, connection: connection) else {
                throw Self.clipboardDisconnected
            }
            try throwIfNeeded(command(nativeSession, nativeGeneration))
        }
    }

    func requestRemoteFileRange(connection: UInt64, stream: UInt32, index: UInt32, offset: UInt64, length: UInt32) throws {
        try withClipboardConnection(connection) { session, generation in
            cndf_iron_clipboard_request_file_range(session, generation, stream, index, offset, length)
        }
    }

    private func clipboardContext(for generation: UInt64) -> (connection: UInt64, manager: RDPRemoteFileDownloadManager)? {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard !trustClosed, callbackGeneration == generation, let remoteFileDownloadManager else { return nil }
        return (clipboardGeneration, remoteFileDownloadManager)
    }

    private func clipboardIsCurrent(_ generation: UInt64, connection: UInt64) -> Bool {
        clipboardContext(for: generation)?.connection == connection
    }

    private struct RemoteClipboardDelivery {
        let generation: UInt64
        let connection: UInt64
        let deliver: (IronRDPSession) -> Void
    }

    private struct RemoteFileMaterialization {
        let entries: [RDPFileListEntry]
        let manager: RDPRemoteFileDownloadManager
        let generation: UInt64
        let connection: UInt64
    }

    // Server clipboard callbacks keep only the newest text or file list for main, and file
    // lists materialize one at a time behind the newest waiting list.
    private let remoteClipboardSlot = IronRDPRemoteClipboardSlot<RemoteClipboardDelivery>()
    private let remoteFileMaterializations = IronRDPRemoteFileMaterializationQueue<RemoteFileMaterialization>()

    /// Server text and file lists. A newer one replaces a delivery still waiting for main.
    private func deliverNewestRemoteClipboard(
        _ generation: UInt64,
        connection: UInt64,
        _ deliver: @escaping (IronRDPSession) -> Void
    ) {
        let delivery = RemoteClipboardDelivery(generation: generation, connection: connection, deliver: deliver)
        guard remoteClipboardSlot.store(delivery) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let delivery = self.remoteClipboardSlot.take() else { return }
            self.deliverClipboardNow(delivery.generation, connection: delivery.connection, delivery.deliver)
        }
    }

    /// Materialization results. Each finished materialization queues one block.
    private func deliverClipboard(
        _ generation: UInt64,
        connection: UInt64,
        _ deliver: @escaping (IronRDPSession) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.deliverClipboardNow(generation, connection: connection, deliver)
        }
    }

    private func deliverClipboardNow(
        _ generation: UInt64,
        connection: UInt64,
        _ deliver: (IronRDPSession) -> Void
    ) {
        withSessionLock {
            guard clipboardIsCurrent(generation, connection: connection) else { return }
            deliver(self)
        }
    }

    private func materializeRemoteFiles(
        _ entries: [RDPFileListEntry],
        with manager: RDPRemoteFileDownloadManager,
        generation: UInt64,
        connection: UInt64
    ) {
        let job = RemoteFileMaterialization(entries: entries, manager: manager, generation: generation, connection: connection)
        guard remoteFileMaterializations.submit(job) else { return }
        // The session stays weak while a materialization waits on range replies.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let job = self?.remoteFileMaterializations.next() {
                let (generation, connection) = (job.generation, job.connection)
                guard self?.clipboardIsCurrent(generation, connection: connection) == true else { continue }
                do {
                    let urls = try job.manager.materialize(job.entries)
                    self?.deliverClipboard(generation, connection: connection) { session in
                        session.clipboardCoordinator?.receiveRemoteFiles(urls)
                        let fileNames = urls.map { FileNameNormalization.normalizeForTransfer($0.lastPathComponent) }
                            .joined(separator: ", ")
                        session.delegate?.rdpSession(session, didLog: "Remote files materialized to local pasteboard: \(fileNames).")
                    }
                } catch {
                    self?.deliverClipboard(generation, connection: connection) { session in
                        session.emitLog("Remote file materialization failed: \(error)")
                    }
                }
            }
        }
    }

    /// A forced update (`sendForcedDesktopSize`) re-delivers the current framebuffer without a
    /// server round trip. Resize only when the requested size has changed. A same-size layout
    /// may never trigger a server reactivation, blocking a real resize queued behind it.
    /// The view already debounces non-forced updates, so the coordinator's commit-on-ask
    /// `sizeToSend` is not used: it would remember a size the engine rejected.
    public func updateDesktopSize(pointWidth: Double, pointHeight: Double, scale: Double, force: Bool = false) throws {
        try withSessionLock {
            let size = resizeCoordinator.candidateSize(
                pointWidth: pointWidth,
                pointHeight: pointHeight,
                scale: scale,
                preferDeviceNativeResolution: lastConnectionOptions?.preferDeviceNativeResolution ?? true,
                forcedDesktopSize: lastConnectionOptions?.forcedDesktopSize
            )
            guard force || size != currentDesktopSize else { return }
            guard let nativeSession else {
                throw RDPSessionError.unableToCreateBridgeSession
            }
            if force {
                // Best effort: before the first frame there is nothing to re-deliver.
                _ = cndf_iron_redeliver_frame(nativeSession, nativeGeneration)
            }
            guard size != currentDesktopSize else { return }
            let status = cndf_iron_resize(nativeSession, nativeGeneration, size.pixelWidth, size.pixelHeight, scalePercent(size.scale))
            guard status == CNDF_IRON_OK else {
                emitLog("IronRDP resize to \(size.pixelWidth)x\(size.pixelHeight) rejected [\(status.rawValue)].")
                try throwIfNeeded(status)
                return
            }
            currentDesktopSize = size
        }
    }

    public func setOutputSuppressed(_ suppressed: Bool) throws {
        throw RDPSessionError.configurationInvalid(reason: "IronRDP does not support output suppression.")
    }

    public func sendPointerMove(_ location: RDPPointerLocation) throws {
        try send(CNDFIronInputEvent(kind: CNDF_IRON_INPUT_POINTER_MOVE, x: location.pixelX, y: location.pixelY))
    }

    public func sendPointerButton(_ button: RDPPointerButton, at location: RDPPointerLocation, pressed: Bool) throws {
        var event = CNDFIronInputEvent(kind: CNDF_IRON_INPUT_POINTER_BUTTON, x: location.pixelX, y: location.pixelY)
        event.button = button.ironButton
        event.pressed = pressed
        try send(event)
    }

    @discardableResult
    public func sendScroll(at location: RDPPointerLocation, deltaX: Int32, deltaY: Int32) throws -> Bool {
        var event = CNDFIronInputEvent(kind: CNDF_IRON_INPUT_WHEEL, x: location.pixelX, y: location.pixelY)
        event.delta_x = deltaX
        event.delta_y = deltaY
        try send(event)
        return true
    }

    /// `keyCode` is an RDP scancode. As with the FreeRDP bridge, bit 0x100 also marks it extended.
    public func sendKey(keyCode: UInt16, pressed: Bool, extended: Bool) throws {
        var event = CNDFIronInputEvent(kind: CNDF_IRON_INPUT_KEY, x: 0, y: 0)
        event.code = keyCode & 0xFF
        event.extended = extended || keyCode & 0x100 != 0
        event.pressed = pressed
        try send(event)
    }

    public func sendUnicode(code: UInt16, pressed: Bool) throws {
        var event = CNDFIronInputEvent(kind: CNDF_IRON_INPUT_UNICODE, x: 0, y: 0)
        event.code = code
        event.pressed = pressed
        try send(event)
    }

    // Pointer and disconnect callbacks are serialized on the delivery thread; the local
    // disconnect report runs only after destroy, when no callback can start.
    // The delegate hears the disconnect before the log line: a view that reacts to the
    // preceding failure by shutting down detaches its delegate, and the log line's file write
    // and delegate call in between were enough for that to drop the disconnect every time.
    private func deliverDisconnect(_ reason: RDPDisconnectReason) {
        lastRemotePointer = nil
        delegate?.rdpSession(self, didDisconnectWith: reason)
        emitLog("IronRDP disconnected.")
    }

    func deliverRemotePointer(_ pointer: RDPRemotePointer) {
        guard lastRemotePointer != pointer else { return }
        lastRemotePointer = pointer
        delegate?.rdpSession(self, didUpdatePointer: pointer)
    }

    func isCallbackCurrent(_ generation: UInt64) -> Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return callbackGeneration == generation
    }

    /// Ends `generation` if it is current. Exactly one caller wins per generation — the
    /// engine's failure or disconnect callback, or the local teardown — and that caller
    /// reports the disconnect. Later callbacks of the generation are dropped as stale.
    private func endCallbackGeneration(_ generation: UInt64?) -> Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard let generation, callbackGeneration == generation else { return false }
        callbackGeneration = nil
        remoteFileDownloadManager = nil
        return true
    }

    private func send(_ event: CNDFIronInputEvent) throws {
        try withSessionLock {
            guard let nativeSession else {
                throw RDPSessionError.unableToCreateBridgeSession
            }
            var event = event
            try throwIfNeeded(cndf_iron_send_input(nativeSession, nativeGeneration, &event, 1, Self.inputTimeoutMs))
        }
    }

    private func tearDownNativeSession(reportingDisconnect: Bool) {
        // A certificate callback holds the native callback gate while it waits; destroy would
        // wait for it, so the decision is rejected first (design I6).
        callbackLock.lock()
        trustClosed = true
        let pending = pendingTrust
        callbackLock.unlock()
        pending?.resolve(false)

        let handle: OpaquePointer? = withSessionLock {
            let handle = nativeSession
            nativeSession = nil
            clipboardCoordinator = nil
            remoteClipboardSink = nil
            return handle
        }
        guard let handle else { return }
        _ = cndf_iron_disconnect(handle)
        var nativeStats = CNDFIronStatistics()
        if cndf_iron_get_statistics(handle, &nativeStats) {
            statisticsLock.lock()
            statisticsStorage.audioWavesReceived = max(
                statisticsStorage.audioWavesReceived,
                nativeStats.audio_waves_received
            )
            statisticsLock.unlock()
        }
        cndf_iron_session_destroy(handle, Self.destroyJoinTimeoutMs)
        // destroy closed the callback gate, so the engine's own disconnect report for a live
        // generation was dropped; report it here instead.
        callbackLock.lock()
        let generation = callbackGeneration
        callbackLock.unlock()
        if endCallbackGeneration(generation), reportingDisconnect {
            deliverDisconnect(.localRequest)
        }
    }

    private func evaluateCertificateTrust(fingerprint: String, hostname: String, port: UInt16) -> Bool {
        // Fail CLOSED on every non-affirmative path: no delegate, a closing session, or no
        // decision within the timeout all reject.
        guard let delegate else { return false }
        let decision = CertificateTrustDecision()
        callbackLock.lock()
        guard !trustClosed else {
            callbackLock.unlock()
            return false
        }
        pendingTrust = decision
        callbackLock.unlock()
        defer {
            callbackLock.lock()
            if pendingTrust === decision { pendingTrust = nil }
            callbackLock.unlock()
        }
        Task {
            let result = await delegate.rdpSession(
                self,
                shouldTrustCertificateFingerprint: fingerprint,
                hostname: hostname,
                port: port
            )
            decision.resolve(result)
        }
        return decision.wait(timeout: certificateTrustTimeout)
    }

    private func emitLog(_ message: String) {
        if let logFileURL {
            logLock.lock()
            defer { logLock.unlock() }
            let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logFileURL.path),
                   let handle = try? FileHandle(forWritingTo: logFileURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                    try? handle.close()
                } else {
                    try? data.write(to: logFileURL, options: .atomic)
                }
            }
        }
        delegate?.rdpSession(self, didLog: message)
    }

    private func recordFrame(byteCount: Int) {
        updateStatistics {
            $0.framesReceived += 1
            $0.frameBytesReceived += UInt64(byteCount)
        }
    }

    private func resetStatistics() {
        statisticsLock.lock()
        statisticsStorage = MutableRDPConnectionStatistics(startedAt: Date(), lastActivityAt: Date())
        statisticsLock.unlock()
    }

    private func updateStatistics(_ update: (inout MutableRDPConnectionStatistics) -> Void) {
        statisticsLock.lock()
        update(&statisticsStorage)
        statisticsStorage.lastActivityAt = Date()
        statisticsLock.unlock()
    }

    private func throwIfNeeded(_ status: CNDFIronStatus) throws {
        guard status == CNDF_IRON_OK else {
            throw RDPSessionError.bridgeRejectedOperation(Int32(status.rawValue))
        }
    }

    private func withSessionLock<T>(_ body: () throws -> T) rethrows -> T {
        sessionLock.lock()
        defer { sessionLock.unlock() }
        return try body()
    }
}

/// One pending certificate decision. The first answer wins: the delegate's, or the rejection
/// `disconnect` delivers so the blocked engine thread is released.
private final class CertificateTrustDecision {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Bool?

    func resolve(_ trusted: Bool) {
        lock.lock()
        let first = result == nil
        if first { result = trusted }
        lock.unlock()
        if first { semaphore.signal() }
    }

    func wait(timeout: TimeInterval) -> Bool {
        _ = semaphore.wait(timeout: .now() + timeout)
        lock.lock()
        defer { lock.unlock() }
        if result == nil { result = false }
        return result ?? false
    }
}

private extension CNDFIronInputEvent {
    init(kind: CNDFIronInputKind, x: UInt32, y: UInt32) {
        self.init(
            kind: kind,
            code: 0,
            extended: false,
            pressed: false,
            button: CNDF_IRON_BUTTON_LEFT,
            x: x,
            y: y,
            delta_x: 0,
            delta_y: 0
        )
    }
}

private extension RDPPointerButton {
    var ironButton: CNDFIronPointerButton {
        switch self {
        case .left:
            return CNDF_IRON_BUTTON_LEFT
        case .right:
            return CNDF_IRON_BUTTON_RIGHT
        case .middle:
            return CNDF_IRON_BUTTON_MIDDLE
        }
    }
}

private extension RDPLogLevel {
    var ironLogLevel: CNDFIronLogLevel {
        switch self {
        case .trace: return CNDF_IRON_LOG_TRACE
        case .debug: return CNDF_IRON_LOG_DEBUG
        case .info: return CNDF_IRON_LOG_INFO
        case .warn: return CNDF_IRON_LOG_WARN
        case .error: return CNDF_IRON_LOG_ERROR
        case .fatal: return CNDF_IRON_LOG_FATAL
        case .off: return CNDF_IRON_LOG_OFF
        }
    }
}

extension RDPConnectStage {
    init(_ stage: CNDFIronStage) {
        switch stage {
        case CNDF_IRON_STAGE_INITIAL: self = .initial
        case CNDF_IRON_STAGE_NEGOTIATION: self = .negotiation
        case CNDF_IRON_STAGE_AUTHENTICATION: self = .authentication
        case CNDF_IRON_STAGE_CHANNEL_SETUP: self = .channelSetup
        case CNDF_IRON_STAGE_LICENSING: self = .licensing
        case CNDF_IRON_STAGE_CAPABILITIES: self = .capabilities
        case CNDF_IRON_STAGE_FINALIZATION: self = .finalization
        case CNDF_IRON_STAGE_ACTIVE: self = .active
        default: self = .unknown
        }
    }
}

extension RDPSessionError {
    /// The engine already applied the design I7 allow list: only CredSSP logon rejections
    /// arrive as AUTHENTICATION.
    init(ironKind kind: CNDFIronFailureKind, code: UInt32, stage: RDPConnectStage, description: String) {
        switch kind {
        case CNDF_IRON_FAILURE_NETWORK:
            self = .networkUnreachable(underlying: description, code: code, stage: stage)
        case CNDF_IRON_FAILURE_TLS:
            self = .tlsHandshakeFailed(reason: description, code: code, stage: stage)
        case CNDF_IRON_FAILURE_AUTHENTICATION:
            self = .authenticationFailed
        case CNDF_IRON_FAILURE_CERTIFICATE:
            self = .certificateRejected
        case CNDF_IRON_FAILURE_CONFIGURATION:
            self = .configurationInvalid(reason: description)
        default:
            self = .ironrdp(code: code, description: description)
        }
    }
}

extension RDPDisconnectReason {
    init(ironKind kind: CNDFIronDisconnectKind, code: UInt32) {
        switch kind {
        case CNDF_IRON_DISCONNECT_LOCAL_REQUEST:
            self = .localRequest
        case CNDF_IRON_DISCONNECT_SERVER:
            self = .serverDisconnect(code: code == 0 ? nil : code)
        case CNDF_IRON_DISCONNECT_TIMEOUT:
            self = .timeout
        default:
            self = .error
        }
    }
}

private func utf8String(_ bytes: UnsafePointer<UInt8>?, _ length: Int) -> String {
    guard let bytes, length > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
}

private func scalePercent(_ scale: Double) -> UInt32 {
    UInt32(max(1, min(Double(UInt32.max), (scale * 100).rounded())))
}

private func withOptionalCString<T>(_ string: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
    guard let string else {
        return body(nil)
    }
    return string.withCString(body)
}

/// Exposes the password bytes only for the duration of `body` (design I8).
private func withPasswordBytes<T>(_ options: RDPConnectionOptions, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
    if let securePassword = options.securePassword {
        return securePassword.withCString { pointer in
            guard let pointer else { return body(nil, 0) }
            return body(UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), strlen(pointer))
        }
    }
    guard let password = options.password, !password.isEmpty else {
        return body(nil, 0)
    }
    var bytes = Array(password.utf8)
    defer {
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            memset(baseAddress, 0, buffer.count)
        }
    }
    return bytes.withUnsafeBufferPointer { body($0.baseAddress, $0.count) }
}
