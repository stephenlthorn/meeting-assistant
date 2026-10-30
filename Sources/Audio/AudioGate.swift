import Foundation

/// Decides whether audio handed to a transcriber may still be used.
///
/// A transcriber does its work on its own queue, so when consent is withdrawn
/// the queue may still hold buffers that were handed over a moment earlier. The
/// gate closes on the caller's thread, before `cancel()` returns, and every
/// piece of queued work (a buffer, a start, a retry) checks it again when its
/// turn comes. Each close starts a new epoch, so work from before it can tell
/// it is stale even after the gate was opened again.
///
/// A user's Stop does not touch the gate: what was already handed over is
/// still processed, so the last words of a call are not lost.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var epoch = 0
    private var isOpen = true

    /// The epoch to stamp new work with, or nil once closed.
    func admit() -> Int? {
        lock.withLock { isOpen ? epoch : nil }
    }

    func allows(_ epoch: Int) -> Bool {
        lock.withLock { isOpen && self.epoch == epoch }
    }

    func close() {
        lock.withLock {
            isOpen = false
            epoch += 1
        }
    }

    /// Opens a closed gate in a new epoch; an open gate keeps its epoch, so
    /// stopping and starting again does not discard audio queued in between.
    @discardableResult
    func open() -> Int {
        lock.withLock {
            if !isOpen {
                isOpen = true
                epoch += 1
            }
            return epoch
        }
    }
}
