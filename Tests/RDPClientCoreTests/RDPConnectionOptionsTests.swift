import CoreGraphics
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
        XCTAssertTrue(options.preferDeviceNativeResolution)
        XCTAssertEqual(options.colorDepth, .depth32)
        XCTAssertNil(options.forcedDesktopSize)
    }

    func testStoresConnectionOptions() {
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
            logFilters: ["com.freerdp.channels.cliprdr": .trace],
            preferDeviceNativeResolution: false,
            colorDepth: .depth24,
            forcedDesktopSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(options.securePassword, securePassword)
        XCTAssertEqual(options.redirectedFolderPath, "/Users/me/RDPShare")
        XCTAssertEqual(options.redirectedFolderName, "RemoteShare")
        XCTAssertEqual(options.audioPlaybackMode, .playLocally)
        XCTAssertEqual(options.logFileURL, logURL)
        XCTAssertEqual(options.logLevel, .debug)
        XCTAssertEqual(options.logFilters["com.freerdp.channels.cliprdr"], .trace)
        XCTAssertFalse(options.preferDeviceNativeResolution)
        XCTAssertEqual(options.colorDepth, .depth24)
        XCTAssertEqual(options.forcedDesktopSize, CGSize(width: 1920, height: 1080))
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
        // Reported by the loaded library, so it tracks Scripts/build-freerdp.sh (3.32.1 / bf217a5).
        XCTAssertTrue(RDPMacInfo.freerdpVersion.hasPrefix("3.32.1 ("), RDPMacInfo.freerdpVersion)
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
