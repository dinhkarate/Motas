import Foundation

public struct AutomaticRefreshPolicy: Sendable, Equatable {
    public let interval: Duration
    public let minimumInterval: Duration

    public init(
        interval: Duration = .seconds(300),
        minimumInterval: Duration = .seconds(60)
    ) {
        self.interval = interval
        self.minimumInterval = minimumInterval
    }

    public static let `default` = AutomaticRefreshPolicy()
}

/// Runs a cancellation-aware operation loop at a fixed interval.
///
/// The loop sleeps first, then runs the operation, and repeats until stopped.
/// Missed ticks after a long pause are not replayed. A `start` call cancels any
/// previous loop before scheduling a fresh one.
@MainActor
public final class AutomaticRefreshScheduler {
    private let policy: AutomaticRefreshPolicy
    private let sleep: @Sendable (Duration) async throws -> Void
    private var task: Task<Void, Never>?

    /// - Parameters:
    ///   - policy: default and minimum interval policy.
    ///   - sleep: injected sleeper for deterministic tests. Defaults to a
    ///     cancellation-aware `Task.sleep`.
    public init(
        policy: AutomaticRefreshPolicy = .default,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil
    ) {
        self.policy = policy
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
    }

    /// Starts or restarts the loop using the policy's default interval.
    public func start(operation: @escaping @Sendable () async -> Void) {
        start(interval: policy.interval, operation: operation)
    }

    /// Starts or restarts the loop with the given operation.
    ///
    /// The first iteration waits for `interval` before running, and the loop
    /// exits immediately if cancelled during sleep. Unsupported short intervals
    /// are clamped to the policy minimum.
    public func start(interval: Duration, operation: @escaping @Sendable () async -> Void) {
        let clamped = Swift.max(interval, policy.minimumInterval)
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