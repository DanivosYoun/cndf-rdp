import Foundation

public struct StagedFile: Equatable, Sendable {
    public let sourceURL: URL
    public let stagedURL: URL
    public let fileName: String
    public let byteCount: UInt64
    /// A folder entry (design D-1, INV-D1): it carries no contents and its size is 0.
    public let isDirectory: Bool

    public init(sourceURL: URL, stagedURL: URL, fileName: String, byteCount: UInt64, isDirectory: Bool = false) {
        self.sourceURL = sourceURL
        self.stagedURL = stagedURL
        self.fileName = fileName
        self.byteCount = byteCount
        self.isDirectory = isDirectory
    }

    /// The name handed to the native bridges (INV-D2): a trailing `\` marks a folder; file names never end in `\`.
    public var wireName: String {
        isDirectory ? fileName + "\\" : fileName
    }
}
