import Foundation

/// Orca as a source. Orca already reads the quota of every agent account it
/// manages (Claude and Codex accounts, active or not) and of the CLIs signed
/// in on this computer (Antigravity, Grok …). One `orca account list --json`
/// per refresh lists them and carries every reading, so `readUsage` makes no
/// call and Motas needs no credential. `baseURL` is the `orca` executable.
actor OrcaAdapter: ProxyAdapter {
    /// Runs the CLI with arguments and returns its standard output.
    typealias Runner = @Sendable (URL, [String]) async throws -> Data

    private let cli: URL
    private let run: Runner
    private let now: @Sendable () -> Date
    private var readings: [String: UsageReading] = [:]

    init(config: ProxyConfig, run: @escaping Runner = OrcaAdapter.process, now: @escaping @Sendable () -> Date = Date.init) {
        cli = config.baseURL
        self.run = run
        self.now = now
    }

    /// Where Orca installs its CLI, as a file URL.
    static let defaultCLI = URL(fileURLWithPath: "/Applications/Orca.app/Contents/Resources/bin/orca")

    func listAccounts() async throws -> [AccountDescriptor] {
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw ProxyAccessError.unreachable("Orca CLI not found at \(cli.path)")
        }
        let data = try await run(cli, ["account", "list", "--json"])
        let listing = try Self.parse(data, now: now())
        readings = listing.readings
        return listing.accounts
    }

    func readUsage(_ account: AccountDescriptor, force: Bool) async throws -> UsageReading {
        readings[account.id] ?? .failed(.transient("Orca no longer lists this account"))
    }

    // MARK: Parsing

    struct Listing {
        var accounts: [AccountDescriptor] = []
        var readings: [String: UsageReading] = [:]
    }

    /// Orca's figures older than this are not shown as current.
    static let staleAfter: TimeInterval = 3 * 3600

    /// Managed Claude and Codex accounts, then every other provider Orca reads
    /// on this computer. Providers Orca cannot read here (not signed in, not
    /// installed) are left out rather than listed as failing.
    static func parse(_ data: Data, now: Date) throws -> Listing {
        guard let root = JSON.object(data) else { throw ProxyAccessError.failed("Orca returned no JSON") }
        guard root["ok"] as? Bool == true, let result = root["result"] as? [String: Any] else {
            let message = ((root["error"] as? [String: Any])?["message"] as? String) ?? (root["error"] as? String) ?? "Orca refused the request"
            throw ProxyAccessError.unreachable(message)
        }
        let limits = result["rateLimits"] as? [String: Any] ?? [:]
        var listing = Listing()

        for (key, provider) in [("claude", Provider.claude), ("codex", Provider.codex)] {
            let section = result[key] as? [String: Any] ?? [:]
            var byAccount: [String: [String: Any]] = [:]
            for entry in limits["inactive\(key.prefix(1).uppercased() + key.dropFirst())Accounts"] as? [[String: Any]] ?? [] {
                if let id = entry["accountId"] as? String, let reading = entry["rateLimits"] as? [String: Any] { byAccount[id] = reading }
            }
            if let active = limits[key] as? [String: Any] {
                let reader = ((active["usageMetadata"] as? [String: Any])?["readingAccount"] as? [String: Any])?["accountId"] as? String
                if let id = reader ?? section["activeAccountId"] as? String { byAccount[id] = active }
            }
            for account in section["accounts"] as? [[String: Any]] ?? [] {
                guard let id = account["id"] as? String else { continue }
                let email = account["email"] as? String
                let identity = provider == .codex ? (account["providerAccountId"] as? String) ?? email?.lowercased() : email?.lowercased()
                let descriptor = AccountDescriptor(id: "\(key):\(id)", provider: provider, label: email ?? id, email: email,
                                                   identity: identity, metadataPlan: plan(fromWorkspace: account["workspaceLabel"] as? String))
                listing.accounts.append(descriptor)
                listing.readings[descriptor.id] = byAccount[id].map { reading($0, provider: provider, now: now) }
                    ?? .failed(.transient("Orca has not read this account yet"))
            }
        }

        // One entry per provider signed in on this computer.
        let others: [(key: String, provider: Provider)] = [
            ("antigravity", .antigravity), ("gemini", .geminiCLI), ("grok", Provider(rawValue: "grok")),
            ("kimi", Provider(rawValue: "kimi")), ("opencodeGo", Provider(rawValue: "opencode-go")),
            ("cursor", Provider(rawValue: "cursor")), ("minimax", Provider(rawValue: "minimax")),
            ("zcode", Provider(rawValue: "zcode")), ("muse", Provider(rawValue: "muse")),
        ]
        for (key, provider) in others {
            guard let entry = limits[key] as? [String: Any], entry["status"] as? String == "ok" else { continue }
            let descriptor = AccountDescriptor(id: key, provider: provider, label: "\(provider.displayName) on this Mac")
            listing.accounts.append(descriptor)
            listing.readings[descriptor.id] = reading(entry, provider: provider, now: now)
        }
        return listing
    }

    /// "Personal (Plus)" → "plus".
    static func plan(fromWorkspace label: String?) -> String? {
        guard let label, let open = label.lastIndex(of: "("), label.hasSuffix(")") else { return nil }
        let plan = label[label.index(after: open)..<label.index(before: label.endIndex)].lowercased()
        return plan.isEmpty ? nil : plan
    }

    /// One Orca rate-limit entry as a reading.
    static func reading(_ entry: [String: Any], provider: Provider, now: Date) -> UsageReading {
        guard entry["status"] as? String == "ok" else {
            let message = entry["error"] as? String ?? "Orca could not read this account"
            return .failed(failure(message))
        }
        if let updated = (entry["updatedAt"] as? Double).map({ Date(timeIntervalSince1970: $0 / 1000) }),
           now.timeIntervalSince(updated) > staleAfter {
            return .failed(.transient("Orca last read this account \(Int(now.timeIntervalSince(updated) / 3600)) h ago"))
        }
        var windows: [QuotaWindow] = []
        if let buckets = entry["buckets"] as? [[String: Any]], !buckets.isEmpty {
            for bucket in buckets {
                let family = group(bucket["group"] as? String)
                guard var window = window(bucket, id: bucket["name"] as? String ?? "bucket", group: family) else { continue }
                if let family { window.label = "\(QuotaGroups.label(provider: provider, group: family)) · \(window.label)" }
                windows.append(window)
            }
        } else {
            for (key, role) in [("session", WindowRole.limit), ("weekly", .limit), ("monthly", .limit), ("fableWeekly", .detail)] {
                guard let raw = entry[key] as? [String: Any], var window = window(raw, id: key, group: nil) else { continue }
                window.role = role
                if key == "fableWeekly" { window.label = "Fable · Weekly" }
                windows.append(window)
            }
        }
        guard !windows.isEmpty else {
            return .unavailable("Orca reports no limits for this account", recheckAfter: 3600, extras: UsageExtras())
        }
        let credits = (entry["rateLimitResetCredits"] as? [String: Any])?["availableCount"] as? Int
        let plan = (entry["planType"] as? String).flatMap { $0.isEmpty ? nil : $0.lowercased() }
        return .windows(windows, plan: plan, extras: UsageExtras(resetCredits: credits))
    }

    private static func window(_ raw: [String: Any], id: String, group: String?) -> QuotaWindow? {
        guard let used = raw["usedPercent"] as? Double else { return nil }
        let minutes = raw["windowMinutes"] as? Double
        let period: String? = switch minutes {
        case 300: "5h"
        case 1440: "daily"
        case 10080: "weekly"
        case let m?: "\(Int(m))m"
        case nil: id
        }
        let duration = minutes.map { $0 * 60 }
        return QuotaWindow(id: id, label: QuotaGroups.periodLabel(period ?? id, duration: duration), duration: duration,
                           remainingFraction: 1 - used / 100,
                           resetsAt: (raw["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
                           group: group, period: period)
    }

    /// Antigravity's bucket families, as `QuotaGroups` ids.
    private static func group(_ name: String?) -> String? {
        guard let name = name?.lowercased() else { return nil }
        if name.hasPrefix("gemini") { return "gemini" }
        if name.contains("claude") || name.contains("gpt") { return "claude-gpt" }
        if name.contains("image") { return "image" }
        return "other"
    }

    /// A revoked or rejected sign-in needs a re-login in Orca; anything else may pass.
    static func failure(_ message: String) -> UsageFailure {
        let lower = message.lowercased()
        if lower.contains("401") || lower.contains("token_revoked") || lower.contains("unauthorized") || lower.contains("sign in again") {
            return .credentialRejected("Sign-in rejected: log in again in Orca")
        }
        if lower.contains("429") || lower.contains("rate limit") { return .rateLimited(until: nil, "Rate limited while Orca read it") }
        // Orca quotes whole response bodies; keep the first line.
        return .transient(String(message.prefix { $0 != "\n" && $0 != ";" }.prefix(120)))
    }

    // MARK: Process

    /// Runs the CLI with a 20 s limit; a non-zero exit is the proxy's problem.
    static let process: Runner = { executable, arguments in
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let output = Pipe(), errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            process.standardInput = FileHandle.nullDevice
            let collected = OutputBox()
            output.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
            process.terminationHandler = { process in
                output.fileHandleForReading.readabilityHandler = nil
                let data = collected.data + output.fileHandleForReading.readDataToEndOfFile()
                if process.terminationStatus == 0 || !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let line = stderr.split(separator: "\n").first.map(String.init) ?? "exit \(process.terminationStatus)"
                    continuation.resume(throwing: ProxyAccessError.unreachable("Orca: \(line)"))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: ProxyAccessError.unreachable("Could not run Orca: \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 20) { if process.isRunning { process.terminate() } }
        }
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        func append(_ data: Data) { lock.withLock { buffer.append(data) } }
        var data: Data { lock.withLock { buffer } }
    }
}
