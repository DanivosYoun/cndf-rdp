import Foundation

public struct StagedFile: Equatable, Sendable {
    public let sourceURL: URL
    public let stagedURL: URL
    public let fileName: String
    public let byteCount: UInt64

    public init(sourceURL: URL, stagedURL: URL, fileName: String, byteCount: UInt64) {
        self.sourceURL = sourceURL
        self.stagedURL = stagedURL
        self.fileName = fileName
        self.byteCount = byteCount
    }
}
