import Foundation

/// Gives up on an on-device AI request, or another system service, that takes
/// too long. A request to the model, and reading text in a photo, have each
/// been seen never to answer, and sorting judges one file at a time, so
/// without a limit one stuck file would hold up every file after it. The
/// abandoned request is cancelled and left to end on its own.
enum AIDeadline {
    /// The request took longer than its limit.
    struct Exceeded: Error {}

    static func run<T: Sendable>(within limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = Race()
        return try await withCheckedThrowingContinuation { continuation in
            let work = Task {
                do {
                    let value = try await operation()
                    if race.finish() { continuation.resume(returning: value) }
                } catch {
                    if race.finish() { continuation.resume(throwing: error) }
                }
            }
            race.timer = Task {
                try? await Task.sleep(for: limit)
                guard !Task.isCancelled, race.finish() else { return }
                work.cancel()
                continuation.resume(throwing: Exceeded())
            }
        }
    }

    /// Lets only the first of the request and the timer through, and stops
    /// the timer when the request wins.
    private final class Race: @unchecked Sendable {
        private let lock = NSLock()
        private var isFinished = false
        private var _timer: Task<Void, Never>?

        var timer: Task<Void, Never>? {
            get { lock.withLock { _timer } }
            set {
                let cancelNow = lock.withLock { () -> Bool in
                    _timer = newValue
                    return isFinished
                }
                if cancelNow { newValue?.cancel() }
            }
        }

        /// True for the first caller only.
        func finish() -> Bool {
            let (first, timer) = lock.withLock { () -> (Bool, Task<Void, Never>?) in
                defer { isFinished = true }
                return (!isFinished, _timer)
            }
            if first { timer?.cancel() }
            return first
        }
    }
}
