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
    }

    func testStoresRedirectedFolderAndAudioOptions() {
        let options = RDPConnectionOptions(
            host: "rdp.example",
            redirectedFolderPath: "/Users/me/RDPShare",
            redirectedFolderName: "RemoteShare",
            audioPlaybackMode: .playLocally
        )

        XCTAssertEqual(options.redirectedFolderPath, "/Users/me/RDPShare")
        XCTAssertEqual(options.redirectedFolderName, "RemoteShare")
        XCTAssertEqual(options.audioPlaybackMode, .playLocally)
    }
}
