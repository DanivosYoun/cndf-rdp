import CoreGraphics
import RDPClientCore
import XCTest

final class DisplayResizeCoordinatorTests: XCTestCase {
    func testConvertsPointSizeToPixelSizeWithScale() {
        let coordinator = DisplayResizeCoordinator()

        let size = coordinator.candidateSize(pointWidth: 900, pointHeight: 560, scale: 2)

        XCTAssertEqual(size, RDPDesktopSize(pixelWidth: 1800, pixelHeight: 1120, scale: 2))
    }

    func testCanDisableDeviceNativeScale() {
        let coordinator = DisplayResizeCoordinator()

        let size = coordinator.candidateSize(
            pointWidth: 900,
            pointHeight: 560,
            scale: 2,
            preferDeviceNativeResolution: false
        )

        XCTAssertEqual(size, RDPDesktopSize(pixelWidth: 900, pixelHeight: 560, scale: 1))
    }

    func testForcedDesktopSizeIgnoresViewSizeAndScale() {
        let coordinator = DisplayResizeCoordinator()

        let size = coordinator.candidateSize(
            pointWidth: 900,
            pointHeight: 560,
            scale: 2,
            forcedDesktopSize: CGSize(width: 1920, height: 1080)
        )

        XCTAssertEqual(size, RDPDesktopSize(pixelWidth: 1920, pixelHeight: 1080, scale: 1))
    }

    func testThrottlesRapidResizeUpdates() {
        let coordinator = DisplayResizeCoordinator(minimumInterval: 0.12)

        let first = coordinator.sizeToSend(pointWidth: 900, pointHeight: 560, scale: 2, now: 1.0)
        let second = coordinator.sizeToSend(pointWidth: 901, pointHeight: 560, scale: 2, now: 1.05)
        let third = coordinator.sizeToSend(pointWidth: 901, pointHeight: 560, scale: 2, now: 1.13)

        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertNotNil(third)
    }

    func testForceResendsSameSize() {
        let coordinator = DisplayResizeCoordinator(minimumInterval: 0.12)

        let first = coordinator.sizeToSend(pointWidth: 900, pointHeight: 560, scale: 2, now: 1.0)
        let second = coordinator.sizeToSend(pointWidth: 900, pointHeight: 560, scale: 2, now: 2.0)
        let forced = coordinator.sizeToSend(pointWidth: 900, pointHeight: 560, scale: 2, now: 2.0, force: true)

        XCTAssertNotNil(first)
        XCTAssertNil(second)
        XCTAssertNotNil(forced)
    }
}
