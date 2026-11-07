//  PersistenceWriter.swift
//  AsterismaV2.5
//
//  FINAL TRACES / UPGRADE #4 (safe slice): a dedicated OWNED serial queue
//  that executes ALL library disk writes. Replaces the ad-hoc detached-task
//  chain in DataStore.enqueueWrite — identical FIFO ordering contract, but
//  the executor is owned and named, so future SQLite-style stores can adopt
//  it directly (fixes the cross-thread handle issue from P6-G: everything
//  touching a DB handle will run on THIS queue).
//
//  Why DispatchQueue over an actor here: encode/write closures are
//  synchronous by nature; a serial queue gives owned serialization without
//  async-entry friction at every call site, and plays perfectly with the
//  semaphore drain in saveImmediately().

import Foundation

final class PersistenceWriter: @unchecked Sendable {
    static let shared = PersistenceWriter()

    private let queue: DispatchQueue

    init(label: String = "readingtracker.persistence.writer") {
        queue = DispatchQueue(label: label, qos: .utility) // serial by default
    }

    /// Enqueues an encode+write job. FIFO ordering guaranteed from the moment
    /// this call returns, not just once a detached task happens to start.
    /// Returns a handle whose `value` resolves after this job completes
    /// ("nil" = success), preserving DataStore's observer pattern.
    func enqueue(encode: @escaping @Sendable () throws -> Data,
                 write: @escaping @Sendable (Data) throws -> Void)
        -> Task<String?, Never> {
        let result = WriteResult()
        // Submit synchronously, in call order. The queue is the executor.
        queue.async {
            do {
                let data = try encode()
                try write(data)
                result.resolve(nil)
            } catch {
                result.resolve("\(error)")
            }
        }
        return Task { await result.wait() }
    }

    /// Synchronous barrier for saveImmediately paths (drains ALL pending).
    func drainSync() {
        queue.sync(flags: .barrier) {}
    }
}

/// One job's completion slot. `enqueue` submits the job to the serial queue
/// synchronously, then returns a Task that waits on this slot.
private final class WriteResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<String?, Never>?
    /// Double optional: outer nil = not finished; .some(nil) = success.
    private var finished: String??

    func resolve(_ value: String?) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: value)
        } else {
            finished = .some(value)
            lock.unlock()
        }
    }

    func wait() async -> String? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let finished {
                lock.unlock()
                continuation.resume(returning: finished)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
