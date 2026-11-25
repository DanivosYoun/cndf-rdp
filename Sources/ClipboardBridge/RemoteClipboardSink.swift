import Foundation

public protocol RemoteClipboardSink: AnyObject {
    func sendLocalText(_ text: String) throws
    @discardableResult
    func sendLocalFiles(_ urls: [URL]) throws -> ClipboardFileOffer
}
