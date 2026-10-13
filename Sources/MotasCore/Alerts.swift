import Foundation

public struct Alert: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case poolLow(Provider)
        case poolRecovered(Provider)
        case proxyDown(UUID)
        case proxyRecovered(UUID)
    }

    public var kind: Kind
    public var title: String
    public var body: String
}

/// Decides which notifications a refresh should produce, by comparing the
/// previous and current snapshots. Pure: delivery happens in the app.
/// Only transitions alert — a pool that stays low does not re-notify.
public enum AlertRules {
    public static func alerts(previous: Snapshot?, current: Snapshot, threshold: Double) -> [Alert] {
        guard let previous, !previous.proxies.isEmpty else { return [] }
        var alerts: [Alert] = []

        let before = Dictionary(uniqueKeysWithValues: Pool.summarize(previous).map { ($0.provider, $0) })
        for pool in Pool.summarize(current) {
            guard let now = pool.reserve, let then = before[pool.provider]?.reserve else { continue }
            let percent = Int((now * 100).rounded())
            if then >= threshold, now < threshold {
                var body = "\(pool.provider.displayName) pool is at \(percent)% (\(pool.exhaustedCount) of \(pool.measuredCount) accounts exhausted)."
                if let reset = pool.nextReset {
                    body += " Next reset \(reset.formatted(.relative(presentation: .named)))."
                }
                alerts.append(Alert(kind: .poolLow(pool.provider), title: "\(pool.provider.displayName) quota low", body: body))
            } else if then < threshold, now >= threshold {
                alerts.append(Alert(kind: .poolRecovered(pool.provider), title: "\(pool.provider.displayName) quota recovered",
                                    body: "\(pool.provider.displayName) pool is back to \(percent)%."))
            }
        }

        let oldProxies = Dictionary(uniqueKeysWithValues: previous.proxies.map { ($0.id, $0) })
        for proxy in current.proxies {
            guard let old = oldProxies[proxy.id] else { continue }
            if old.health.isOK, !proxy.health.isOK {
                alerts.append(Alert(kind: .proxyDown(proxy.id), title: "\(proxy.name) unavailable", body: proxy.health.summary))
            } else if !old.health.isOK, proxy.health.isOK {
                alerts.append(Alert(kind: .proxyRecovered(proxy.id), title: "\(proxy.name) is back", body: "Quota monitoring resumed."))
            }
        }
        return alerts
    }
}

extension ProxyHealth {
    public var summary: String {
        switch self {
        case .ok: "Connected"
        case .unauthorized: "Credentials were rejected. Check the key or password in Settings."
        case .unreachable(let reason): "Cannot reach the proxy: \(reason)."
        case .failed(let reason): "The proxy returned an error: \(reason)."
        }
    }
}
