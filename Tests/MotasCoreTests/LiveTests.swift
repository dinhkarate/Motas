import Foundation
import Testing
@testable import MotasCore

/// Hits real proxies. Skipped unless MOTAS_LIVE=1 with
/// MOTAS_CPA_URL/MOTAS_CPA_KEY and MOTAS_9R_URL/MOTAS_9R_PASSWORD set.
@Suite("Live proxies", .enabled(if: ProcessInfo.processInfo.environment["MOTAS_LIVE"] == "1"))
struct LiveTests {
    let env = ProcessInfo.processInfo.environment

    @Test func cliProxyAPI() async throws {
        let config = ProxyConfig(name: "live", kind: .cliProxyAPI, baseURL: try #require(URL(string: env["MOTAS_CPA_URL"] ?? "")))
        let snap = await CLIProxyAPIAdapter(config: config, managementKey: env["MOTAS_CPA_KEY"], http: URLSessionHTTPClient()).fetch()
        report(snap)
        #expect(snap.health == .ok)
        #expect(!snap.accounts.isEmpty)
        #expect(snap.accounts.allSatisfy { if case .failed = $0.quota { false } else { true } })
    }

    @Test func nineRouter() async throws {
        let config = ProxyConfig(name: "live", kind: .nineRouter, baseURL: try #require(URL(string: env["MOTAS_9R_URL"] ?? "")))
        let snap = await NineRouterAdapter(config: config, password: env["MOTAS_9R_PASSWORD"], http: URLSessionHTTPClient()).fetch()
        report(snap)
        #expect(snap.health == .ok)
        #expect(!snap.accounts.isEmpty)
    }

    func report(_ snap: ProxySnapshot) {
        print("[live] \(snap.kind.displayName) health=\(snap.health)")
        for a in snap.accounts {
            let quota = switch a.quota {
            case .windows(let w): w.map { "\($0.label)=\(Int(($0.remainingFraction * 100).rounded()))%" }.joined(separator: ",")
            case .unavailable(let m): "unavailable(\(m))"
            case .failed(let m): "failed(\(m))"
            }
            print("[live]   \(a.provider.rawValue) plan=\(a.plan ?? "-") state=\(a.state.rawValue) \(quota)")
        }
    }
}
