import Foundation

/// A session's log file (design D-T3). It holds no session reference, so a materialization job
/// can keep a copy and still write its line after the session, its delegate, or its connection
/// is gone (INV-LOG1, INV-T4). The session passes its own lock, so every copy made for the
/// session, across reconnects, serializes its writes with the session's.
struct RDPSessionLogFile {
    let url: URL
    let lock: NSLock

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
}
