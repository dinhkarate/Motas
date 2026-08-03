import Foundation

/// Runs a cancellation-aware operation loop at a fixed interval.
///
/// The loop sleeps first, then runs the operation, and repeats until stopped.
/// Missed ticks after a long pause are not replayed. A `start` call cancels any
/// previous loop before scheduling a fresh one.
@MainActor
public final class AutomaticRefreshScheduler {
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    /// - Parameter sleep: injected sleeper for deterministic tests. Defaults to
    ///   a cancellation-aware `Task.sleep`.
    public init(sleep: (@Sendable (Duration) async throws -> Void)? = nil) {
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
    }

    /// Starts or restarts the loop with the given operation.
    ///
    /// The first iteration waits for `interval` before running, and the loop
    /// exits immediately if cancelled during sleep. Unsupported short intervals
    /// are clamped to 60 seconds.
    public func start(interval: Duration, operation: @escaping @Sendable () async -> Void) {
        let clamped = Swift.max(interval, .seconds(60))
        let sleeper = sleep
        task?.cancel()
        task = Task {
            while !Task.isCancelled {
                do {
                    try await sleeper(clamped)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await operation()
            }
        }
    }

    /// Cancels the running loop and clears the task handle.
    public func stop() {
        task?.cancel()
        task = nil
    }
}