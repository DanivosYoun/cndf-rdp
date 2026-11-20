import CoreGraphics
import Foundation
import XCTest
@testable import RDPClientCore

final class RDPSessionLogTests: XCTestCase {
    /// Both engines start the session log with the engine line (design D4); this is FreeRDP's.
    func testFreeRDPSessionLogStartsWithTheEngineLine() throws {
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("freerdp-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: log) }
        let session = try RDPSession()
        try session.connect(RDPConnectionOptions(host: "127.0.0.1", port: 9, username: "log", logFileURL: log),
                            initialPointSize: CGSize(width: 640, height: 480), scale: 1)
        try? session.disconnect()

        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
        XCTAssertTrue(lines.first?.hasSuffix("RDP engine=freerdp version=\(RDPMacInfo.freerdpVersion)") == true)
    }
}
