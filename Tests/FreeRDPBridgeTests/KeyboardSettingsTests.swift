import FreeRDPBridge
import XCTest

final class KeyboardSettingsTests: XCTestCase {
    func testStandardFieldsMatchFreeRDPDefaults() {
        assertSettings(layout: 0, type: 4, subType: 0, functionKey: 12)
    }

    func testKoreanFieldsAreWrittenAsGiven() {
        assertSettings(layout: 0x412, type: 8, subType: 3, functionKey: 12)
    }

    private func assertSettings(layout: UInt32, type: UInt32, subType: UInt32, functionKey: UInt32,
                                file: StaticString = #filePath, line: UInt = #line) {
        var options = RDPBridgeConnectionOptions()
        options.keyboardLayout = layout
        options.keyboardType = type
        options.keyboardSubType = subType
        options.keyboardFunctionKey = functionKey
        var settings = RDPBridgeKeyboardSettings()
        XCTAssertTrue(rdp_bridge_keyboard_settings_for_options(&options, &settings), file: file, line: line)
        XCTAssertEqual(settings.keyboardLayout, layout, file: file, line: line)
        XCTAssertEqual(settings.keyboardType, type, file: file, line: line)
        XCTAssertEqual(settings.keyboardSubType, subType, file: file, line: line)
        XCTAssertEqual(settings.keyboardFunctionKey, functionKey, file: file, line: line)
    }
}
