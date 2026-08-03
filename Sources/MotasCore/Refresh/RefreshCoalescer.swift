/// Serializes refresh requests while tracking configuration revisions.
///
/// One batch may run at a time. Extra requests coalesce into one follow-up
/// batch, and a result captured before a configuration change is discarded.
public struct RefreshCoalescer: Sendable, Equatable {
    public private(set) var isRefreshing = false
    public private(set) var configurationRevision = 0
    private var hasPendingRefresh = false

    public init() {}

    /// Begins a refresh and returns the revision it must capture. If a batch is
    /// already active, records one pending request and returns `nil`.
    public mutating func begin() -> Int? {
        guard !isRefreshing else {
            hasPendingRefresh = true
            return nil
        }
        isRefreshing = true
        return configurationRevision
    }

    /// Marks a configuration change. Any in-flight result becomes obsolete and
    /// one current-configuration follow-up batch is requested.
    public mutating func configurationDidChange() {
        configurationRevision += 1
        if isRefreshing {
            hasPendingRefresh = true
        }
    }

    public func shouldApplyResult(capturedAt revision: Int) -> Bool {
        revision == configurationRevision
    }

    /// Finishes the active batch and returns whether one follow-up should begin.
    public mutating func finish() -> Bool {
        isRefreshing = false
        let shouldRefreshAgain = hasPendingRefresh
        hasPendingRefresh = false
        return shouldRefreshAgain
    }
}
