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
        XCTAssertTrue(options.preferDeviceNativeResolution)
        XCTAssertEqual(options.colorDepth, .depth32)
        XCTAssertNil(options.forcedDesktopSize)
        XCTAssertEqual(options.graphicsMode, .automatic)
        XCTAssertEqual(options.keyboardProfile, .standard)
    }

    /// Design D2: `.standard` keeps the pre-profile fields, `.korean` is Korean 101-key Type 1.
    func testKeyboardProfileGCCFields() {
        let standard = RDPKeyboardProfile.standard
        XCTAssertEqual([standard.keyboardLayout, standard.keyboardType, standard.keyboardSubType, standard.keyboardFunctionKey],
                       [0, 4, 0, 12])
        let korean = RDPKeyboardProfile.korean
        XCTAssertEqual([korean.keyboardLayout, korean.keyboardType, korean.keyboardSubType, korean.keyboardFunctionKey],
                       [0x412, 8, 3, 12])
        XCTAssertEqual(RDPConnectionOptions(host: "rdp.example", keyboardProfile: .korean).keyboardProfile, .korean)
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
            preferDeviceNativeResolution: false,
            colorDepth: .depth24,
            forcedDesktopSize: CGSize(width: 1920, height: 1080),
            graphicsMode: .compatibility
        )

        XCTAssertEqual(options.securePassword, securePassword)
        XCTAssertEqual(options.redirectedFolderPath, "/Users/me/RDPShare")
        XCTAssertEqual(options.redirectedFolderName, "RemoteShare")
        XCTAssertEqual(options.audioPlaybackMode, .playLocally)
        XCTAssertEqual(options.logFileURL, logURL)
        XCTAssertEqual(options.logLevel, .debug)
        XCTAssertFalse(options.preferDeviceNativeResolution)
        XCTAssertEqual(options.colorDepth, .depth24)
        XCTAssertEqual(options.forcedDesktopSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(options.graphicsMode, .compatibility)
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
        XCTAssertFalse(RDPMacInfo.ironRDPVersion.isEmpty)
        XCTAssertTrue(RDPMacInfo.buildConfiguration.contains("rdpsnd"))
    }

    func testSessionExposesInitialStatisticsAndReconnectGuard() throws {
        let session = try IronRDPSession()

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
