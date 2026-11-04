import Foundation

/// What Motas remembers about one account between refreshes.
public struct AccountRecord: Codable, Sendable, Hashable {
    /// Last good windows.
    public var windows: [QuotaWindow]?
    /// When `windows` were read.
    public var observedAt: Date?
    /// Last resolved plan.
    public var plan: String?
    public var extras = UsageExtras()
    /// Set ⇔ the account is unmetered (a by-design message).
    public var unavailable: String?
    public var unavailableStreak = 0
    /// Last failed read's message; nil after a success.
    public var lastError: String?
    /// Consecutive transient / rate-limited reads.
    public var failureStreak = 0
    /// Consecutive credential-rejected reads; two make the account rejected.
    public var rejectStreak = 0
    public var rateLimitedUntil: Date?
    /// nil = due now.
    public var nextReadAt: Date?

    public var isRejected: Bool { rejectStreak >= 2 }

    /// Merges one completed read.
    mutating func apply(_ reading: UsageReading, metadataPlan: String?, now: Date) {
        switch reading {
        case .windows(let windows, let plan, let extras):
            self = AccountRecord(windows: windows, observedAt: now, plan: plan ?? self.plan ?? metadataPlan, extras: extras)
        case .unavailable(let message, let recheck, let extras):
            unavailableStreak += 1
            // A metered account that suddenly reports no figures is more likely
            // a hiccup: keep its recent windows for two more reads.
            if let observedAt, windows != nil, now.timeIntervalSince(observedAt) < 24 * 3600, unavailableStreak < 3 {
                failed(message, rateLimitedUntil: nil, now: now)
            } else {
                self = AccountRecord(plan: plan, extras: extras, unavailable: message, unavailableStreak: unavailableStreak,
                                     nextReadAt: now.addingTimeInterval(recheck))
            }
        case .failed(let failure):
            switch failure.kind {
            case .transient:
                failed(failure.message, rateLimitedUntil: nil, now: now)
            case .rateLimited(let until):
                failed(failure.message, rateLimitedUntil: until, now: now)
            case .credentialRejected:
                // One rejection keeps the windows and re-reads next cycle; the
                // second makes the account rejected, rechecked every 15 min.
                rejectStreak += 1
                lastError = failure.message
                nextReadAt = isRejected ? now.addingTimeInterval(15 * 60) : nil
            }
        }
    }

    /// The windows stay (now stale); the next read backs off 5 min doubling to
    /// 60 min, or waits for the rate limit if that ends later.
    private mutating func failed(_ message: String, rateLimitedUntil until: Date?, now: Date) {
        lastError = message
        failureStreak += 1
        rejectStreak = 0
        let backoff = now.addingTimeInterval(min(300 * pow(2, Double(failureStreak - 1)), 3600))
        nextReadAt = max(backoff, until ?? backoff)
        rateLimitedUntil = until
    }
}

/// One proxy's reading state: plain values merged by the pure `apply`.
public struct ProxyState: Codable, Sendable, Hashable {
    /// The last built accounts, carried when a refresh cannot list.
    public var accounts: [AccountSnapshot]
    public var records: [String: AccountRecord]
    public var lastSuccessAt: Date?
    public var consecutiveFailures: Int

    /// Rebuilds the records from a restored snapshot. 0.2 snapshots have no
    /// `quotaObservedAt`; their windows were read at the proxy's `fetchedAt`.
    /// Their plans were kept as read ("unknown", "Antigravity"), so they are
    /// normalised like any plan read now.
    public init(seed: ProxySnapshot?) {
        accounts = (seed?.accounts ?? []).map { account in
            var account = account
            if case .windows = account.quota, account.quotaObservedAt == nil { account.quotaObservedAt = seed?.fetchedAt }
            account.plan = ProviderUsage.normalisedPlan(account.plan, provider: account.provider)
            account.metadataPlan = ProviderUsage.normalisedPlan(account.metadataPlan, provider: account.provider)
            return account
        }
        lastSuccessAt = seed?.lastSuccessAt
        consecutiveFailures = seed?.consecutiveFailures ?? 0
        records = [:]
        for account in accounts {
            var record = AccountRecord(plan: account.plan, extras: account.extras, rateLimitedUntil: account.rateLimitedUntil,
                                       nextReadAt: account.nextReadAt)
            switch account.quota {
            case .windows(let windows):
                record.windows = windows
                record.observedAt = account.quotaObservedAt
                record.lastError = account.lastReadError
            case .unavailable(let message):
                record.unavailable = message
            case .failed(let message):
                record.lastError = message
            case .rejected(let message):
                record.lastError = message
                record.rejectStreak = 2
            }
            records[account.id] = record
        }
    }

