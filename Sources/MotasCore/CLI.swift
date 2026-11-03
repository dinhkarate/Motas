import Foundation
import os

/// What `motas` reads and writes. Tests inject every part.
public struct CLIEnvironment: Sendable {
    public var settings: SettingsStore
    public var secrets: any SecretStore
    public var http: any HTTPClient
    /// One line of secret input: prompted without echo on a TTY, else read
    /// from stdin. nil at the end of input.
    public var readSecret: @Sendable (_ prompt: String) -> String?
    /// Tells a running Motas to reload its settings and secrets.
    public var notify: @Sendable () -> Void
    /// Writes one line to stdout.
    public var out: @Sendable (String) -> Void
    /// Writes one line to stderr.
    public var err: @Sendable (String) -> Void
    /// Whether stdin is a terminal.
    public var isTTY: Bool

    public init(settings: SettingsStore, secrets: any SecretStore, http: any HTTPClient,
                readSecret: @escaping @Sendable (_ prompt: String) -> String?, notify: @escaping @Sendable () -> Void,
                out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void, isTTY: Bool) {
        self.settings = settings
        self.secrets = secrets
        self.http = http
        self.readSecret = readSecret
        self.notify = notify
        self.out = out
        self.err = err
        self.isTTY = isTTY
    }

    /// The user's settings.json and Keychain item, the network and the terminal.
    public static var live: CLIEnvironment {
        // Through the Homebrew `motas` symlink `.standard` is a domain of its
        // own, but the store's migration flag lives in the app's.
        let app = Bundle.motasApp?.bundleIdentifier
        let defaults = app.flatMap { $0 == Bundle.main.bundleIdentifier ? nil : UserDefaults(suiteName: $0) } ?? .standard
        return CLIEnvironment(
            settings: SettingsStore(url: SettingsStore.defaultURL),
            secrets: KeychainSecretStore(preferences: UIPreferences(defaults: defaults)),
            http: URLSessionHTTPClient(),
            readSecret: { prompt in
                guard isatty(STDIN_FILENO) == 1 else { return readLine() }
                var buffer = [CChar](repeating: 0, count: 1024)
                return buffer.withUnsafeMutableBufferPointer { buffer in
                    readpassphrase(prompt, buffer.baseAddress, buffer.count, RPP_REQUIRE_TTY).map { String(cString: $0) }
                }
            },
            notify: {
                DistributedNotificationCenter.default().postNotificationName(MotasCLI.settingsChanged, object: nil, userInfo: nil,
                                                                             deliverImmediately: true)
            },
            out: { print($0) },
            err: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) },
            isTTY: isatty(STDIN_FILENO) == 1)
    }
}

/// `motas` in a terminal: the app's binary run as a command. `motas proxy …`
/// changes settings.json and the Keychain item while the app keeps running,
/// then tells it to reload. It runs synchronously and never on the main
/// actor; async store and network calls are bridged with a semaphore.
public enum MotasCLI {
    /// Posted, delivered immediately, after every change.
    public static let settingsChanged = Notification.Name("dev.motas.settings-changed")

    /// The exit code: 0 ok, 64 usage, 65 bad input, 69 proxy unreachable, 75
    /// Keychain approval needed, 1 anything else. nil when `args` launch the
    /// app, which then never builds `env`.
    public static func run(_ args: [String], env makeEnv: @autoclosure () -> CLIEnvironment) -> Int32? {
        guard args.count > 1, ["proxy", "help", "--help", "-h", "version", "--version"].contains(args[1]) else { return nil }
        let env = makeEnv()
        do {
            switch args[1] {
            case "proxy": try ProxyCommand(env: env, args: args.dropFirst(2)).run()
            case "version", "--version": env.out(version)
            default: env.out(help)
            }
            return 0
        } catch let exit as Exit {
            env.err(exit.message)
            return exit.code
        } catch {
            env.err("\(error)")
            return 1
        }
    }

