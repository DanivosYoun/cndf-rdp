import AppKit
import ClipboardBridge
import FileTransferStaging
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

    func testEngineCapabilitiesMatchABIv1() throws {
        let session = try IronRDPSession()
        XCTAssertEqual(session.engine, .ironRDP)
        XCTAssertEqual(cndf_iron_abi_version(), 1)
        XCTAssertEqual(cndf_iron_capabilities(), 0xF)
        XCTAssertTrue(session.supportsClipboard)
        XCTAssertTrue(RDPEngineKind.ironRDP.supportsDriveRedirection)
        XCTAssertTrue(RDPEngineKind.ironRDP.supportsAudioPlayback(.disabled))
        XCTAssertTrue(RDPEngineKind.ironRDP.supportsAudioPlayback(.playLocally))
        XCTAssertTrue(RDPEngineKind.ironRDP.supportsAudioPlayback(.playOnRemote))
        XCTAssertFalse(session.supportsOutputSuppression)
        XCTAssertNoThrow(try session.pollLocalClipboard())
        XCTAssertThrowsError(try session.sendLocalText("x"))
        XCTAssertThrowsError(try session.setOutputSuppressed(true))
    }

    func testRejectedConnectDoesNotAdvanceTheGeneration() throws {
        let session = try IronRDPSession()
        let generation = session.connectionGeneration
        XCTAssertThrowsError(try session.connect(RDPConnectionOptions(host: ""), initialPointSize: .zero, scale: 1))
        XCTAssertEqual(session.connectionGeneration, generation)
        XCTAssertFalse(session.isConnected)
        XCTAssertThrowsError(try session.sendKey(keyCode: 0x1E, pressed: true, extended: false))
    }

    func testInvalidDrivePathIsRejectedBeforeConnecting() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let session = try IronRDPSession()
        let recorder = Recorder()
        session.delegate = recorder
        let options = RDPConnectionOptions(
            host: "localhost", enableClipboard: false,
            redirectedFolderPath: file.path, redirectedFolderName: "Home",
            audioPlaybackMode: .playOnRemote
        )
        XCTAssertThrowsError(try session.connect(options, initialPointSize: CGSize(width: 800, height: 600), scale: 1)) {
            XCTAssertEqual($0 as? RDPSessionError, .bridgeRejectedOperation(Int32(CNDF_IRON_INVALID_ARGUMENT.rawValue)))
        }
        XCTAssertEqual(session.connectionGeneration, 0)
        XCTAssertEqual(recorder.logs.dropFirst().first, "RDP channels clipboard=off folder=on audio=remote")
        XCTAssertEqual(recorder.logs.dropFirst(2).first, "RDP keyboard profile=standard layout=0x0 type=4 subtype=0 fn=12")
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

    // stub
    func testLifecycleForFailureAndForDisconnectWhileConnecting() throws {
        try skipUnlessStub()

        // Async certificate rejection.
        let ironFailure = Recorder(trust: false)
        let iron = try IronRDPSession()
        iron.delegate = ironFailure
        try iron.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { ironFailure.lifecycle.count == 2 })
        XCTAssertEqual(ironFailure.lifecycle, ["failure", "disconnect:error"])
        try iron.disconnect()
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertEqual(ironFailure.lifecycle, ["failure", "disconnect:error"])

        // Local disconnect with an unanswered certificate prompt.
        let ironConnecting = Recorder(trust: nil)
        let iron2 = try IronRDPSession()
        iron2.delegate = ironConnecting
        try iron2.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { ironConnecting.trustRequests.count == 1 })
        try iron2.disconnect()
        XCTAssertEqual(ironConnecting.lifecycle, ["disconnect:localRequest"])
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertEqual(ironConnecting.lifecycle, ["disconnect:localRequest"])
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
    func testForcedUpdateRedeliversFrameWhenTheSizeIsUnchanged() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        try session.connect(options(), initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        XCTAssertTrue(waitUntil { session.isConnected && recorder.frameCount == 1 })

        // A same-size update redelivers the cached frame without asking for a resize.
        try session.updateDesktopSize(pointWidth: 640, pointHeight: 480, scale: 1, force: true)
        XCTAssertTrue(waitUntil { recorder.frameCount == 2 })
        XCTAssertEqual(recorder.lastFrameSize, CGSize(width: 640, height: 480))
        try session.disconnect()
    }

    func testClipboardStubRoundTripsTextAndFilesOnNamedPasteboard() throws {
        try skipUnlessStub()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = FileTransferStaging(rootURL: root.appendingPathComponent("staging"))
        let session = try IronRDPSession(resizeCoordinator: DisplayResizeCoordinator(), certificateTrustTimeout: 5, staging: staging)
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        defer { try? session.disconnect() }
        try session.connect(RDPConnectionOptions(host: "localhost", pasteboardName: board.name.rawValue),
                            initialPointSize: CGSize(width: 800, height: 600), scale: 1)
        XCTAssertTrue(waitUntil { session.isConnected })

        board.clearContents()
        XCTAssertTrue(board.setString("한글 🖥️", forType: .string))
        try session.pollLocalClipboard()
        XCTAssertTrue(waitUntil { recorder.clipboardTexts == ["한글 🖥️"] })
        XCTAssertEqual(board.string(forType: .string), "한글 🖥️")
        try session.pollLocalClipboard()
        XCTAssertEqual(session.statistics.remoteClipboardTextsReceived, 1)

        let nfd = "한글.txt".decomposedStringWithCanonicalMapping
        let file = root.appendingPathComponent(nfd)
        let data = Data(repeating: 0xA5, count: 1024 * 1024 + 3)
        try data.write(to: file)
        try session.sendLocalFiles([file])
        XCTAssertTrue(waitUntil { !recorder.clipboardFiles.isEmpty })
        let entry = try XCTUnwrap(recorder.clipboardFiles.first)
        XCTAssertEqual(Array(entry.fileName.utf8), Array("한글.txt".utf8))
        XCTAssertTrue(waitUntil {
            (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count == 1
        })
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), data)
        XCTAssertEqual(session.statistics.localFilesOffered, 1)
        XCTAssertEqual(session.statistics.remoteFileBytesReceived, UInt64(data.count))
    }

    func testFileOfferOmissionsDoNotReachNativeSink() throws {
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temp) }
        let file = temp.appendingPathComponent("fixture")
        try Data([1]).write(to: file)
        let link = temp.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        let missing = temp.appendingPathComponent("missing")
        let staging = FileTransferStaging(rootURL: temp.appendingPathComponent("staging"))

        var attempts = 0
        let iron = IronRDPClipboardSink(staging: staging) { _ in attempts += 1 }
        let onlyOmitted = ClipboardFileOffer(providedCount: 0, providedBytes: 0, omittedCount: 1)
        XCTAssertEqual(try iron.sendLocalFiles([link]), onlyOmitted)
        XCTAssertThrowsError(try iron.sendLocalFiles([file, missing]))
        XCTAssertEqual(attempts, 0)
        XCTAssertEqual(try iron.sendLocalFiles([file, link]),
                       ClipboardFileOffer(providedCount: 1, providedBytes: 1, omittedCount: 1))
        XCTAssertEqual(attempts, 1)

        // A native FreeRDP offer on this disconnected session would throw.
        let free = try IronRDPSession(staging: staging)
        XCTAssertEqual(try free.sendLocalFiles([link]), onlyOmitted)
        XCTAssertThrowsError(try free.sendLocalFiles([file, link]))
    }

    /// T-M5: an empty folder offered through the stub (which echoes names) arrives as an empty directory.
    func testClipboardStubRoundTripsEmptyFolder() throws {
        try skipUnlessStub()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("M", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: folder.appendingPathComponent("f.txt"))
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = FileTransferStaging(rootURL: root.appendingPathComponent("staging"))
        let session = try IronRDPSession(resizeCoordinator: DisplayResizeCoordinator(), certificateTrustTimeout: 5, staging: staging)
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        defer { try? session.disconnect() }
        try session.connect(RDPConnectionOptions(host: "localhost", pasteboardName: board.name.rawValue),
                            initialPointSize: CGSize(width: 800, height: 600), scale: 1)
        XCTAssertTrue(waitUntil { session.isConnected })

        try session.sendLocalFiles([folder])
        XCTAssertTrue(waitUntil {
            (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count == 1
        })
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
        let received = try XCTUnwrap(urls.first)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: received.appendingPathComponent("empty").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: received.appendingPathComponent("empty").path), [])
        XCTAssertEqual(try Data(contentsOf: received.appendingPathComponent("f.txt")), Data("abc".utf8))
    }

    func testClipboardCallbacksAreDroppedAcrossDisconnectAndReconnect() throws {
        try skipUnlessStub()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let session = try IronRDPSession()
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        defer { try? session.disconnect() }
        try session.connect(RDPConnectionOptions(host: "localhost", pasteboardName: board.name.rawValue),
                            initialPointSize: CGSize(width: 800, height: 600), scale: 1)
        XCTAssertTrue(waitUntil { session.isConnected })
        let connection = session.connectionGeneration

        let text = Array("stale".utf8)
        text.withUnsafeBufferPointer {
            session.callbacks.remote_text?(99, $0.baseAddress, $0.count, session.callbacks.context)
            session.callbacks.remote_text?(1, $0.baseAddress, $0.count, session.callbacks.context)
        }
        try session.reconnect()
        XCTAssertTrue(waitUntil { session.isConnected })
        try session.sendLocalText("current")
        XCTAssertTrue(waitUntil { recorder.clipboardTexts.contains("current") })
        XCTAssertEqual(recorder.clipboardTexts, ["current"])
        XCTAssertEqual(board.string(forType: .string), "current")

        try session.disconnect()
        XCTAssertThrowsError(try session.requestRemoteFileRange(connection: connection, stream: 2, index: 0, offset: 1024 * 1024, length: 1)) {
            XCTAssertEqual($0 as? RDPSessionError, .bridgeRejectedOperation(Int32(CNDF_IRON_NOT_CONNECTED.rawValue)))
        }
        text.withUnsafeBufferPointer {
            session.callbacks.remote_text?(1, $0.baseAddress, $0.count, session.callbacks.context)
        }
        let mainQueueDrained = expectation(description: "main queue drained")
        DispatchQueue.main.async { mainQueueDrained.fulfill() }
        wait(for: [mainQueueDrained], timeout: 2)
        XCTAssertEqual(recorder.clipboardTexts, ["current"])
        XCTAssertEqual(board.string(forType: .string), "current")
    }

    func testClipboardStubReportsRejectedRangeWithoutChangingPasteboard() throws {
        try skipUnlessStub()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setString("unchanged", forType: .string)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("session.log")
        let session = try IronRDPSession(
            resizeCoordinator: DisplayResizeCoordinator(),
            certificateTrustTimeout: 5,
            staging: FileTransferStaging(rootURL: root)
        )
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        defer { try? session.disconnect() }
        try session.connect(RDPConnectionOptions(host: "localhost", logFileURL: log, pasteboardName: board.name.rawValue),
                            initialPointSize: CGSize(width: 800, height: 600), scale: 1)
        XCTAssertTrue(waitUntil { session.isConnected })

        let missing = root.appendingPathComponent("missing.txt")
        XCTAssertThrowsError(try session.sendLocalFiles([missing]))
        board.clearContents()
        board.writeObjects([missing as NSURL])
        XCTAssertThrowsError(try session.pollLocalClipboard())
        board.clearContents()
        board.setString("unchanged", forType: .string)

        // The stub has no file at index zero. Its range reply must drive the failure path.
        Array("unavailable.txt".utf8).withUnsafeBufferPointer { name in
            var file = CNDFIronRemoteFile(name_utf8: name.baseAddress, name_length: name.count, size: 1)
            session.callbacks.remote_file_list?(1, &file, 1, session.callbacks.context)
        }
        XCTAssertTrue(waitUntil(timeout: 3) {
            recorder.logs.contains { $0.hasPrefix("Remote file materialization failed:") }
        })
        let contents = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(contents.contains("Local file offer failed:"))
        XCTAssertTrue(contents.contains("Local clipboard sync failed:"))
        XCTAssertTrue(contents.contains("Remote file materialization failed:"))
        XCTAssertEqual(board.string(forType: .string), "unchanged")
    }

    func testFileDownloadRequestsOneMiBAndFailsImmediatelyOnNegativeResponse() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstChunk: UInt32 = 1024 * 1024
        var offsets: [UInt64] = []
        var lengths: [UInt32] = []
        var manager: RDPRemoteFileDownloadManager!
        manager = RDPRemoteFileDownloadManager(staging: FileTransferStaging(rootURL: root)) { stream, _, offset, length in
            offsets.append(offset)
            lengths.append(length)
            if offset == 0 {
                manager.receive(streamId: stream, data: Data(count: Int(length)))
            } else {
                manager.fail(streamId: stream)
            }
        }
        defer { manager = nil }
        manager.fail(streamId: 1) // unsolicited responses cannot poison future requests
        let start = Date()
        XCTAssertThrowsError(try manager.materialize([
            RDPFileListEntry(fileName: "partial.txt", byteCount: UInt64(firstChunk) + 1, localURL: nil)
        ]))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(offsets, [0, UInt64(firstChunk)])
        XCTAssertEqual(lengths, [firstChunk, 1])
    }

    func testIronRDPRemoteFileListKeepsTraversalAbsoluteAndSymlinkInsideStagingRoot() throws {
        try skipUnlessStub()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ironrdp-drop-\(UUID().uuidString)", isDirectory: true)
        let stagingDir = tempRoot.appendingPathComponent("a/b/staging", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let outsideSentinel = tempRoot.appendingPathComponent("outside.txt")
        let sentinelData = Data("sentinel".utf8)
        try sentinelData.write(to: outsideSentinel)

        let plantedLink = stagingDir.appendingPathComponent("planted.txt")
        try FileManager.default.createSymbolicLink(at: plantedLink, withDestinationURL: outsideSentinel)

        let seedPayload = Data("hello".utf8)
        let seedFile = tempRoot.appendingPathComponent("seed.txt")
        try seedPayload.write(to: seedFile)

        let session = try IronRDPSession(
            resizeCoordinator: DisplayResizeCoordinator(),
            certificateTrustTimeout: 5,
            staging: FileTransferStaging(rootURL: stagingDir)
        )
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        defer { try? session.disconnect() }
        try session.connect(
            RDPConnectionOptions(host: "localhost", pasteboardName: board.name.rawValue),
            initialPointSize: CGSize(width: 800, height: 600),
            scale: 1
        )
        XCTAssertTrue(waitUntil { session.isConnected })

        // Offer distinct names so the stub can answer ranges for indices 0, 1, and 2.
        let additionalSeeds = [tempRoot.appendingPathComponent("seed-2.txt"), tempRoot.appendingPathComponent("seed-3.txt")]
        for seed in additionalSeeds { try seedPayload.write(to: seed) }
        try session.sendLocalFiles([seedFile] + additionalSeeds)
        XCTAssertTrue(waitUntil {
            (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count == 3
        })
        board.clearContents()

        let absTarget = tempRoot.appendingPathComponent("absolute.txt")
        let maliciousNames = [
            "../../../escape.txt",
            absTarget.path,
            "planted.txt"
        ]
        let nameBuffers = maliciousNames.map { Array($0.utf8) }
        nameBuffers[0].withUnsafeBufferPointer { n0 in
            nameBuffers[1].withUnsafeBufferPointer { n1 in
                nameBuffers[2].withUnsafeBufferPointer { n2 in
                    let files = [
                        CNDFIronRemoteFile(name_utf8: n0.baseAddress, name_length: n0.count, size: UInt64(seedPayload.count)),
                        CNDFIronRemoteFile(name_utf8: n1.baseAddress, name_length: n1.count, size: UInt64(seedPayload.count)),
                        CNDFIronRemoteFile(name_utf8: n2.baseAddress, name_length: n2.count, size: UInt64(seedPayload.count))
                    ]
                    files.withUnsafeBufferPointer { buffer in
                        session.callbacks.remote_file_list?(1, buffer.baseAddress, buffer.count, session.callbacks.context)
                    }
                }
            }
        }

        XCTAssertTrue(waitUntil(timeout: 5) {
            (board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.count == 3
        })
        let urls = try XCTUnwrap(board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])
        let expectedRoot = stagingDir.standardizedFileURL.path
        for url in urls {
            XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL.path, expectedRoot)
            XCTAssertEqual(try Data(contentsOf: url), seedPayload)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempRoot.appendingPathComponent("escape.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: absTarget.path))
        XCTAssertEqual(try Data(contentsOf: outsideSentinel), sentinelData)
        XCTAssertEqual(urls[2].lastPathComponent, "planted 1.txt")
    }

    func testAudioWavesReceivedExposedFromABIAndPreservedAfterDisconnect() throws {
        try skipUnlessStub()
        let session = try IronRDPSession()
        let recorder = Recorder(trust: true)
        session.delegate = recorder
        defer { try? session.disconnect() }

        try session.connect(
            RDPConnectionOptions(host: "localhost", audioPlaybackMode: .playLocally),
            initialPointSize: CGSize(width: 800, height: 600),
            scale: 1
        )
        XCTAssertTrue(waitUntil { session.isConnected })
        XCTAssertGreaterThanOrEqual(session.statistics.audioWavesReceived, 1)
        let wavesWhileConnected = session.statistics.audioWavesReceived
        try session.disconnect()
        XCTAssertEqual(session.statistics.audioWavesReceived, wavesWhileConnected)

        try session.connect(
            RDPConnectionOptions(host: "localhost", audioPlaybackMode: .disabled),
            initialPointSize: CGSize(width: 800, height: 600),
            scale: 1
        )
        XCTAssertTrue(waitUntil { session.isConnected })
        XCTAssertEqual(session.statistics.audioWavesReceived, 0)
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

private final class Recorder: RDPSessionDelegate {
    private let lock = NSLock()
    private var trust: Bool?
    private var storedLogs: [String] = []
    private var storedClipboardTexts: [String] = []
    private var storedClipboardFiles: [RDPRemoteFile] = []
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

    var clipboardTexts: [String] { locked { storedClipboardTexts } }
    var clipboardFiles: [RDPRemoteFile] { locked { storedClipboardFiles } }

    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteText text: String) {
        XCTAssertTrue(Thread.isMainThread)
        locked { storedClipboardTexts.append(text) }
    }

    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {
        XCTAssertTrue(Thread.isMainThread)
        locked { storedClipboardFiles.append(contentsOf: files) }
    }

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


    func rdpSession(_ session: RDPEngineSession, didReceiveFrame frame: RDPFrame) {
        locked { storedFrames.append(CGSize(width: frame.width, height: frame.height)); storedEvents += 1 }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