    /// The accounts to read now, most useful first: those with windows (oldest
    /// first), never read, failed or rejected, then unmetered rechecks.
    /// Disabled accounts are never read. `force` also reads accounts waiting on
    /// a backoff or a rejection recheck, but never unmetered ones, and nothing
    /// is read before its rate limit ends.
    public func due(_ list: [AccountDescriptor], now: Date, force: Bool) -> [AccountDescriptor] {
        func rank(_ record: AccountRecord?) -> Int {
            guard let record else { return 1 }
            if record.isRejected { return 2 }
            if record.windows != nil { return 0 }
            if record.unavailable != nil { return 3 }
            return record.lastError != nil ? 2 : 1
        }
        return list.enumerated()
            .filter { _, account in
                let record = records[account.id]
                if account.isDisabled { return false }
                if let until = record?.rateLimitedUntil, until > now { return false }
                guard let next = record?.nextReadAt, next > now else { return true }
                return force && record?.unavailable == nil
            }
            .sorted { a, b in
                let ra = records[a.element.id], rb = records[b.element.id]
                if rank(ra) != rank(rb) { return rank(ra) < rank(rb) }
                let oa = ra?.observedAt ?? .distantPast, ob = rb?.observedAt ?? .distantPast
                if rank(ra) == 0, oa != ob { return oa < ob }
                return a.offset < b.offset
            }
            .map(\.element)
    }

    /// Merges one refresh. Health comes from the listing and an abort only:
    /// a failed listing carries the accounts, an abort keeps the reads that
    /// completed. Accounts missing from a successful listing are dropped.
    public mutating func apply(_ outcome: ReadOutcome, config: ProxyConfig, now: Date) -> ProxySnapshot {
        let list: [AccountDescriptor]
        switch outcome.list {
        case .success(let accounts):
            list = accounts
        case .failure(let error):
            consecutiveFailures += 1
            return carried(.failed(error), config: config, now: now)
        }
        let listed = Set(list.map(\.id))
        records = records.filter { listed.contains($0.key) }
        for account in list {
            guard let reading = outcome.reads[account.id] else { continue }
            records[account.id, default: AccountRecord()].apply(reading, metadataPlan: account.metadataPlan, now: now)
        }
        accounts = list.map(snapshot(of:))
        if let abort = outcome.abort {
            consecutiveFailures += 1
            return carried(.failed(abort), config: config, now: now)
        }
        lastSuccessAt = now
        consecutiveFailures = 0
        return carried(.ok, config: config, now: now)
    }

    /// The carried accounts with `health`: for Keychain approval, a missing
    /// credential and other local problems. It never changes the failure count
    /// or `lastSuccessAt`, so it never alerts.
    public func carried(_ health: ProxyHealth, config: ProxyConfig, now: Date) -> ProxySnapshot {
        ProxySnapshot(id: config.id, name: config.name, kind: config.kind, fetchedAt: now, health: health, accounts: accounts,
                      lastSuccessAt: lastSuccessAt, consecutiveFailures: consecutiveFailures)
    }

    /// What the snapshot shows for `account`, from its record.
    func snapshot(of account: AccountDescriptor) -> AccountSnapshot {
        let record = records[account.id] ?? AccountRecord()
        var snapshot = AccountSnapshot(
            id: account.id, provider: account.provider, label: account.label, email: account.email, identity: account.identity,
            plan: record.plan ?? account.metadataPlan, metadataPlan: account.metadataPlan,
            state: account.isDisabled ? .disabled : .active, quota: .failed("Not read yet"), nextReadAt: record.nextReadAt,
            rateLimitedUntil: record.rateLimitedUntil, cooldownUntil: account.cooldownUntil, coolingDown: account.coolingDown,
            lockedModels: account.lockedModels, proxyNote: account.proxyNote, extras: record.extras, displayHint: account.displayHint)
        if record.isRejected {
            snapshot.quota = .rejected(record.lastError ?? "")
        } else if let windows = record.windows {
            snapshot.quota = .windows(windows)
            snapshot.quotaObservedAt = record.observedAt
            snapshot.lastReadError = record.lastError
        } else if let message = record.unavailable {
            snapshot.quota = .unavailable(message)
        } else if let error = record.lastError {
            snapshot.quota = .failed(error)
        }
        return snapshot
    }
}

/// One refresh of one proxy, as `ProxyRead.run` saw it.
public struct ReadOutcome: Sendable {
    public var list: Result<[AccountDescriptor], ProxyAccessError>
    /// Completed reads only, by account id.
    public var reads: [String: UsageReading]
    /// Thrown by a read; no later read started.
    public var abort: ProxyAccessError?
    /// Due reads skipped because the budget ran out.
    public var notStarted: Int
}
