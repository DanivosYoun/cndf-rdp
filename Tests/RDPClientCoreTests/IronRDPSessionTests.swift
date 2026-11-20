import Foundation
import IronRDPBridge
import XCTest
@testable import RDPClientCore

/// Tests marked "stub" need `libcndf_ironrdp.a` built with `--no-default-features --features stub`
/// (C1 stub: one certificate callback with DER `30 00`, a test-pattern frame, one frame echo per
/// input). Against the real engine they are skipped; the rest run with either library.
final class IronRDPSessionTests: XCTestCase {
    private let secret = "never-logged-\(UUID().uuidString)"

    func testFailureKindsMapOntoTheSharedSessionErrors() {
        let cases: [(CNDFIronFailureKind, RDPSessionError)] = [
            (CNDF_IRON_FAILURE_NETWORK, .networkUnreachable(underlying: "d", code: 0x49520003, stage: .negotiation)),
            (CNDF_IRON_FAILURE_TLS, .tlsHandshakeFailed(reason: "d", code: 0x49520003, stage: .negotiation)),
            (CNDF_IRON_FAILURE_AUTHENTICATION, .authenticationFailed),
            (CNDF_IRON_FAILURE_CERTIFICATE, .certificateRejected),
            (CNDF_IRON_FAILURE_CONFIGURATION, .configurationInvalid(reason: "d")),
            (CNDF_IRON_FAILURE_ENGINE, .ironrdp(code: 0x49520003, description: "d"))
        ]
        for (kind, expected) in cases {
            XCTAssertEqual(
                RDPSessionError(ironKind: kind, code: 0x49520003, stage: RDPConnectStage(CNDF_IRON_STAGE_NEGOTIATION), description: "d"),
                expected
            )
        }
    }

    func testEngineCapabilitiesAreReportedOff() throws {
        let session = try IronRDPSession()
        XCTAssertEqual(session.engine, .ironRDP)
        XCTAssertFalse(session.supportsClipboard)
        XCTAssertFalse(session.supportsOutputSuppression)
        XCTAssertNoThrow(try session.pollLocalClipboard())
        XCTAssertThrowsError(try session.sendLocalText("x"))
        XCTAssertThrowsError(try session.setOutputSuppressed(true))
        XCTAssertEqual(try RDPSession().engine, .freeRDP)
        XCTAssertTrue(try RDPSession().supportsClipboard)
    }

    func testRejectedConnectDoesNotAdvanceTheGeneration() throws {
        let session = try IronRDPSession()
        let generation = session.connectionGeneration
        XCTAssertThrowsError(try session.connect(RDPConnectionOptions(host: ""), initialPointSize: .zero, scale: 1))
        XCTAssertEqual(session.connectionGeneration, generation)
        XCTAssertFalse(session.isConnected)
        XCTAssertThrowsError(try session.sendKey(keyCode: 0x1E, pressed: true, extended: false))
    }

    func testCallbacksBeforeAnyConnectionAreDropped() throws {
        let session = try IronRDPSession()
        let recorder = Recorder()
        session.delegate = recorder
        deliverSyntheticFrame(to: session, generation: 1)
        session.callbacks.connected?(1, session.callbacks.context)
        XCTAssertEqual(recorder.frameCount, 0)
        XCTAssertTrue(recorder.logs.isEmpty)
    }

    // stub
    func testConnectsWithTrustKeyAndEchoesInputOnTheCurrentGeneration() throws {
        try skipUnlessStub()
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("iron-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let session = try IronRDPSession()
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        try session.connect(options(logFileURL: log), initialPointSize: CGSize(width: 800, height: 600), scale: 1)

        XCTAssertTrue(waitUntil { session.isConnected && recorder.frameCount == 1 })
        XCTAssertEqual(recorder.trustRequests, [RDPCertificateTrustString.freeRDPCompatible(derChain: [Data([0x30, 0x00])])])
        XCTAssertEqual(recorder.lastFrameSize, CGSize(width: 800, height: 600))
        XCTAssertEqual(session.statistics.framesReceived, 1)

        let generation = session.connectionGeneration
        XCTAssertTrue(session.isInputConnectionCurrent(generation: generation))
        XCTAssertFalse(session.isInputConnectionCurrent(generation: generation + 1))
        try session.sendKey(keyCode: 0x1E, pressed: true, extended: false)
        XCTAssertTrue(waitUntil { recorder.frameCount == 2 })

        // Callbacks carrying another native generation are discarded.
        deliverSyntheticFrame(to: session, generation: 99)
        session.callbacks.connected?(99, session.callbacks.context)
        XCTAssertEqual(recorder.frameCount, 2)
        XCTAssertEqual(recorder.logs.filter { $0 == "IronRDP connected." }.count, 1)

        try session.disconnect()
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(lines.first?.hasSuffix("RDP engine=ironrdp version=\(IronRDPSession.engineVersion)") == true)
        XCTAssertFalse(try String(contentsOf: log, encoding: .utf8).contains(secret))
        XCTAssertFalse(recorder.logs.joined().contains(secret))
    }

    // stub
    func testNoCallbackAfterDisconnectReturns() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 2)
        XCTAssertTrue(waitUntil { recorder.frameCount == 1 })
        XCTAssertEqual(recorder.lastFrameSize, CGSize(width: 1280, height: 960))

