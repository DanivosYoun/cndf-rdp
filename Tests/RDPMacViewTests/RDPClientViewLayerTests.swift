import CoreVideo
import QuartzCore
import RDPClientCore
import RDPMacView
import XCTest

final class RDPClientViewLayerTests: XCTestCase {
    func testFrameLayerDisablesImplicitAnimations() {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let actions = view.layer?.actions

        XCTAssertTrue(actions?["contents"] is NSNull)
        XCTAssertTrue(actions?["contentsScale"] is NSNull)
        XCTAssertTrue(actions?["bounds"] is NSNull)
        XCTAssertTrue(actions?["position"] is NSNull)
    }

    func testFrameTapReceivesBGRAPixelBufferOnMainThread() throws {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        let frame = testFrame()
        var receivedPixelBuffer: CVPixelBuffer?
        var receivedHostTime: CFTimeInterval = 0
        var callbackIsMainThread = false
        var callbackCount = 0

        view.onRenderedFrame = { pixelBuffer, hostTime in
            callbackCount += 1
            callbackIsMainThread = Thread.isMainThread
            receivedPixelBuffer = pixelBuffer
            receivedHostTime = hostTime
        }

        view.display(frame)

        XCTAssertEqual(callbackCount, 1)
        XCTAssertTrue(callbackIsMainThread)
        XCTAssertGreaterThan(receivedHostTime, 0)
        let pixelBuffer = try XCTUnwrap(receivedPixelBuffer)
        XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixelBuffer), kCVPixelFormatType_32BGRA)
        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), frame.width)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), frame.height)

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        let baseAddress = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [0x10, 0x20, 0x30, 0x40])
    }

    func testFrameTapIsClearedOnShutdown() {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        view.onRenderedFrame = { _, _ in }

        view.shutdownRendering()

        XCTAssertNil(view.onRenderedFrame)
    }

    func testConnectionViewForwardsFrameTapToClientView() {
        let connectionView = RDPConnectionView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))
        var callbackCount = 0
        connectionView.onRenderedFrame = { _, _ in
            callbackCount += 1
        }

        connectionView.clientView.display(testFrame())

        XCTAssertEqual(callbackCount, 1)
    }

    func testInputInjectionNoOpsWithoutConnectedSession() {
        let view = RDPClientView(frame: CGRect(x: 0, y: 0, width: 320, height: 200))

        view.injectMouse(x: 10, y: 20, button: .left, flags: [.move, .down, .up])
        view.injectKey(virtualKeyCode: 0x41, scanCode: 0x1E, flags: [.down, .up])
        view.injectKey(virtualKeyCode: 0x2E, scanCode: 0x53, flags: [.down, .up, .extended])
        view.injectScroll(x: 10, y: 20, deltaY: 120, deltaX: -120)
    }
}

private func testFrame() -> RDPFrame {
    RDPFrame(
        bgra: Data([
            0x10, 0x20, 0x30, 0x40,
            0x50, 0x60, 0x70, 0x80,
            0x90, 0xA0, 0xB0, 0xC0,
            0xD0, 0xE0, 0xF0, 0xFF
        ]),
        width: 2,
        height: 2,
        stride: 8
    )
}
