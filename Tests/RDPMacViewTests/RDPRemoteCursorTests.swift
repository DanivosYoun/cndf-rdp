import XCTest
@testable import RDPMacView
import RDPClientCore

final class RDPCursorGeometryTests: XCTestCase {
    // Retina native resolution: 2 remote pixels per point.
    func testRetinaNativeHalvesPixelSizeAndHotSpot() {
        let geometry = RDPCursorGeometry(
            pixelWidth: 64, pixelHeight: 64, hotSpotX: 10, hotSpotY: 20, pointsPerRemotePixel: 0.5
        )

        XCTAssertEqual(geometry.size, CGSize(width: 32, height: 32))
        XCTAssertEqual(geometry.hotSpot, CGPoint(x: 5, y: 10))
    }

    func testOneToOneKeepsPixels() {
        let geometry = RDPCursorGeometry(
            pixelWidth: 32, pixelHeight: 48, hotSpotX: 0, hotSpotY: 47, pointsPerRemotePixel: 1
        )

        XCTAssertEqual(geometry.size, CGSize(width: 32, height: 48))
        XCTAssertEqual(geometry.hotSpot, CGPoint(x: 0, y: 47))
    }

    func testLargePointerScaledDownWithLetterboxScale() {
        let geometry = RDPCursorGeometry(
            pixelWidth: 384, pixelHeight: 384, hotSpotX: 192, hotSpotY: 0, pointsPerRemotePixel: 0.25
        )

        XCTAssertEqual(geometry.size, CGSize(width: 96, height: 96))
        XCTAssertEqual(geometry.hotSpot, CGPoint(x: 48, y: 0))
    }

    func testHotSpotIsClampedInsideImage() {
        let geometry = RDPCursorGeometry(
            pixelWidth: 32, pixelHeight: 32, hotSpotX: 40, hotSpotY: -3, pointsPerRemotePixel: 0.5
        )

        XCTAssertEqual(geometry.hotSpot, CGPoint(x: 15.5, y: 0))
    }
}

@MainActor
final class RDPClientViewRemoteCursorTests: XCTestCase {
    func testNoCursorUntilServerSendsOne() {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))

        XCTAssertNil(view.remoteCursor)
    }

    func testImagePointerBecomesCursorScaledToDisplayedFrame() throws {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        // Remote desktop at 2x the view size, so one remote pixel is half a point.
        view.display(RDPFrame(bgra: Data(count: 640 * 400 * 4), width: 640, height: 400, stride: 640 * 4))

        view.updateRemotePointer(.image(pointerImage(width: 32, height: 32, hotSpotX: 8, hotSpotY: 4)))

        let cursor = try XCTUnwrap(view.remoteCursor)
        XCTAssertEqual(cursor.image.size, NSSize(width: 16, height: 16))
        XCTAssertEqual(cursor.hotSpot, NSPoint(x: 4, y: 2))
    }

    func testHiddenPointerUsesTransparentCursor() throws {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))

        view.updateRemotePointer(.hidden)

        let cursor = try XCTUnwrap(view.remoteCursor)
        XCTAssertEqual(cursor.image.size, NSSize(width: 1, height: 1))
        XCTAssertFalse(cursor === NSCursor.arrow)
    }

    func testDefaultPointerUsesArrow() {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))

        view.updateRemotePointer(.hidden)
        view.updateRemotePointer(.systemDefault)

        XCTAssertTrue(view.remoteCursor === NSCursor.arrow)
    }

    func testPointerUpdatesAreIgnoredAfterShutdown() {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.updateRemotePointer(.hidden)

        view.shutdownRendering()
        view.updateRemotePointer(.image(pointerImage(width: 32, height: 32, hotSpotX: 0, hotSpotY: 0)))

        XCTAssertNil(view.remoteCursor)
    }

    private func pointerImage(width: Int, height: Int, hotSpotX: Int, hotSpotY: Int) -> RDPPointerImage {
        RDPPointerImage(
            bgra: Data(repeating: 0xFF, count: width * height * 4),
            width: width,
            height: height,
            stride: width * 4,
            hotSpotX: hotSpotX,
            hotSpotY: hotSpotY
        )
    }
}