        try session.disconnect()
        let events = recorder.eventCount
        XCTAssertFalse(session.isConnected)
        XCTAssertThrowsError(try session.sendKey(keyCode: 0x1E, pressed: true, extended: false))
        deliverSyntheticFrame(to: session, generation: 1)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(recorder.eventCount, events)
    }

    // stub
    func testDisconnectRejectsAPendingCertificatePromptWithoutWaiting() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: nil)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { recorder.trustRequests.count == 1 })

        let started = Date()
        try session.disconnect()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(recorder.frameCount, 0)
        XCTAssertFalse(recorder.logs.contains("IronRDP connected."))
    }

    // stub
    func testUnansweredCertificatePromptIsRejectedAfterTheTimeout() throws {
        try skipUnlessStub()
        let session = try IronRDPSession(resizeCoordinator: DisplayResizeCoordinator(), certificateTrustTimeout: 0.2)
        let recorder = Recorder(trust: nil)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { recorder.errors.count == 1 })
        XCTAssertEqual(recorder.errors, [.certificateRejected])
        XCTAssertTrue(recorder.logs.contains { $0.hasPrefix("IronRDP connect failed: ") && $0.hasSuffix(" [0x49520002].") })
        XCTAssertEqual(recorder.frameCount, 0)
        try session.disconnect()
    }

    // stub
    func testReconnectStartsANewInputGeneration() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { session.isConnected })
        let first = session.connectionGeneration

        try session.reconnect()
        XCTAssertTrue(waitUntil { session.isConnected })
        XCTAssertEqual(session.connectionGeneration, first + 1)
        XCTAssertFalse(session.isInputConnectionCurrent(generation: first))
        var ran = false
        XCTAssertThrowsError(try session.withInputConnection(generation: first) { ran = true })
        XCTAssertFalse(ran)
        try session.disconnect()
    }

    // MARK: didDisconnectWith contract (finding ironrdp-missing-disconnect-leaves-zombie-session)
    //
    // FreeRDP reference (FreeRDPBridge.c rdp_event_loop / bridge_disconnect):
    // - async connect failure: failure, then exactly one disconnect(.error), from the worker.
    // - local disconnect while the worker runs (connecting or connected): exactly one
    //   disconnect(.localRequest) and no failure, delivered before `disconnect()` returns.
    // - `disconnect()` after the worker already ended: no further callback.

    // stub
    func testAsyncConnectFailureReportsFailureThenOneErrorDisconnect() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: false)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)

        XCTAssertTrue(waitUntil { recorder.lifecycle.count == 2 })
        XCTAssertEqual(recorder.lifecycle, ["failure", "disconnect:error"])
        XCTAssertEqual(recorder.errors, [.certificateRejected])

        try session.disconnect()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(recorder.lifecycle, ["failure", "disconnect:error"])
    }

    // stub. Nothing reaches the delegate between the failure and its disconnect: a view that
    // shuts down on the failure detaches its delegate, so a log line in between lost the
    // disconnect in the engine harness (cert-3-rejected).
    func testFailureIsFollowedDirectlyByItsErrorDisconnect() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: false, logsInLifecycle: true)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)

        XCTAssertTrue(waitUntil { recorder.lifecycle.contains("disconnect:error") })
        let lifecycle = recorder.lifecycle
        let failure = try XCTUnwrap(lifecycle.firstIndex(of: "failure"))
        XCTAssertEqual(Array(lifecycle[failure...].prefix(2)), ["failure", "disconnect:error"])
        try session.disconnect()
    }

    // stub
    func testLocalDisconnectOfAConnectedSessionReportsOneLocalRequestBeforeReturning() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { session.isConnected && recorder.frameCount == 1 })

        try session.disconnect()
        XCTAssertEqual(recorder.lifecycle, ["disconnect:localRequest"])
        try session.disconnect()
        deliverSyntheticDisconnect(to: session, generation: 1)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(recorder.lifecycle, ["disconnect:localRequest"])
    }

    // stub
    func testEngineDisconnectCallbackAndLocalDisconnectAreReportedOnce() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { session.isConnected })

        // The engine reported the end of this generation (server disconnect) first.
        deliverSyntheticDisconnect(to: session, generation: 1, kind: CNDF_IRON_DISCONNECT_SERVER)
        try session.disconnect()
        XCTAssertEqual(recorder.lifecycle, ["disconnect:server"])
    }

    // stub + real FreeRDP. Both engines, same observable lifecycle.
    func testLifecycleMatchesFreeRDPForFailureAndForDisconnectWhileConnecting() throws {
        try skipUnlessStub()

        // Async connect failure. FreeRDP: refused TCP port. IronRDP stub: rejected certificate.
        let freeRDPFailure = Recorder(trust: false)
        let freeRDP = try RDPSession()
        freeRDP.delegate = freeRDPFailure
        try freeRDP.connect(RDPConnectionOptions(host: "127.0.0.1", port: 1, username: "u", password: "p"), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil(timeout: 20) { freeRDPFailure.lifecycle.count == 2 })
        let ironFailure = Recorder(trust: false)
        let iron = try IronRDPSession()
        iron.delegate = ironFailure
        try iron.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { ironFailure.lifecycle.count == 2 })
        XCTAssertEqual(freeRDPFailure.lifecycle, ["failure", "disconnect:error"])
        XCTAssertEqual(ironFailure.lifecycle, freeRDPFailure.lifecycle)
        try freeRDP.disconnect()
        try iron.disconnect()
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(freeRDPFailure.lifecycle, ["failure", "disconnect:error"])
        XCTAssertEqual(ironFailure.lifecycle, freeRDPFailure.lifecycle)

        // Local disconnect while still connecting. FreeRDP: a local listener that accepts the
        // TCP handshake and never answers X.224. IronRDP stub: an unanswered certificate prompt.
        let silent = try SilentListener()
        defer { silent.close() }
        let freeRDPConnecting = Recorder(trust: false)
        let freeRDP2 = try RDPSession()
        freeRDP2.delegate = freeRDPConnecting
        try freeRDP2.connect(RDPConnectionOptions(host: "127.0.0.1", port: silent.port, username: "u", password: "p"), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(freeRDPConnecting.lifecycle, [])
        try freeRDP2.disconnect()
        let ironConnecting = Recorder(trust: nil)
        let iron2 = try IronRDPSession()
        iron2.delegate = ironConnecting
        try iron2.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { ironConnecting.trustRequests.count == 1 })
        try iron2.disconnect()
        XCTAssertEqual(freeRDPConnecting.lifecycle, ["disconnect:localRequest"])
        XCTAssertEqual(ironConnecting.lifecycle, freeRDPConnecting.lifecycle)
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(ironConnecting.lifecycle, freeRDPConnecting.lifecycle)
    }

    // MARK: resize (finding ironrdp-resize-state-desync-on-rejected-send)

    // stub
    func testRejectedResizeIsLoggedAndRetriedWithTheSameSize() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: nil)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { recorder.trustRequests.count == 1 })

        // Not connected yet: the engine rejects the resize with NOT_CONNECTED.
        XCTAssertThrowsError(try session.updateDesktopSize(pointWidth: 800, pointHeight: 600, scale: 1))
        XCTAssertTrue(recorder.logs.contains {
            $0 == "IronRDP resize to 800x600 rejected [\(CNDF_IRON_NOT_CONNECTED.rawValue)]."
        })

        recorder.answerTrust(true)
        XCTAssertTrue(waitUntil { session.isConnected && recorder.frameCount == 1 })
        XCTAssertEqual(recorder.lastFrameSize, CGSize(width: 640, height: 480))
        try session.updateDesktopSize(pointWidth: 800, pointHeight: 600, scale: 1)
        XCTAssertTrue(waitUntil { recorder.lastFrameSize == CGSize(width: 800, height: 600) })
        try session.disconnect()
    }

    // stub
    func testForcedResizeIsSentEvenWhenTheSizeIsUnchanged() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { session.isConnected && recorder.frameCount == 1 })

        // The stub answers a redelivery with one frame and a resize with another.
        try session.updateDesktopSize(pointWidth: 640, pointHeight: 480, scale: 1, force: true)
        XCTAssertTrue(waitUntil { recorder.frameCount == 3 })
        XCTAssertEqual(recorder.lastFrameSize, CGSize(width: 640, height: 480))
        try session.disconnect()
    }

    private func options(logFileURL: URL? = nil) -> RDPConnectionOptions {
        RDPConnectionOptions(
            host: "localhost",
            username: "stub",
            securePassword: RDPSecureString(secret),
            logFileURL: logFileURL
        )
    }

    private func deliverSyntheticDisconnect(
        to session: IronRDPSession,
        generation: UInt64,
        kind: CNDFIronDisconnectKind = CNDF_IRON_DISCONNECT_LOCAL_REQUEST
    ) {
        session.callbacks.disconnect?(generation, kind, 0, session.callbacks.context)
    }

    private func deliverSyntheticFrame(to session: IronRDPSession, generation: UInt64) {
        let pixels = [UInt8](repeating: 0xFF, count: 16)
        pixels.withUnsafeBufferPointer { buffer in
            session.callbacks.frame?(
                generation, buffer.baseAddress, 2, 2, 8,
                CNDFIronRect(x: 0, y: 0, width: 2, height: 2), 1, session.callbacks.context
            )
        }
    }
}

