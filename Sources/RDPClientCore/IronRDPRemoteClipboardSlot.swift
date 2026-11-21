import Foundation

/// Newest remote clipboard delivery waiting for main, the same way `RDPConnectionView` holds
/// `pendingFrame`. A value stored while one waits replaces it, so main has at most one
/// delivery queued and only the newest server clipboard reaches it.
final class IronRDPRemoteClipboardSlot<Value> {
    private let lock = NSLock()
    private var pending: Value?

    /// Stores `value`. True when nothing was waiting: the caller queues one main block that
    /// calls `take()`. False when a queued block will pick this value up instead.
    func store(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let deliveryQueued = pending != nil
        pending = value
        return !deliveryQueued
    }

    func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let value = pending
        pending = nil
        return value
    }
}

/// Runs at most one remote file list materialization at a time and keeps only the newest
/// list that arrives while one runs.
final class IronRDPRemoteFileMaterializationQueue<Job> {
    private let lock = NSLock()
    private var running = false
    private var pending: Job?

    /// Stores `job`. True when no worker runs: the caller starts one that loops on `next()`.
    func submit(_ job: Job) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        pending = job
        guard !running else { return false }
        running = true
        return true
    }

    /// The next job for the running worker, or nil when there is none and the worker must stop.
    func next() -> Job? {
        lock.lock()
        defer { lock.unlock() }
        guard let job = pending else {
            running = false
            return nil
        }
        pending = nil
        return job
    }
}
