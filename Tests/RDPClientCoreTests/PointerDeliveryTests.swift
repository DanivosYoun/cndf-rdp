import XCTest
@testable import RDPClientCore

final class PointerDeliveryTests: XCTestCase {
    func testIdenticalShapesAreDeduplicatedWithoutDroppingStateTransitions() throws {
        let session = try RDPSession()
        let delegate = PointerDelegate()
        session.delegate = delegate
        let image = RDPRemotePointer.image(RDPPointerImage(
            bgra: Data(repeating: 255, count: 16), width: 2, height: 2, stride: 8,
            hotSpotX: 0, hotSpotY: 0))
        for pointer in [image, image, .hidden, .hidden, image, .systemDefault, .systemDefault, image] {
            session.deliverRemotePointer(pointer)
        }
        XCTAssertEqual(delegate.pointers, [image, .hidden, image, .systemDefault, image])
    }
}

private final class PointerDelegate: RDPSessionDelegate {
    func rdpSession(_ session: RDPEngineSession, didLog message: String) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteText text: String) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveRemoteFiles files: [RDPRemoteFile]) {}
    func rdpSession(_ session: RDPEngineSession, didReceiveFrame frame: RDPFrame) {}
    var pointers: [RDPRemotePointer] = []
    func rdpSession(_ session: RDPEngineSession, didUpdatePointer pointer: RDPRemotePointer) {
        pointers.append(pointer)
    }
}
