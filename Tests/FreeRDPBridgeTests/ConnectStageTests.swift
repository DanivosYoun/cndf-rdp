import FreeRDPBridge
import XCTest

/// FreeRDP's CONNECTION_STATE numbering (freerdp/types.h, 3.32.1). The failure
/// callback reports the coarse stage so a negotiation failure can be told apart
/// from one after the security exchange.
final class ConnectStageTests: XCTestCase {
    func testNegotiationStatesMapToNegotiation() {
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(0), RDPBridgeConnectStageInitial)   // INITIAL
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(1), RDPBridgeConnectStageNegotiation) // NEGO
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(2), RDPBridgeConnectStageAuthentication) // NLA
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(3), RDPBridgeConnectStageAuthentication) // AAD
    }

    func testLaterStatesMapToTheirPhase() {
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(4), RDPBridgeConnectStageChannelSetup)   // MCS_CREATE_REQUEST
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(14), RDPBridgeConnectStageChannelSetup)  // AUTO_DETECT_RESPONSE
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(15), RDPBridgeConnectStageLicensing)     // LICENSING
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(18), RDPBridgeConnectStageCapabilities)  // DEMAND_ACTIVE
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(21), RDPBridgeConnectStageFinalization)  // FINALIZATION_SYNC
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(30), RDPBridgeConnectStageActive)        // ACTIVE
    }

    func testUnknownStateIsUnknown() {
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(31), RDPBridgeConnectStageUnknown)
        XCTAssertEqual(rdp_bridge_connect_stage_for_state(UInt32.max), RDPBridgeConnectStageUnknown)
    }
}
