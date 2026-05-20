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
