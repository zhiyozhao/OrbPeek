// Cache only within a synchronous poll, never across event-loop turns/awaits.
// Writes invalidate even if the OS rejects them, so subsequent reads are real.
package final class PollReadCache<Value> {
    private enum Storage { case empty, value(Value) }
    private var storage: Storage = .empty
    private var depth = 0
    package init() {}
    package func begin() {
        if depth == 0 { invalidate() }
        depth += 1
    }
    package func end() {
        precondition(depth > 0)
        depth -= 1
        if depth == 0 { invalidate() }
    }
    package func invalidate() { storage = .empty }
    package func read(_ load: () -> Value) -> Value {
        guard depth > 0 else { return load() }
        if case .value(let value) = storage { return value }
        let value = load()
        storage = .value(value)
        return value
    }
}
