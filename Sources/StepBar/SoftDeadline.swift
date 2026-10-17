import Foundation

// Do not use a structured task group here: leaving the group would wait for
// the slow child. The bounded search continues independently for cache reuse.
enum SoftDeadline {
    static let webNanoseconds: UInt64 = 1_200_000_000
    private actor Race<Value> {
        var continuation: CheckedContinuation<Value?, Never>?
        var finished = false
        var result: Value?
        func install(_ continuation: CheckedContinuation<Value?, Never>) {
            if finished { continuation.resume(returning: result) }
            else { self.continuation = continuation }
        }
        func resolve(_ value: Value?) {
            guard !finished else { return }
            finished = true; result = value
            continuation?.resume(returning: value); continuation = nil
        }
    }
    static func wait<Value>(for task: Task<Value, Never>, nanoseconds: UInt64 = webNanoseconds) async -> Value? {
        let race = Race<Value>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                Task { await race.install(continuation) }
                Task { await race.resolve(task.value) }
                Task {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                    await race.resolve(nil)
                }
            }
        } onCancel: {
            Task { await race.resolve(nil) }
        }
    }
}
