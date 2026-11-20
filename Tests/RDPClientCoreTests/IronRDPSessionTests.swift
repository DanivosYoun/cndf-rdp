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

    private func options(logFileURL: URL? = nil) -> RDPConnectionOptions {
        RDPConnectionOptions(
            host: "localhost",
            username: "stub",
            securePassword: RDPSecureString(secret),
            logFileURL: logFileURL
        )
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

/// Thread-safe delegate. `trust == nil` never answers a certificate prompt.
private final class Recorder: RDPSessionDelegate {
    private let lock = NSLock()
    private let trust: Bool?
    private var storedLogs: [String] = []
    private var storedTrustRequests: [String] = []
    private var storedErrors: [RDPSessionError] = []
    private var storedFrames: [CGSize] = []
    private var storedEvents = 0

    init(trust: Bool? = false) {
        self.trust = trust
    }

    var logs: [String] { locked { storedLogs } }
    var trustRequests: [String] { locked { storedTrustRequests } }
    var errors: [RDPSessionError] { locked { storedErrors } }
    var frameCount: Int { locked { storedFrames.count } }
    var lastFrameSize: CGSize? { locked { storedFrames.last } }
    var eventCount: Int { locked { storedEvents } }

    func rdpSession(_ session: RDPEngineSession, didLog message: String) {
        locked { storedLogs.append(message); storedEvents += 1 }
    }

    func rdpSession(
        _ session: RDPEngineSession,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool {
        locked { storedTrustRequests.append(fingerprint); storedEvents += 1 }
        guard let trust else {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return true
        }
        return trust
    }

    func rdpSession(_ session: RDPEngineSession, didFailWith error: RDPSessionError) {
        locked { storedErrors.append(error); storedEvents += 1 }
    }

    func rdpSession(_ session: RDPEngineSession, didDisconnectWith reason: RDPDisconnectReason) {
        locked { storedEvents += 1 }
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
