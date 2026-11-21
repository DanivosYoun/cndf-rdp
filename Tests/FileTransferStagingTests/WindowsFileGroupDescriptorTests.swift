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

    // T1 (design D1): a folder needs FD_ATTRIBUTES in dwFlags and FILE_ATTRIBUTE_DIRECTORY.
    func testDirectoryNeedsBothTheAttributesFlagAndTheDirectoryAttribute() throws {
        func descriptor(flags: UInt32, attributes: UInt32, at attributesOffset: Int = 36) -> Data {
            var data = Data(count: 4 + 592)
            data.writeUInt32LE(1, at: 0)
            data.writeUInt32LE(flags, at: 4)
            data.writeUInt32LE(attributes, at: 4 + attributesOffset)
            for (index, unit) in Array("폴더W".utf16).enumerated() {
                data[4 + 72 + index * 2] = UInt8(unit & 0xFF)
                data[4 + 72 + index * 2 + 1] = UInt8(unit >> 8)
            }
            return data
        }

        XCTAssertTrue(try WindowsFileGroupDescriptor.decode(descriptor(flags: 0x4 | 0x40, attributes: 0x10))[0].isDirectory)
        XCTAssertFalse(try WindowsFileGroupDescriptor.decode(descriptor(flags: 0x40, attributes: 0x10))[0].isDirectory)
        XCTAssertFalse(try WindowsFileGroupDescriptor.decode(descriptor(flags: 0x4, attributes: 0x20))[0].isDirectory)
        // The attribute must be read at offset 36, not at the CLSID/size fields before it.
        XCTAssertFalse(try WindowsFileGroupDescriptor.decode(descriptor(flags: 0x4, attributes: 0x10, at: 32))[0].isDirectory)
        XCTAssertEqual(try WindowsFileGroupDescriptor.decode(descriptor(flags: 0x4, attributes: 0x10))[0].fileName, "폴더W")
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
