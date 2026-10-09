import Foundation

/// Writes that must never block the caller (main actor): done at once when the writer is free, else on one
/// serial background queue in order – while a refresh commit, an EPG swap or a dictionary fill holds the writer.
/// Once something is queued, later writes queue behind it (order kept). `drain` waits for the queue (app going to
/// the background).
public final class DeferredWrites: @unchecked Sendable {
    private let queue = DispatchQueue(label: "db.deferred-writes", qos: .userInitiated)
    private let lock = NSLock()
    private var pending = 0

    public var isIdle: Bool { lock.lock(); defer { lock.unlock() }; return pending == 0 }

    /// Runs `write` now when nothing is queued and the writer is free (returns true), else queues it (false) and
    /// calls `completion` on the queue after it ran.
    @MainActor
    @discardableResult
    func perform(_ db: SQLiteDatabase, _ write: @escaping @Sendable () -> Void,
                 queued: (() -> Void)? = nil, completion: (@Sendable () -> Void)? = nil) -> Bool {
        if isIdle, db.ifWriterFree(write) != nil { return true }
        queued?()
        enqueue {
            write()
            completion?()
        }
        return false
    }

    func enqueue(_ block: @escaping @Sendable () -> Void) {
        lock.lock(); pending += 1; lock.unlock()
        queue.async { [self] in
            block()
            lock.lock(); pending -= 1; lock.unlock()
        }
    }

    /// Waits until everything queued so far is written (at most `timeout`). Call off the main thread.
    @discardableResult
    public func drain(timeout: TimeInterval) -> Bool {
        guard !isIdle else { return true }
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }
}
