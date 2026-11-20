import CoreGraphics
import Foundation
import IronRDPBridge

/// IronRDP engine session over the `CNDFIronRDP.h` ABI v0. Mirrors `RDPSession`'s contract:
/// callbacks arrive on engine threads, frames are copied into `RDPFrame` and handed to the
/// existing `didReceiveFrame` path, and certificate trust uses the FreeRDP-compatible PEM key.
///
/// Clipboard, drive redirection, sound and output suppression are not supported (M1); the
/// corresponding options are ignored rather than pretending to be on.
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
    private var pendingTrust: CertificateTrustDecision?
    private var trustClosed = false
    private var lastRemotePointer: RDPRemotePointer?
    private var logFileURL: URL?
    private let logLock = NSLock()
    private let statisticsLock = NSLock()
    private var framesReceived: UInt64 = 0
    private var frameBytesReceived: UInt64 = 0
    private var startedAt: Date?
    private var lastActivityAt: Date?

    public convenience init(resizeCoordinator: DisplayResizeCoordinator = DisplayResizeCoordinator()) throws {
        try self.init(resizeCoordinator: resizeCoordinator, certificateTrustTimeout: 120)
    }

    init(resizeCoordinator: DisplayResizeCoordinator, certificateTrustTimeout: TimeInterval) throws {
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
            guard session.isCallbackCurrent(generation) else { return }
            let description = utf8String(bytes, length)
            session.emitLog("IronRDP connect failed: \(description) [\(String(format: "0x%08x", code))].")
            session.delegate?.rdpSession(
                session,
                didFailWith: RDPSessionError(ironKind: kind, code: code, stage: RDPConnectStage(stage), description: description)
            )
        }
        callbacks.disconnect = { generation, kind, code, context in
            guard let context else { return }
            let session = Unmanaged<IronRDPSession>.fromOpaque(context).takeUnretainedValue()
            guard session.isCallbackCurrent(generation) else { return }
            session.lastRemotePointer = nil
            session.emitLog("IronRDP disconnected.")
            session.delegate?.rdpSession(session, didDisconnectWith: RDPDisconnectReason(ironKind: kind, code: code))
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
    }

    deinit {
        tearDownNativeSession()
    }

    public var engine: RDPEngineKind { .ironRDP }
    public var supportsClipboard: Bool { engine.supportsClipboard }
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
        statisticsLock.lock()
        defer { statisticsLock.unlock() }
        return RDPConnectionStatistics(
            framesReceived: framesReceived,
            frameBytesReceived: frameBytesReceived,
            remoteClipboardTextsReceived: 0,
            remoteFilesReceived: 0,
            remoteFileBytesReceived: 0,
            localClipboardTextsSent: 0,
            localFilesOffered: 0,
            localFileBytesOffered: 0,
            startedAt: startedAt,
            lastActivityAt: lastActivityAt,
            networkBandwidthKbps: nil,
            networkBaseRTTMs: nil,
            networkAverageRTTMs: nil
        )
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

            // Held across connect so the first callbacks of the new generation wait for it
            // to be recorded instead of being dropped as stale.
            callbackLock.lock()
            trustClosed = false
            var generation: UInt64 = 0
            let status = options.host.withCString { hostPointer in
                (options.username ?? "").withCString { usernamePointer in
                    withOptionalCString(options.domain) { domainPointer in
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
                                log_level: options.logLevel.ironLogLevel
                            )
                            return cndf_iron_connect(nativeSession, &nativeOptions, passwordPointer, passwordLength, &generation)
                        }
                    }
                }
            }
            if status == CNDF_IRON_OK {
                callbackGeneration = generation
            }
            callbackLock.unlock()

            try throwIfNeeded(status)
            nativeGeneration = generation
            inputConnectionGeneration &+= 1
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
    public func disconnect() throws {
        tearDownNativeSession()
    }

    public func pollLocalClipboard() throws {}

    public func sendLocalFiles(_ urls: [URL]) throws {
        throw RDPSessionError.configurationInvalid(reason: "IronRDP does not support clipboard file transfer.")
    }

    public func sendLocalText(_ text: String) throws {
        throw RDPSessionError.configurationInvalid(reason: "IronRDP does not support clipboard redirection.")
    }

    /// A forced update (`sendForcedDesktopSize`) re-delivers the current framebuffer without a
    /// server round trip; a resize is only requested when the size actually changed.
    public func updateDesktopSize(pointWidth: Double, pointHeight: Double, scale: Double, force: Bool = false) throws {
        guard let size = resizeCoordinator.sizeToSend(
            pointWidth: pointWidth,
            pointHeight: pointHeight,
            scale: scale,
            force: force,
            preferDeviceNativeResolution: lastConnectionOptions?.preferDeviceNativeResolution ?? true,
            forcedDesktopSize: lastConnectionOptions?.forcedDesktopSize
        ) else {
            return
        }

        try withSessionLock {
            guard let nativeSession else {
                throw RDPSessionError.unableToCreateBridgeSession
            }
            if force {
                // Best effort: before the first frame there is nothing to re-deliver.
                _ = cndf_iron_redeliver_frame(nativeSession, nativeGeneration)
            }
            guard size != currentDesktopSize else { return }
            try throwIfNeeded(
                cndf_iron_resize(nativeSession, nativeGeneration, size.pixelWidth, size.pixelHeight, scalePercent(size.scale))
            )
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

    // Pointer and disconnect callbacks are serialized on the delivery thread.
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

    private func send(_ event: CNDFIronInputEvent) throws {
        try withSessionLock {
            guard let nativeSession else {
                throw RDPSessionError.unableToCreateBridgeSession
            }
            var event = event
            try throwIfNeeded(cndf_iron_send_input(nativeSession, nativeGeneration, &event, 1, Self.inputTimeoutMs))
        }
    }

    private func tearDownNativeSession() {
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
            return handle
        }
        guard let handle else { return }
        _ = cndf_iron_disconnect(handle)
        cndf_iron_session_destroy(handle, Self.destroyJoinTimeoutMs)
        callbackLock.lock()
        callbackGeneration = nil
        callbackLock.unlock()
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
        statisticsLock.lock()
        framesReceived += 1
        frameBytesReceived += UInt64(byteCount)
        lastActivityAt = Date()
        statisticsLock.unlock()
    }

    private func resetStatistics() {
        statisticsLock.lock()
        framesReceived = 0
        frameBytesReceived = 0
        startedAt = Date()
        lastActivityAt = startedAt
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