    /// Motas.app's CFBundleShortVersionString, else "dev".
    static var version: String {
        Bundle.motasApp?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    static let help = """
        Usage:
          motas proxy list [--json]
          motas proxy add --kind 9router|cliproxyapi --name NAME --url URL
                          [--auth cli-token|password|management-key] [--secret-stdin] [--disabled]
          motas proxy set-secret <id|name> [--secret-stdin]
          motas proxy remove|enable|disable <id|name>
          motas proxy test <id|name>
          motas version

        Changes reach a running Motas at once. <id|name> is a proxy's id, or its name in
        any case. --auth defaults to cli-token for 9router and management-key for
        cliproxyapi. `test` only lists the proxy's accounts.

          --secret-stdin           Read the secret as one line from stdin, without echo on a
                                   terminal. Secrets are never taken as arguments.
          --allow-keychain-prompt  Let macOS ask for Keychain access instead of exiting with 75.

        9Router CLI token: it is admin-equivalent. It passes every 9Router /api guard, the
        admin and local-only routes included, and never expires; Motas only uses it for two
        read-only requests. Derive it on the server:
          \(ProxyAuth.cliTokenRecipe)
        To rotate it, delete auth/cli-secret on the server.

        Exit codes: 0 ok, 64 usage, 65 bad input, 69 proxy unreachable,
        75 Keychain approval needed, 1 anything else.
        """
}

/// Ends a command with `code`; `message` goes to stderr.
private struct Exit: Error {
    var code: Int32
    var message: String

    static func usage(_ message: String) -> Exit { Exit(code: 64, message: "\(message) See `motas --help`.") }
    static func badInput(_ message: String) -> Exit { Exit(code: 65, message: message) }
    static let keychainApproval = Exit(
        code: 75, message: "Keychain needs approval for this Motas build: open Motas → Allow…, or rerun with --allow-keychain-prompt")
}

/// One command's `--option value`s, `--flag`s and positionals. A rejected
/// argument is never echoed: it may be a mistyped secret.
private struct Arguments {
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []

    init(_ args: ArraySlice<String>, options known: Set<String> = [], flags allowed: Set<String> = [], positionals expected: Int) throws {
        var rest = args
        while let arg = rest.popFirst() {
            if known.contains(arg) {
                guard let value = rest.popFirst() else { throw Exit.usage("\(arg) needs a value.") }
                options[arg] = value
            } else if allowed.contains(arg) || arg == "--allow-keychain-prompt" {
                flags.insert(arg)
            } else if arg.hasPrefix("-") {
                throw Exit.usage("Unknown option.")
            } else {
                positionals.append(arg)
            }
        }
        guard positionals.count == expected else {
            throw Exit.usage(expected == 0 ? "Unexpected argument." : "Name one proxy, by id or name.")
        }
    }
}

/// One `motas proxy` command.
private struct ProxyCommand {
    let env: CLIEnvironment
    let args: ArraySlice<String>
    /// --allow-keychain-prompt: approve, letting macOS ask, instead of exiting with 75.
    let allowPrompt: Bool

    init(env: CLIEnvironment, args: ArraySlice<String>) {
        self.env = env
        self.args = args
        allowPrompt = args.contains("--allow-keychain-prompt")
    }

    func run() throws {
        if args.contains("--help") || args.contains("-h") { return env.out(MotasCLI.help) }
        let rest = args.dropFirst()
        switch args.first ?? "" {
        case "list": try list(Arguments(rest, flags: ["--json"], positionals: 0))
        case "add":
            try add(Arguments(rest, options: ["--kind", "--name", "--url", "--auth"], flags: ["--secret-stdin", "--disabled"],
                              positionals: 0))
        case "set-secret": try setSecret(Arguments(rest, flags: ["--secret-stdin"], positionals: 1))
        case "remove": try remove(resolve(Arguments(rest, positionals: 1)))
        case "enable": try enable(resolve(Arguments(rest, positionals: 1)), true)
        case "disable": try enable(resolve(Arguments(rest, positionals: 1)), false)
        case "test": try test(resolve(Arguments(rest, positionals: 1)))
        case "": throw Exit.usage("Missing command.")
        default: throw Exit.usage("Unknown command.")
        }
    }

    private struct Row: Encodable {
        var id: UUID
        var name: String
        var kind: String
        var auth: String
        var enabled: Bool
        var url: URL
        /// "set", "missing" or "locked".
        var secret: String
    }

