import FileTransferStaging
import Foundation

public enum ClipboardPayload: Equatable, Sendable {
    case text(String)
    case fileURLs([URL])
}

public enum ClipboardBridgeError: Error, Equatable {
    case noSupportedPasteboardContent
    case bridgeUnavailable
    case bridgeRejectedOperation(Int32)
}

public struct ClipboardFileOffer: Equatable, Sendable {
    public let providedCount: Int
    public let providedBytes: UInt64
    public let omittedCount: Int

    public init(providedCount: Int, providedBytes: UInt64, omittedCount: Int) {
        self.providedCount = providedCount
        self.providedBytes = providedBytes
        self.omittedCount = omittedCount
    }

    public init(staged selection: LocalFileStagingResult) {
        self.init(
            providedCount: selection.files.count,
            providedBytes: selection.files.reduce(0) { $0 + $1.byteCount },
            omittedCount: selection.omittedCount
        )
    }

    public static let none = ClipboardFileOffer(providedCount: 0, providedBytes: 0, omittedCount: 0)
    public var didProvide: Bool { providedCount > 0 }
}
