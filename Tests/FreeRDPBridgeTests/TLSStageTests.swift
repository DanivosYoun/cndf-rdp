import FreeRDPBridge
import XCTest

final class TLSStageTests: XCTestCase {
    private func settings(for stage: RDPBridgeTLSStage) throws -> (min: UInt16, max: UInt16, secLevel: UInt32, ciphers: String) {
        var out = RDPBridgeTLSSettings()
        XCTAssertTrue(rdp_bridge_tls_settings_for_stage(stage, &out))
        let ciphers = withUnsafeBytes(of: out.allowedCiphers) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        return (out.minVersion, out.maxVersion, out.secLevel, ciphers)
    }

    func testDefaultStageKeepsFreeRDPDefaults() throws {
        let s = try settings(for: RDPBridgeTLSStageDefault)
        XCTAssertEqual(s.min, 0x0303)
        XCTAssertEqual(s.max, 0)
        XCTAssertEqual(s.secLevel, 2)
        XCTAssertEqual(s.ciphers, "")
    }

    // The first fallback must be FreeRDP 3.26's defaults, so a host that
    // connected on the first attempt before 3.27 is not dropped to SECLEVEL 0.
    func testPreviousStageMatchesFreeRDP326Defaults() throws {
        let s = try settings(for: RDPBridgeTLSStagePrevious)
        XCTAssertEqual(s.min, 0x0301)
        XCTAssertEqual(s.max, 0)
        XCTAssertEqual(s.secLevel, 1)
        XCTAssertEqual(s.ciphers, "")
    }

    func testLegacyStageKeepsExistingLastResortProfile() throws {
        let s = try settings(for: RDPBridgeTLSStageLegacy)
        XCTAssertEqual(s.min, 0x0301)
        XCTAssertEqual(s.max, 0x0303)
        XCTAssertEqual(s.secLevel, 0)
        XCTAssertEqual(s.ciphers, "DEFAULT@SECLEVEL=0")
    }

    func testStagesAreOrderedStrongestFirst() {
        XCTAssertLessThan(RDPBridgeTLSStageDefault.rawValue, RDPBridgeTLSStagePrevious.rawValue)
        XCTAssertLessThan(RDPBridgeTLSStagePrevious.rawValue, RDPBridgeTLSStageLegacy.rawValue)
    }
}
