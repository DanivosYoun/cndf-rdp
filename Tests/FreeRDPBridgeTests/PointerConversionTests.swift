import FreeRDPBridge
import XCTest

final class PointerConversionTests: XCTestCase {
    private func convert(
        width: UInt32,
        height: UInt32,
        xorBpp: UInt32,
        xor: [UInt8],
        and: [UInt8]
    ) -> [UInt8]? {
        var bgra = [UInt8](repeating: 0xEE, count: Int(width * height * 4))
        let ok = xor.withUnsafeBufferPointer { xorBuffer in
            and.withUnsafeBufferPointer { andBuffer in
                rdp_bridge_pointer_to_bgra(
                    width, height, xorBpp,
                    xorBuffer.baseAddress, UInt32(xor.count),
                    and.isEmpty ? nil : andBuffer.baseAddress, UInt32(and.count),
                    &bgra
                )
            }
        }
        return ok ? bgra : nil
    }

    // 1bpp masks are top-down with rows padded to 2 bytes: AND=0/XOR=0 is black,
    // AND=0/XOR=1 white, AND=1/XOR=0 transparent.
    func testMonochromePointerMapsAndXorToBlackWhiteTransparent() throws {
        let bgra = try XCTUnwrap(convert(
            width: 3, height: 2, xorBpp: 1,
            xor: [0b0100_0000, 0, 0b0000_0000, 0],
            and: [0b0010_0000, 0, 0b1110_0000, 0]
        ))

        XCTAssertEqual(Array(bgra[0..<12]), [
            0x00, 0x00, 0x00, 0xFF,
            0xFF, 0xFF, 0xFF, 0xFF,
            0x00, 0x00, 0x00, 0x00
        ])
        XCTAssertEqual(Array(bgra[12..<24]), [UInt8](repeating: 0, count: 12))
    }

    // 32bpp XOR data is bottom-up BGRA; the output is top-down with alpha kept straight.
    func testColorPointerIsFlippedTopDownAndKeepsAlpha() throws {
        let bottomRow: [UInt8] = [0x01, 0x02, 0x03, 0xFF]
        let topRow: [UInt8] = [0x40, 0x50, 0x60, 0x80]
        let bgra = try XCTUnwrap(convert(
            width: 1, height: 2, xorBpp: 32,
            xor: bottomRow + topRow,
            and: [0, 0, 0, 0]
        ))

        XCTAssertEqual(Array(bgra[0..<4]), topRow)
        XCTAssertEqual(Array(bgra[4..<8]), bottomRow)
    }

    func testRejectsTruncatedMasks() {
        XCTAssertNil(convert(width: 3, height: 2, xorBpp: 1, xor: [0], and: [0]))
        XCTAssertNil(convert(width: 2, height: 2, xorBpp: 32, xor: [0, 0, 0, 0], and: []))
    }
}
