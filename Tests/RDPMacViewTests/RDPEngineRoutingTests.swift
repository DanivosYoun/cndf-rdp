import AppKit
import CoreVideo
import RDPClientCore
import XCTest
@testable import RDPMacView

/// IronRDP routing in `RDPConnectionView` and the IronRDP session behind the existing view,
/// executor and shutdown paths. Tests marked "stub" need the C1 stub `libcndf_ironrdp.a`.
@MainActor
final class RDPEngineRoutingTests: XCTestCase {
    func testConnectCreatesAnIronRDPSession() throws {
        let view = RDPConnectionView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        XCTAssertNil(view.engine)
        try view.connect(RDPConnectionOptions(host: "127.0.0.1", port: 9, username: "routing"))
        XCTAssertEqual(view.engine, .ironRDP)
        view.shutdown()
        XCTAssertNil(view.engine)
    }

    // stub
    func testFramesReachTheTapAndNothingArrivesAfterShutdown() throws {
        try skipUnlessStub()
        let view = RDPConnectionView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let delegate = EngineViewDelegate(trust: true)
        view.delegate = delegate
        var tapped = 0
        view.onRenderedFrame = { _, _ in tapped += 1 }
        try view.connect(RDPConnectionOptions(host: "localhost", username: "stub"))

        XCTAssertTrue(waitUntil { tapped > 0 && delegate.connectedChanges.contains(true) })
        XCTAssertTrue(view.isConnected)
        XCTAssertGreaterThan(view.statistics?.framesReceived ?? 0, 0)

        let diagnostics = view.shutdown()
        XCTAssertTrue(diagnostics.didWaitForSession)
        let afterShutdown = (tapped, delegate.eventCount)
        drainRunLoop(0.3)
        XCTAssertEqual(tapped, afterShutdown.0)
        XCTAssertEqual(delegate.eventCount, afterShutdown.1)
    }

    // stub
    func testShutdownWithACertificatePromptOpenStaysUnderOneSecond() throws {
        try skipUnlessStub()
        let view = RDPConnectionView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let delegate = EngineViewDelegate(trust: nil)
        view.delegate = delegate
        try view.connect(RDPConnectionOptions(host: "localhost", username: "stub"))
        XCTAssertTrue(waitUntil { delegate.trustRequests == 1 })

        let started = Date()
        let diagnostics = view.shutdown()
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0)
        XCTAssertTrue(diagnostics.didWaitForSession)
        XCTAssertFalse(view.isConnected)
        let events = delegate.eventCount
        drainRunLoop(0.3)
        XCTAssertEqual(delegate.eventCount, events)
        XCTAssertFalse(delegate.connectedChanges.contains(true))
    }

    // stub: the shared-input executor sends through the IronRDP session on the wire.
    func testSharedInputCloseReleasesHeldKeyThroughIronRDP() async throws {
        try skipUnlessStub()
        let native = try IronRDPSession()
        let counter = FrameCounter()
        native.delegate = counter
        try native.connect(RDPConnectionOptions(host: "localhost", username: "stub"), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        let ready = await eventually { native.isConnected && counter.frames == 1 }
        XCTAssertTrue(ready)

        let queue = DispatchQueue(label: "test.iron.input")
        let executor = RDPInputExecutorRegistry.executor(for: native, schedule: { work in queue.async { work() } })
        let share = executor.makeSharedSession()
        XCTAssertTrue(share.activate())
        XCTAssertTrue(share.submit(.key(scanCode: 0x1E, pressed: true, modifiers: [])))
        let echoed = await eventually { counter.frames == 2 }
        XCTAssertTrue(echoed, "stub echoes one frame per input")

        share.beginClose()
        let result = await share.finishClose()
        XCTAssertEqual(result, .released)
        let released = await eventually { counter.frames == 3 }
        XCTAssertTrue(released, "close sends the key-up")

        try native.disconnect()
        let reshare = executor.makeSharedSession()
        XCTAssertFalse(reshare.activate(), "a disconnected session cannot activate sharing")
    }
}

private final class EngineViewDelegate: RDPConnectionViewDelegate {
    private let lock = NSLock()
    private let trust: Bool?
    private var storedTrustRequests = 0
    private var storedEvents = 0
    var connectedChanges: [Bool] = []

    init(trust: Bool?) {
        self.trust = trust
    }

    var trustRequests: Int { lock.withLock { storedTrustRequests } }
    var eventCount: Int { lock.withLock { storedEvents } }

    func rdpConnectionView(_ view: RDPConnectionView, didChangeConnected connected: Bool) {
        connectedChanges.append(connected)
        lock.withLock { storedEvents += 1 }
    }

    func rdpConnectionView(_ view: RDPConnectionView, didLog message: String) {
        lock.withLock { storedEvents += 1 }
    }

    func rdpConnectionView(
        _ view: RDPConnectionView,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool {
        lock.withLock { storedTrustRequests += 1 }
        guard let trust else {
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            return true
        }
        return trust
    }
}

private final class FrameCounter: RDPSessionDelegate {
    private let lock = NSLock()
    private var count = 0
    var frames: Int { lock.withLock { count } }

    func rdpSession(_ session: RDPEngineSession, didLog message: String) {}
    func rdpSession(
        _ session: RDPEngineSession,
        shouldTrustCertificateFingerprint fingerprint: String,
        hostname: String,
        port: UInt16
    ) async -> Bool { true }
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteText text: String) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveFrame frame: RDPFrame) {
        lock.withLock { count += 1 }
    }
}

private func skipUnlessStub() throws {
    try XCTSkipUnless(
        IronRDPSession.engineVersion.hasSuffix("patches=0"),
        "needs the C1 stub library (Scripts/build-ironrdp.sh --no-default-features --features stub)"
    )
}

private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return true
}

private func drainRunLoop(_ duration: TimeInterval) {
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}

private func eventually(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}
