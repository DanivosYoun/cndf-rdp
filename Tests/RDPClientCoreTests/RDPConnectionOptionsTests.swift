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
    }

    func testStoresRedirectedFolderAndAudioOptions() {
        let logURL = URL(fileURLWithPath: "/tmp/rdp.log")
        let options = RDPConnectionOptions(
            host: "rdp.example",
            redirectedFolderPath: "/Users/me/RDPShare",
            redirectedFolderName: "RemoteShare",
            audioPlaybackMode: .playLocally,
            logFileURL: logURL
        )

        XCTAssertEqual(options.redirectedFolderPath, "/Users/me/RDPShare")
        XCTAssertEqual(options.redirectedFolderName, "RemoteShare")
        XCTAssertEqual(options.audioPlaybackMode, .playLocally)
        XCTAssertEqual(options.logFileURL, logURL)
    }

    func testExposesBuildInfo() {
        XCTAssertFalse(RDPMacInfo.packageVersion.isEmpty)
        XCTAssertTrue(RDPMacInfo.freerdpVersion.contains("3.26.0"))
        XCTAssertTrue(RDPMacInfo.buildConfiguration.contains("rdpsnd"))
    }
}
