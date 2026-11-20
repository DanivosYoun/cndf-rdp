import FreeRDPBridge
import XCTest

final class GraphicsModeTests: XCTestCase {
    func testAutomaticKeepsGraphicsPipelineAndCodecsEnabled() {
        assertSettings(compatibility: false, gfx: true)
    }

    func testCompatibilityDisablesGraphicsPipelineAndCodecs() {
        assertSettings(compatibility: true, gfx: false)
    }

    private func assertSettings(compatibility: Bool, gfx: Bool, file: StaticString = #filePath, line: UInt = #line) {
        var settings = RDPBridgeGraphicsSettings()
        XCTAssertTrue(rdp_bridge_graphics_settings_for_mode(compatibility, &settings), file: file, line: line)
        XCTAssertEqual(settings.graphicsPipeline, gfx, file: file, line: line)
        XCTAssertEqual(settings.h264, gfx, file: file, line: line)
        XCTAssertEqual(settings.avc444, gfx, file: file, line: line)
        XCTAssertEqual(settings.avc444v2, gfx, file: file, line: line)
        XCTAssertEqual(settings.progressive, gfx, file: file, line: line)
        XCTAssertFalse(settings.bitmapCache, file: file, line: line)
        XCTAssertTrue(settings.compression, file: file, line: line)
    }
}
