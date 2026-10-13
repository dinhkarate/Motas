import Foundation

/// Refreshes every enabled proxy concurrently. Keeps one adapter per proxy
/// (so 9Router sessions are reused) and rebuilds it when its config or
/// secret changes.
public actor Monitor {
    private let http: any HTTPClient
    private var adapters: [UUID: (key: String, adapter: any ProxyAdapter)] = [:]

    public init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    public func refresh(_ configs: [ProxyConfig], secrets: any SecretStore, now: Date = Date()) async -> Snapshot {
        let enabled = configs.filter(\.isEnabled)
        adapters = adapters.filter { id, _ in enabled.contains { $0.id == id } }

        var work: [(Int, any ProxyAdapter, ProxyConfig)] = []
        var failures: [Int: ProxySnapshot] = [:]
        for (index, config) in enabled.enumerated() {
            let secret: String?
            do {
                secret = try secrets.secret(for: config.id, interactive: false)
            } catch SecretStoreError.needsApproval {
                failures[index] = ProxySnapshot(id: config.id, name: config.name, kind: config.kind, fetchedAt: now,
                                                health: .needsKeychainAccess, accounts: [])
                continue
            } catch {
                failures[index] = ProxySnapshot(id: config.id, name: config.name, kind: config.kind, fetchedAt: now,
                                                health: .failed("Keychain: \(error)"), accounts: [])
                continue
            }
            let key = "\(config.kind)|\(config.baseURL.absoluteString)|\(config.name)|\((secret ?? "").hashValue)"
            if adapters[config.id]?.key != key {
                adapters[config.id] = (key, ProxyAdapters.make(config, secret: secret, http: http))
            }
            work.append((index, adapters[config.id]!.adapter, config))
        }

        let fetched = await withTaskGroup(of: (Int, ProxySnapshot).self) { group in
            for (index, adapter, _) in work {
                group.addTask { (index, await adapter.fetch()) }
            }
            var out: [Int: ProxySnapshot] = [:]
            for await (index, snap) in group { out[index] = snap }
            return out
        }
        let all = fetched.merging(failures) { a, _ in a }
        return Snapshot(fetchedAt: now, proxies: all.keys.sorted().map { all[$0]! })
    }

    /// One-off read with an unsaved config, for Settings' "Test connection".
    public func test(_ config: ProxyConfig, secret: String?) async -> ProxySnapshot {
        await ProxyAdapters.make(config, secret: secret, http: http).fetch()
    }
}
