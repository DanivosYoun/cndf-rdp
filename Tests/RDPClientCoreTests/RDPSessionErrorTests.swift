import FreeRDPBridge
@testable import RDPClientCore
import XCTest

/// Network and TLS failures used to drop the bridge's FreeRDP code, so a
/// transport failure (0x0002000D) could not be told from a DNS failure.
final class RDPSessionErrorTests: XCTestCase {
    func testNetworkFailureKeepsCodeAndStage() {
        let error = RDPSessionError(kind: RDPBridgeFailureNetwork, code: 0x0002000D, stage: .negotiation,
                                    description: "transport layer failed")
        XCTAssertEqual(error, .networkUnreachable(underlying: "transport layer failed", code: 0x0002000D, stage: .negotiation))
    }

    func testTLSFailureKeepsCodeAndStage() {
        let error = RDPSessionError(kind: RDPBridgeFailureTLS, code: 0x00020008, stage: .negotiation, description: "tls")
        XCTAssertEqual(error, .tlsHandshakeFailed(reason: "tls", code: 0x00020008, stage: .negotiation))
    }

    func testBridgeStageMapsToPublicStage() {
        XCTAssertEqual(RDPConnectStage(RDPBridgeConnectStageNegotiation), .negotiation)
        XCTAssertEqual(RDPConnectStage(RDPBridgeConnectStageActive), .active)
        XCTAssertEqual(RDPConnectStage(RDPBridgeConnectStageUnknown), .unknown)
    }
}
