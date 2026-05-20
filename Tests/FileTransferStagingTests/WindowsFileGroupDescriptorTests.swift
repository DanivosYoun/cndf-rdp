import FileTransferStaging
import XCTest

final class WindowsFileGroupDescriptorTests: XCTestCase {
    func testDecodesMinimalFileGroupDescriptor() throws {
        var data = Data(count: 4 + 592)
        data.writeUInt32LE(1, at: 0)
        data.writeUInt32LE(123, at: 4 + 68)

        let name = Array("report.txt".utf16)
        for (index, unit) in name.enumerated() {
            data[4 + 72 + index * 2] = UInt8(unit & 0xFF)
            data[4 + 72 + index * 2 + 1] = UInt8(unit >> 8)
        }

        let files = try WindowsFileGroupDescriptor.decode(data)

        XCTAssertEqual(files, [
            RDPFileListEntry(fileName: "report.txt", byteCount: 123, localURL: nil)
        ])
    }

    func testNormalizesDecodedKoreanFileNameToNFC() throws {
        var data = Data(count: 4 + 592)
        data.writeUInt32LE(1, at: 0)
        data.writeUInt32LE(123, at: 4 + 68)

        let decomposedName = "한글.txt".decomposedStringWithCanonicalMapping
        let name = Array(decomposedName.utf16)
        for (index, unit) in name.enumerated() {
            data[4 + 72 + index * 2] = UInt8(unit & 0xFF)
            data[4 + 72 + index * 2 + 1] = UInt8(unit >> 8)
        }

        let files = try WindowsFileGroupDescriptor.decode(data)

        XCTAssertEqual(files[0].fileName, "한글.txt")
        XCTAssertEqual(files[0].fileName.unicodeScalars.map(\.value), "한글.txt".unicodeScalars.map(\.value))
    }
}

private extension Data {
    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value & 0xFF)
        self[offset + 1] = UInt8((value >> 8) & 0xFF)
        self[offset + 2] = UInt8((value >> 16) & 0xFF)
        self[offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}