func skipUnlessStub() throws {
    try XCTSkipUnless(
        IronRDPSession.engineVersion.hasSuffix("patches=0"),
        "needs the C1 stub library (Scripts/build-ironrdp.sh --no-default-features --features stub)"
    )
}

func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return true
}

/// A loopback TCP listener that never accepts: the kernel completes the handshake from the
/// backlog, so a client stays in its connect sequence until it gives up or is stopped.
private final class SilentListener {
    private var descriptor: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        descriptor = fd
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Bool in
                bind(fd, pointer, length) == 0
                    && listen(fd, 4) == 0
                    && getsockname(fd, pointer, &length) == 0
            }
        }
        guard fd >= 0, bound else {
            if fd >= 0 { Darwin.close(fd) }
            throw RDPSessionError.configurationInvalid(reason: "listener")
        }
        port = UInt16(bigEndian: address.sin_port)
    }

    func close() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }
}

/// Thread-safe delegate. `trust == nil` never answers a certificate prompt.
private final class Recorder: RDPSessionDelegate {
    private let lock = NSLock()
    private var trust: Bool?
    private var storedLogs: [String] = []
    private var storedTrustRequests: [String] = []
    private var storedErrors: [RDPSessionError] = []
    private var storedFrames: [CGSize] = []
    private var storedEvents = 0
    private var storedLifecycle: [String] = []
    private let logsInLifecycle: Bool

