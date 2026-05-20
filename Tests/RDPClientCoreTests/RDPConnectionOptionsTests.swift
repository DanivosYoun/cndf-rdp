import RDPClientCore
import XCTest

final class RDPConnectionOptionsTests: XCTestCase {
    func testDefaultsKeepRedirectionAndAudioDisabled() {
        let options = RDPConnectionOptions(host: "rdp.example")

        XCTAssertEqual(options.host, "rdp.example")
        XCTAssertEqual(options.port, 3389)
        XCTAssertTrue(options.enableClipboard)
        XCTAssertFalse(options.enableDriveRedirection)
        XCTAssertNil(options.redirectedFolderPath)
        XCTAssertNil(options.redirectedFolderName)
        XCTAssertEqual(options.audioPlaybackMode, .disabled)
        XCTAssertNil(options.logFileURL)
        XCTAssertEqual(options.logLevel, .info)
        XCTAssertTrue(options.logFilters.isEmpty)
    }

    func testStoresRedirectedFolderAndAudioOptions() {
        let logURL = URL(fileURLWithPath: "/tmp/rdp.log")
        let securePassword = RDPSecureString("secret")
        let options = RDPConnectionOptions(
            host: "rdp.example",
            securePassword: securePassword,
            redirectedFolderPath: "/Users/me/RDPShare",
            redirectedFolderName: "RemoteShare",
            audioPlaybackMode: .playLocally,
            logFileURL: logURL,
            logLevel: .debug,
            logFilters: ["com.freerdp.channels.cliprdr": .trace]
        )

        XCTAssertEqual(options.securePassword, securePassword)
        XCTAssertEqual(options.redirectedFolderPath, "/Users/me/RDPShare")
        XCTAssertEqual(options.redirectedFolderName, "RemoteShare")
        XCTAssertEqual(options.audioPlaybackMode, .playLocally)
        XCTAssertEqual(options.logFileURL, logURL)
        XCTAssertEqual(options.logLevel, .debug)
        XCTAssertEqual(options.logFilters["com.freerdp.channels.cliprdr"], .trace)
    }

    func testSecureStringCanBeZeroized() {
        let password = RDPSecureString("secret")
        var captured: String?
        password.withCString { pointer in
            captured = pointer.map(String.init(cString:))
        }
        XCTAssertEqual(captured, "secret")

        password.zeroize()
        password.withCString { pointer in
            XCTAssertNil(pointer)
        }
    }

    func testExposesBuildInfo() {
        XCTAssertFalse(RDPMacInfo.packageVersion.isEmpty)
        XCTAssertTrue(RDPMacInfo.freerdpVersion.contains("3.26.0"))
        XCTAssertTrue(RDPMacInfo.buildConfiguration.contains("rdpsnd"))
    }

    func testSessionExposesInitialStatisticsAndReconnectGuard() throws {
        let session = try RDPSession()

        XCTAssertEqual(session.statistics.framesReceived, 0)
        XCTAssertEqual(session.statistics.localFilesOffered, 0)
        XCTAssertThrowsError(try session.reconnect()) { error in
            XCTAssertEqual(
                error as? RDPSessionError,
                .configurationInvalid(reason: "No previous RDP connection options are available.")
            )
        }
    }
}
