import Foundation

enum TimeoutOutcome<T> {
    case finished(T?)
    case failed(Error)
    case timedOut
    case cancelled
}

// No structured child tasks: leaving a task-group scope waits even for an
// uncooperative SCK request. Only the winner resumes; late callbacks are inert.
private final class DeadlineRace<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TimeoutOutcome<T>, Never>?
    private var result: TimeoutOutcome<T>?
    private var timer: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<TimeoutOutcome<T>, Never>) {
        let ready: TimeoutOutcome<T>? = lock.withLock {
            if let result { return result }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }
    func installTimer(_ timer: Task<Void, Never>) {
        let finished = lock.withLock {
            if result != nil { return true }
            self.timer = timer
            return false
        }
        if finished { timer.cancel() }
    }
    func finish(_ result: TimeoutOutcome<T>) {
        let winner = lock.withLock { () -> (CheckedContinuation<TimeoutOutcome<T>, Never>?, Task<Void, Never>?)? in
            guard self.result == nil else { return nil }
            self.result = result
            let winner = (continuation, timer)
            continuation = nil
            timer = nil
            return winner
        }
        guard let winner else { return }
        winner.1?.cancel()
        winner.0?.resume(returning: result)
    }
}

func withTimeoutOutcome<T>(_ seconds: Double, _ work: @escaping @Sendable () async throws -> T?) async -> TimeoutOutcome<T> {
    let race = DeadlineRace<T>()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            race.install(continuation)
            let timer = Task.detached {
                do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) }
                catch { return }
                race.finish(.timedOut)
            }
            race.installTimer(timer)
            Task.detached {
                do { race.finish(.finished(try await work())) }
                catch { race.finish(.failed(error)) }
            }
        }
    } onCancel: {
        race.finish(.cancelled)
    }
}
