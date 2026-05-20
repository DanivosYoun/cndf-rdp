import Foundation

public final class RDPSecureString: @unchecked Sendable, Equatable {
    private let lock = NSLock()
    private var bytes: [UInt8]

    public init(_ string: String) {
        self.bytes = Array(string.utf8)
    }

    deinit {
        zeroize()
    }

    public static func == (lhs: RDPSecureString, rhs: RDPSecureString) -> Bool {
        lhs.snapshot() == rhs.snapshot()
    }

    public func zeroize() {
        lock.lock()
        defer { lock.unlock() }
        bytes.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            memset(baseAddress, 0, buffer.count)
        }
        bytes.removeAll(keepingCapacity: false)
    }

    public func withCString<T>(_ body: (UnsafePointer<CChar>?) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        guard !bytes.isEmpty else {
            return body(nil)
        }

        var copy = bytes + [0]
        return copy.withUnsafeMutableBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return body(nil)
            }
            defer {
                memset(baseAddress, 0, buffer.count)
            }
            return body(UnsafeRawPointer(baseAddress).assumingMemoryBound(to: CChar.self))
        }
    }

    private func snapshot() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}
