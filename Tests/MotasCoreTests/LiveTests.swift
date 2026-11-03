import Foundation
import Testing
@testable import MotasCore

/// Hits real proxies. Skipped unless MOTAS_LIVE=1 with MOTAS_CPA_URL/MOTAS_CPA_KEY
/// and MOTAS_9R_URL with MOTAS_9R_TOKEN (or MOTAS_9R_PASSWORD); run it through keyshroud.
@Suite("Live proxies", .enabled(if: ProcessInfo.processInfo.environment["MOTAS_LIVE"] == "1"))
struct LiveTests {
    let env = ProcessInfo.processInfo.environment

    func read(_ config: ProxyConfig, secret: String?) async -> ProxySnapshot {
        let adapter = ProxyAdapters.make(config, secret: secret, http: URLSessionHTTPClient())
        var state = ProxyState(seed: nil)
        let outcome = await ProxyRead.run(adapter, state: state, now: .now, force: false)
        return state.apply(outcome, config: config, now: .now)
    }

    @Test func cliProxyAPI() async throws {
        let config = ProxyConfig(name: "live", kind: .cliProxyAPI, baseURL: try #require(URL(string: env["MOTAS_CPA_URL"] ?? "")))
        let snap = await read(config, secret: env["MOTAS_CPA_KEY"])
        report(snap)
        #expect(snap.health == .ok)
        #expect(!snap.accounts.isEmpty)
    }

    @Test func nineRouter() async throws {
        let token = env["MOTAS_9R_TOKEN"]
        let config = ProxyConfig(name: "live", kind: .nineRouter, baseURL: try #require(URL(string: env["MOTAS_9R_URL"] ?? "")),
                                 auth: token == nil ? .password : .cliToken)
        let snap = await read(config, secret: token ?? env["MOTAS_9R_PASSWORD"])
        report(snap)
        #expect(snap.health == .ok)
        #expect(!snap.accounts.isEmpty)
    }

    func report(_ snap: ProxySnapshot) {
        print("[live] \(snap.kind.displayName) health=\(snap.health.logLabel)")
        for a in snap.accounts {
            let quota = switch a.quota {
            case .windows(let w): w.map { "\($0.label)=\(Int(($0.remainingFraction * 100).rounded()))%" }.joined(separator: ",")
            case .unavailable(let m): "unavailable(\(m))"
            case .failed(let m): "failed(\(m))"
            case .rejected(let m): "rejected(\(m))"
            }
            print("[live]   \(a.provider.rawValue) plan=\(a.plan ?? "-") state=\(a.state.rawValue) \(quota)")
        }
    }
}