    private func list(_ a: Arguments) throws {
        let proxies = try loadSettings().proxies
        // One item holds every secret: open it once, then ask the cache.
        if let first = proxies.first { _ = try? storedSecret(first.id) }
        let presence = env.secrets.presence()
        let rows = proxies.map { proxy in
            Row(id: proxy.id, name: proxy.name, kind: Self.name(proxy.kind), auth: Self.name(proxy.auth), enabled: proxy.isEnabled,
                url: proxy.baseURL, secret: presence.contains(proxy.id).map { $0 ? "set" : "missing" } ?? "locked")
        }
        if a.flags.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            env.out(String(decoding: try encoder.encode(rows), as: UTF8.self))
        } else if rows.isEmpty {
            env.out("No proxies yet: add one with `motas proxy add`.")
        } else {
            let cells = [["ID", "NAME", "KIND", "AUTH", "ENABLED", "SECRET", "URL"]] + rows.map {
                [$0.id.uuidString, $0.name, $0.kind, $0.auth, $0.enabled ? "yes" : "no", $0.secret, $0.url.absoluteString]
            }
            // Every column but the last (the URL) padded to its widest cell.
            let widths = cells[0].indices.map { column in cells.map { $0[column].count }.max() ?? 0 }
            for row in cells {
                env.out((zip(row, widths).dropLast().map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) } + [row.last!])
                    .joined(separator: "  "))
            }
        }
    }

    private func add(_ a: Arguments) throws {
        guard let kindName = a.options["--kind"], let name = a.options["--name"], let urlText = a.options["--url"] else {
            throw Exit.usage("proxy add needs --kind, --name and --url.")
        }
        guard let kind = Self.kinds[kindName] else { throw Exit.usage("--kind is 9router or cliproxyapi.") }
        var auth = ProxyAuth.newDefault(for: kind)
        if let authName = a.options["--auth"] {
            guard let chosen = Self.auths[authName] else { throw Exit.usage("--auth is cli-token, password or management-key.") }
            auth = chosen
        }
        guard (kind == .cliProxyAPI) == (auth == .managementKey) else {
            throw Exit.usage("9router signs in with cli-token or password, cliproxyapi with management-key.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw Exit.badInput("The name is empty.") }
        guard let url = ProxyConfig.baseURL(from: urlText) else {
            throw Exit.badInput("The URL must be http or https with a host, and no credentials, query or fragment.")
        }
        let secret = a.flags.contains("--secret-stdin") ? try readSecret(auth, for: trimmed) : nil
        if auth.needsSecret || secret != nil { try checkSecretURL(url) }
        let proxy = ProxyConfig(name: trimmed, kind: kind, baseURL: url, auth: auth, isEnabled: !a.flags.contains("--disabled"))
        // Approval first, so a 75 changes nothing.
        if secret != nil { _ = try keychain { try storedSecret(proxy.id) } }
        try updateSettings { $0.proxies.append(proxy) }
        defer { env.notify() }
        env.out(proxy.id.uuidString)
        if let secret { try store(secret, for: proxy) }
    }

    private func setSecret(_ a: Arguments) throws {
        let proxy = try resolve(a)
        guard a.flags.contains("--secret-stdin") || env.isTTY else {
            throw Exit.usage("set-secret reads the secret from stdin: pass --secret-stdin.")
        }
        let secret = try readSecret(proxy.auth, for: proxy.name)
        try checkSecretURL(proxy.baseURL)
        _ = try keychain { try storedSecret(proxy.id) }
        try store(secret, for: proxy)
        env.notify()
        env.out("Stored the secret for \(proxy.name).")
    }

    private func remove(_ proxy: ProxyConfig) throws {
        let stored = try keychain { try storedSecret(proxy.id) }
        try updateSettings { $0.proxies.removeAll { $0.id == proxy.id } }
        defer { env.notify() }
        env.out("Removed \(proxy.name).")
        if stored != nil { try store(nil, for: proxy) }
    }

    private func enable(_ proxy: ProxyConfig, _ enabled: Bool) throws {
        try updateSettings { settings in
            for index in settings.proxies.indices where settings.proxies[index].id == proxy.id {
                settings.proxies[index].isEnabled = enabled
            }
        }
        env.notify()
        env.out("\(enabled ? "Enabled" : "Disabled") \(proxy.name).")
    }

    /// Lists only, like Settings' Test button. Offline or unreachable is 69.
    private func test(_ proxy: ProxyConfig) throws {
        let secret = try keychain { try storedSecret(proxy.id) }
        let adapter = ProxyAdapters.make(proxy, secret: secret, http: env.http)
        do {
            env.out(AccountDescriptor.summary(try bridge { try await adapter.listAccounts() }))
        } catch {
            let failure = ProxyAccessError(error)
            switch failure {
            case .offline, .unreachable: throw Exit(code: 69, message: failure.summary)
            default: throw Exit(code: 1, message: failure.summary)
            }
        }
    }

    /// A full id, else a case-insensitive exact name. Unknown or ambiguous
    /// lists the candidates.
    private func resolve(_ a: Arguments) throws -> ProxyConfig {
        let ref = a.positionals[0]
        let proxies = try loadSettings().proxies
        if let id = UUID(uuidString: ref), let proxy = proxies.first(where: { $0.id == id }) { return proxy }
        let matches = proxies.filter { $0.name.caseInsensitiveCompare(ref) == .orderedSame }
        if matches.count == 1 { return matches[0] }
        let lead = !matches.isEmpty ? "Several proxies have that name; use an id:"
            : proxies.isEmpty ? "No proxies yet: add one with `motas proxy add`." : "No proxy has that id or name. Proxies:"
        let candidates = (matches.isEmpty ? proxies : matches).map { "  \($0.id.uuidString)  \($0.name)" }
        throw Exit(code: 64, message: ([lead] + candidates).joined(separator: "\n"))
    }

    /// One line of secret input, checked for `auth`; a CLI token's problem
    /// comes with the recipe.
    private func readSecret(_ auth: ProxyAuth, for name: String) throws -> String {
        guard let secret = env.readSecret("\(Self.label(auth)) for \(name): ") else { throw Exit.badInput("No secret on stdin.") }
        guard let problem = auth.problem(with: secret) else { return secret }
        throw Exit.badInput(auth == .cliToken ? "\(problem) Derive the token on the server:\n  \(ProxyAuth.cliTokenRecipe)" : problem)
    }

    /// Plain HTTP may carry a secret only to a private host, as in the adapters.
    private func checkSecretURL(_ url: URL) throws {
        do {
            try checkPlainHTTP(url)
        } catch ProxyAccessError.failed(let message) {
            throw Exit.badInput("\(message).")
        }
    }

    /// `id`'s secret, read without a prompt, or after an approval (macOS may
    /// ask) with --allow-keychain-prompt.
    private func storedSecret(_ id: UUID) throws -> String? {
        do {
            return try env.secrets.secret(for: id)
        } catch SecretStoreError.needsApproval where allowPrompt {
            try bridge { [env] in try await env.secrets.approve() }
            return try env.secrets.secret(for: id)
        }
    }

    private func store(_ secret: String?, for proxy: ProxyConfig) throws {
        try keychain { try bridge { [env] in try await env.secrets.setSecret(secret, for: proxy.id) } }
    }

    /// Keychain errors as exits: approval needed is 75, anything else 1.
    private func keychain<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch SecretStoreError.needsApproval {
            throw Exit.keychainApproval
        } catch {
            throw Exit(code: 1, message: "Keychain: \(error)")
        }
    }

    private func loadSettings() throws -> MotasSettings {
        do {
            return try env.settings.load()
        } catch {
            throw Exit(code: 1, message: "settings.json is unreadable: \(error.localizedDescription)")
        }
    }

    /// Through `SettingsStore.update`, so what the app saved meanwhile is kept.
    private func updateSettings(_ change: (inout MotasSettings) -> Void) throws {
        do {
            try env.settings.update(change)
        } catch {
            throw Exit(code: 1, message: "Could not update settings.json: \(error.localizedDescription)")
        }
    }

    /// Waits for an async store or network call, which runs on the global
    /// executor, never on the main actor.
    private func bridge<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let done = DispatchSemaphore(value: 0)
        let result = OSAllocatedUnfairLock<Result<T, any Error>?>(initialState: nil)
        Task.detached {
            do {
                let value = try await operation()
                result.withLock { $0 = .success(value) }
            } catch {
                result.withLock { $0 = .failure(error) }
            }
            done.signal()
        }
        done.wait()
        return try result.withLock { $0! }.get()
    }

    private static let kinds: [String: ProxyKind] = ["9router": .nineRouter, "cliproxyapi": .cliProxyAPI]
    private static let auths: [String: ProxyAuth] = ["cli-token": .cliToken, "password": .password, "management-key": .managementKey]

    private static func name(_ kind: ProxyKind) -> String { kinds.first { $0.value == kind }!.key }
    private static func name(_ auth: ProxyAuth) -> String { auths.first { $0.value == auth }!.key }

    private static func label(_ auth: ProxyAuth) -> String {
        switch auth {
        case .cliToken: "CLI token"
        case .password: "Dashboard password"
        case .managementKey: "Management key"
        }
    }
}

extension Bundle {
    /// Motas.app when this binary runs from it, also through the Homebrew
    /// `motas` symlink, where `Bundle.main` is the symlink's directory.
    static var motasApp: Bundle? {
        guard let app = Bundle.main.executableURL?.resolvingSymlinksInPath()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
              app.pathExtension == "app" else { return nil }
        return Bundle(url: app)
    }
}
