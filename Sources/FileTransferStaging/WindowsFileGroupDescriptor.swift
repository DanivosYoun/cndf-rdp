import Foundation

public enum WindowsFileGroupDescriptor {
    private static let descriptorSize = 592
    private static let fileNameOffset = 72
    private static let fileNameByteLength = 520
    private static let fileSizeHighOffset = 64
    private static let fileSizeLowOffset = 68
    private static let flagsOffset = 0
    private static let fileAttributesOffset = 36
    private static let fdAttributes: UInt32 = 0x0000_0004
    private static let fileAttributeDirectory: UInt32 = 0x0000_0010

    public static func decode(_ data: Data) throws -> [RDPFileListEntry] {
        guard data.count >= 4 else {
            throw RDPFileListPayloadError.invalidPayload
        }

        let count = Int(data.readUInt32LE(at: 0))
        let expectedSize = 4 + count * descriptorSize
        guard count >= 0, data.count >= expectedSize else {
            throw RDPFileListPayloadError.invalidPayload
        }

        return (0..<count).map { index in
            let offset = 4 + index * descriptorSize
            let high = UInt64(data.readUInt32LE(at: offset + fileSizeHighOffset))
            let low = UInt64(data.readUInt32LE(at: offset + fileSizeLowOffset))
            let nameData = data.subdata(in: (offset + fileNameOffset)..<(offset + fileNameOffset + fileNameByteLength))
            let decodedFileName = decodeUTF16LECString(nameData) ?? "remote-file-\(index)"
            let fileName = FileNameNormalization.normalizeForTransfer(decodedFileName)
            // dwFileAttributes counts only when dwFlags says it is valid (FD_ATTRIBUTES).
            let flags = data.readUInt32LE(at: offset + flagsOffset)
            let attributes = data.readUInt32LE(at: offset + fileAttributesOffset)
            return RDPFileListEntry(
                fileName: fileName,
                byteCount: (high << 32) | low,
                localURL: nil,
                isDirectory: flags & fdAttributes != 0 && attributes & fileAttributeDirectory != 0
            )
        }
    }

    private static func decodeUTF16LECString(_ data: Data) -> String? {
        var units: [UInt16] = []
        units.reserveCapacity(data.count / 2)

        var index = 0
        while index + 1 < data.count {
            let unit = UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
            if unit == 0 {
                break
            }
            units.append(unit)
            index += 2
        }

        return String(utf16CodeUnits: units, count: units.count)
    }
}

private extension Data {
    func readUInt32LE(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}