    init(trust: Bool? = false, logsInLifecycle: Bool = false) {
        self.trust = trust
        self.logsInLifecycle = logsInLifecycle
    }

    var logs: [String] { locked { storedLogs } }
    var trustRequests: [String] { locked { storedTrustRequests } }
    var errors: [RDPSessionError] { locked { storedErrors } }
    var frameCount: Int { locked { storedFrames.count } }
    var lastFrameSize: CGSize? { locked { storedFrames.last } }
    var eventCount: Int { locked { storedEvents } }
    /// `failure` and `disconnect:<reason>` in delivery order, plus `log` with `logsInLifecycle`.
    var lifecycle: [String] { locked { storedLifecycle } }

    func answerTrust(_ trusted: Bool) {
        locked { trust = trusted }
    }

    func rdpSession(_ session: RDPEngineSession, didLog message: String) {
        locked {
            storedLogs.append(message)
            if logsInLifecycle { storedLifecycle.append("log") }
            storedEvents += 1
        }
    }

    func rdpSession(
        _ session: RDPEngineSession,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool {
        locked { storedTrustRequests.append(fingerprint); storedEvents += 1 }
        // Unanswered prompts poll for `answerTrust` and give up (accept) after 30 s.
        for _ in 0..<3000 {
            if let answer = locked({ self.trust }) { return answer }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }

    func rdpSession(_ session: RDPEngineSession, didFailWith error: RDPSessionError) {
        locked { storedErrors.append(error); storedLifecycle.append("failure"); storedEvents += 1 }
    }

    func rdpSession(_ session: RDPEngineSession, didDisconnectWith reason: RDPDisconnectReason) {
        let name: String
        switch reason {
        case .localRequest: name = "localRequest"
        case .serverDisconnect: name = "server"
        case .timeout: name = "timeout"
        case .error: name = "error"
        }
        locked { storedLifecycle.append("disconnect:\(name)"); storedEvents += 1 }
    }

    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteText text: String) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {}

    func rdpSession(_ session: RDPEngineSession, didReceiveFrame frame: RDPFrame) {
        locked { storedFrames.append(CGSize(width: frame.width, height: frame.height)); storedEvents += 1 }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
