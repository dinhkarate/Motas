import Foundation
import Testing
@testable import MotasCore

/// Secrets only these tests use: no 6-character piece of one is ever printed.
let cliTestToken = "9f3e7d1c5b8a2f60"
let cliOtherToken = "5a1c9e3b7d2f4068"
/// 64 hex characters, like the `auth/cli-secret` file a CLI token is derived from.
let cliSecretFile = String(repeating: "7c2e9a4f1b6d3e8a", count: 4)
let cliManagementKey = "Qz8!wPx#Lm2@"
let cliPassword = "Pw*7hJ&q"

/// Every 6-character piece of `secret`.
func fragments(of secret: String) -> [String] {
    let characters = Array(secret)
    return (0...max(0, characters.count - 6)).map { String(characters[$0..<min($0 + 6, characters.count)]) }
}

/// One `motas` run's terminal: scripted secret input, and what was printed and prompted.
final class Terminal: @unchecked Sendable {
    private let lock = NSLock()
    private var input: [String]
    private var _out: [String] = []
    private var _err: [String] = []
    private var _prompts: [String] = []

    init(input: [String]) { self.input = input }

    var out: String { lock.withLock { _out.joined(separator: "\n") } }
    var err: String { lock.withLock { _err.joined(separator: "\n") } }
    var prompts: [String] { lock.withLock { _prompts } }

    func readSecret(_ prompt: String) -> String? {
        lock.withLock {
            _prompts.append(prompt)
            return input.isEmpty ? nil : input.removeFirst()
        }
    }

    func write(_ line: String) { lock.withLock { _out.append(line) } }
    func writeError(_ line: String) { lock.withLock { _err.append(line) } }
}

struct CLIRun {
    var code: Int32?
    var out: String
    var err: String
    var prompts: [String]
}

/// What `motas` runs against: a temporary settings.json, a secret store and a
/// proxy stub that every run shares, and the notifications the runs posted.
final class CLIMachine: @unchecked Sendable {
    let settings = SettingsStore(url: tempURL("settings.json"))
    let secrets: InMemorySecretStore
    let http: StubHTTP
    private let lock = NSLock()
    private var _notifications = 0
    private var _transcript: [String] = []

    init(secrets: InMemorySecretStore = InMemorySecretStore(), http: StubHTTP = StubHTTP { _ in (404, Data(), [:]) }) {
        self.secrets = secrets
        self.http = http
    }

    var notifications: Int { lock.withLock { _notifications } }
    /// Everything every run printed or prompted.
    var transcript: String { lock.withLock { _transcript.joined(separator: "\n") } }
    var proxies: [ProxyConfig] { (try? settings.load().proxies) ?? [] }

    func proxy(_ name: String) -> ProxyConfig? { proxies.first { $0.name == name } }
    func secret(_ name: String) -> String? { proxy(name).flatMap { try? secrets.secret(for: $0.id) } }

    func motas(_ args: String..., input: [String] = [], tty: Bool = false) async -> CLIRun {
        await motas(args, input: input, tty: tty)
    }

    /// Runs `motas <args>` on a thread of its own: the CLI waits on
    /// semaphores, which must never hold a cooperative thread. `bundle` is
    /// where the binary runs from: Motas.app unless a test says otherwise.
    func motas(_ args: [String], input: [String] = [], tty: Bool = false, bundle: URL = tempURL("Motas.app")) async -> CLIRun {
        let terminal = Terminal(input: input)
        let env = CLIEnvironment(settings: settings, secrets: secrets, http: http, readSecret: { terminal.readSecret($0) },
                                 notify: { [self] in lock.withLock { _notifications += 1 } },
                                 out: { terminal.write($0) }, err: { terminal.writeError($0) }, isTTY: tty)
        let code = await withCheckedContinuation { (continuation: CheckedContinuation<Int32?, Never>) in
            Thread { continuation.resume(returning: MotasCLI.run(["motas"] + args, bundle: bundle, env: env)) }.start()
        }
        let run = CLIRun(code: code, out: terminal.out, err: terminal.err, prompts: terminal.prompts)
        lock.withLock { _transcript += [run.out, run.err] + run.prompts }
        return run
    }
}

@Suite("CLI", .timeLimit(.minutes(1)))
struct CLITests {
    @Test func anythingButACommandLaunchesTheApp() async {
        let machine = CLIMachine()
        for args in [[], ["-NSDocumentRevisionsDebugMode", "YES"], ["-psn_0_12345"], ["status"], ["Proxy", "list"], ["--proxy"]] {
            #expect(await machine.motas(args).code == nil)
        }
        #expect(machine.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Through the Homebrew `motas` symlink the binary is outside Motas.app:
    /// anything but a command prints help rather than start a second app.
    @Test func outsideTheAppAnythingButACommandIsAUsageError() async {
        let machine = CLIMachine()
        let symlinked = URL(fileURLWithPath: "/opt/homebrew/bin")
        for args in [[], ["status"], ["-psn_0_12345"]] {
            let run = await machine.motas(args, bundle: symlinked)
            #expect(run.code == 64 && run.out.isEmpty && run.err.hasPrefix("Usage:"))
        }
        #expect(await machine.motas(["version"], bundle: symlinked).code == 0)
    }

    @Test func helpCarriesTheRecipeAndTheWarning() async {
        let machine = CLIMachine()
        for args in [["help"], ["--help"], ["-h"], ["proxy", "--help"], ["proxy", "add", "-h"]] {
            let run = await machine.motas(args)
            #expect(run.code == 0 && run.err.isEmpty)
            #expect(run.out.contains(ProxyAuth.cliTokenRecipe) && run.out.contains("admin-equivalent"))
            #expect(run.out.contains("75 Keychain approval needed"))
        }
        #expect(machine.notifications == 0)
    }

    @Test func versionIsTheAppsOrDev() async {
        let machine = CLIMachine()
        for args in [["version"], ["--version"]] {
            let run = await machine.motas(args)
            #expect(run.code == 0 && run.out == MotasCLI.version)
        }
        #expect(MotasCLI.version == "dev")    // the test runner is not inside Motas.app
    }

    @Test func addListEnableDisableRemove() async throws {
        let machine = CLIMachine()
        let empty = await machine.motas("proxy", "list")
        #expect(empty.code == 0 && empty.out == "No proxies yet: add one with `motas proxy add`.")

        let cpa = await machine.motas("proxy", "add", "--kind", "cliproxyapi", "--name", " Home CPA ", "--url", "http://cpa.local:8317",
                                      "--secret-stdin", input: [cliManagementKey])
        #expect(cpa.code == 0 && cpa.err.isEmpty)
        #expect(cpa.prompts == ["Management key for Home CPA: "])
        let home = try #require(machine.proxy("Home CPA"))
        #expect(cpa.out == home.id.uuidString)
        #expect(home.kind == .cliProxyAPI && home.auth == .managementKey && home.isEnabled)
        #expect(home.baseURL.absoluteString == "http://cpa.local:8317")
        #expect(machine.secret("Home CPA") == cliManagementKey)
        #expect(machine.notifications == 1)

        let nine = await machine.motas("proxy", "add", "--kind", "9router", "--name", "Production", "--url", "https://router.example.com",
                                       "--disabled", "--secret-stdin", input: [cliTestToken])
        #expect(nine.code == 0 && nine.prompts == ["CLI token for Production: "])
        let production = try #require(machine.proxy("Production"))
        #expect(production.auth == .cliToken && !production.isEnabled)
        #expect(machine.secret("Production") == cliTestToken)

        let lab = await machine.motas("proxy", "add", "--kind", "9router", "--auth", "password", "--name", "Lab", "--url",
                                      "http://10.0.0.5:20128")
        #expect(lab.code == 0 && lab.prompts.isEmpty)
        let open = try #require(machine.proxy("Lab"))
        #expect(open.auth == .password && machine.notifications == 3)

        let table = await machine.motas("proxy", "list")
        #expect(table.code == 0)
        let lines = table.out.components(separatedBy: "\n")
        let cells = lines.map { $0.split(separator: /[ ]{2,}/).map(String.init) }
        #expect(cells == [
            ["ID", "NAME", "KIND", "AUTH", "ENABLED", "SECRET", "URL"],
            [home.id.uuidString, "Home CPA", "cliproxyapi", "management-key", "yes", "set", "http://cpa.local:8317"],
            [production.id.uuidString, "Production", "9router", "cli-token", "no", "set", "https://router.example.com"],
            [open.id.uuidString, "Lab", "9router", "password", "yes", "missing", "http://10.0.0.5:20128"],
        ])
        // Padded columns: the URL starts at the same place on every line.
        #expect(Set(zip(lines, cells).map { $0.count - ($1.last?.count ?? 0) }).count == 1)

        let json = await machine.motas("proxy", "list", "--json")
        #expect(json.code == 0)
        let rows = try #require(try JSONSerialization.jsonObject(with: Data(json.out.utf8)) as? [[String: Any]])
        #expect(rows.map { $0["id"] as? String } == [home.id.uuidString, production.id.uuidString, open.id.uuidString])
        #expect(rows.map { $0["kind"] as? String } == ["cliproxyapi", "9router", "9router"])
        #expect(rows.map { $0["auth"] as? String } == ["management-key", "cli-token", "password"])
        #expect(rows.map { $0["enabled"] as? Bool } == [true, false, true])
        #expect(rows.map { $0["secret"] as? String } == ["set", "set", "missing"])
        #expect(rows.map { $0["name"] as? String } == ["Home CPA", "Production", "Lab"])
        #expect(json.out.contains(#""url" : "http://cpa.local:8317""#))    // slashes unescaped
        #expect(machine.notifications == 3)

        let enable = await machine.motas("proxy", "enable", "PRODUCTION")
        #expect(enable.code == 0 && enable.out == "Enabled Production.")
        #expect(machine.proxy("Production")?.isEnabled == true)
        let disable = await machine.motas("proxy", "disable", home.id.uuidString.lowercased())
        #expect(disable.code == 0 && disable.out == "Disabled Home CPA.")
        #expect(machine.proxy("Home CPA")?.isEnabled == false)
        #expect(machine.notifications == 5)

        let remove = await machine.motas("proxy", "remove", "Production")
        #expect(remove.code == 0 && remove.out == "Removed Production.")
        #expect(machine.proxies.map(\.name) == ["Home CPA", "Lab"])
        #expect(machine.secrets.presence() == .known([home.id]))
        #expect(machine.notifications == 6)
        #expect(machine.http.requests.isEmpty)
    }

    @Test(arguments: [
        (cliTestToken, Int32(0), nil as String?),
        (cliSecretFile, 65, "This looks like auth/cli-secret, not the token."),
        ("not-a-token", 65, "A 9Router CLI token is 16 lowercase hex characters."),
        (cliTestToken.uppercased(), 65, "A 9Router CLI token is 16 lowercase hex characters."),
        (String(cliTestToken.dropLast()), 65, "A 9Router CLI token is 16 lowercase hex characters."),
        ("", 65, "The secret is empty."),
    ] as [(String, Int32, String?)])
    func cliTokensAreChecked(secret: String, code: Int32, problem: String?) async throws {
        let machine = CLIMachine()
        try machine.settings.save(MotasSettings(proxies: [productionConfig]))
        let run = await machine.motas("proxy", "set-secret", "Production 9Router", "--secret-stdin", input: [secret])
        #expect(run.code == code)
        #expect(run.prompts == ["CLI token for Production 9Router: "])
        if let problem {
            #expect(run.err == "\(problem) Derive the token on the server:\n  \(ProxyAuth.cliTokenRecipe)")
            #expect(machine.secrets.presence() == .known([]) && machine.notifications == 0)
        } else {
            #expect(run.out == "Stored the secret for Production 9Router." && machine.notifications == 1)
            #expect(try machine.secrets.secret(for: productionConfig.id) == cliTestToken)
        }
        if !secret.isEmpty { #expect(!machine.transcript.contains(secret)) }
    }

    @Test func aRejectedSecretChangesNothing() async {
        let machine = CLIMachine()
        let eof = await machine.motas("proxy", "add", "--kind", "9router", "--name", "P", "--url", "https://router.example.com",
                                      "--secret-stdin")
        #expect(eof.code == 65 && eof.err == "No secret on stdin.")
        let cliSecret = await machine.motas("proxy", "add", "--kind", "9router", "--name", "P", "--url", "https://router.example.com",
                                            "--secret-stdin", input: [cliSecretFile])
        #expect(cliSecret.code == 65 && cliSecret.err.hasPrefix("This looks like auth/cli-secret, not the token."))
        #expect(cliSecret.err.contains(ProxyAuth.cliTokenRecipe))
        let emptyKey = await machine.motas("proxy", "add", "--kind", "cliproxyapi", "--name", "C", "--url", "http://cpa.local:8317",
                                           "--secret-stdin", input: [""])
        #expect(emptyKey.code == 65 && emptyKey.err == "The secret is empty.")
        #expect(!FileManager.default.fileExists(atPath: machine.settings.url.path))
        #expect(machine.notifications == 0 && machine.secrets.presence() == .known([]))
    }

    @Test func setSecretReadsStdinOnlyWhenAsked() async throws {
        let machine = CLIMachine()
        try machine.settings.save(MotasSettings(proxies: [productionConfig]))
        let piped = await machine.motas("proxy", "set-secret", "Production 9Router", input: [cliTestToken])
        #expect(piped.code == 64 && piped.err == "set-secret reads the secret from stdin: pass --secret-stdin. See `motas --help`.")
        #expect(piped.prompts.isEmpty && machine.notifications == 0)

        let typed = await machine.motas("proxy", "set-secret", "Production 9Router", input: [cliTestToken], tty: true)
        #expect(typed.code == 0 && typed.prompts == ["CLI token for Production 9Router: "])
        #expect(try machine.secrets.secret(for: productionConfig.id) == cliTestToken)
        #expect(machine.notifications == 1)
    }

    @Test func namesResolveOrListTheCandidates() async throws {
        let machine = CLIMachine()
        let none = await machine.motas("proxy", "remove", "anything")
        #expect(none.code == 64 && none.err == "No proxies yet: add one with `motas proxy add`.")

        let twin = ProxyConfig(name: "Twin", kind: .nineRouter, baseURL: URL(string: "https://a.example.com")!)
        let twinToo = ProxyConfig(name: "twin", kind: .nineRouter, baseURL: URL(string: "https://b.example.com")!)
        try machine.settings.save(MotasSettings(proxies: [cpaConfig, twin, twinToo]))

        let ambiguous = await machine.motas("proxy", "disable", "TWIN")
        #expect(ambiguous.code == 64)
        #expect(ambiguous.err == """
            Several proxies have that name; use an id:
              \(twin.id.uuidString)  Twin
              \(twinToo.id.uuidString)  twin
            """)

        let unknown = await machine.motas("proxy", "test", "Nope")
        #expect(unknown.code == 64)
        #expect(unknown.err == """
            No proxy has that id or name. Proxies:
              \(cpaConfig.id.uuidString)  Testbed CPA
              \(twin.id.uuidString)  Twin
              \(twinToo.id.uuidString)  twin
            """)
        let unknownID = await machine.motas("proxy", "enable", UUID().uuidString)
        #expect(unknownID.code == 64 && unknownID.err.hasPrefix("No proxy has that id or name. Proxies:\n"))

        let byID = await machine.motas("proxy", "disable", twinToo.id.uuidString)
        #expect(byID.code == 0 && byID.out == "Disabled twin.")
        #expect(machine.proxies.map(\.isEnabled) == [true, true, false])
        #expect(machine.notifications == 1 && machine.http.requests.isEmpty)
    }

    @Test(arguments: [
        (["proxy"], "Missing command."),
        (["proxy", "rename", "x"], "Unknown command."),
        (["proxy", "list", "--verbose"], "Unknown option."),
        (["proxy", "list", "extra"], "Unexpected argument."),
        (["proxy", "enable"], "Name one proxy, by id or name."),
        (["proxy", "remove", "a", "b"], "Name one proxy, by id or name."),
        (["proxy", "set-secret", "--secret-stdin"], "Name one proxy, by id or name."),
        (["proxy", "add", "--kind", "9router", "--name", "P"], "proxy add needs --kind, --name and --url."),
        (["proxy", "add", "--kind", "9router", "--name", "P", "--url"], "--url needs a value."),
        (["proxy", "add", "--kind", "squid", "--name", "P", "--url", "https://p.example.com"], "--kind is 9router or cliproxyapi."),
        (["proxy", "add", "--kind", "9router", "--auth", "token", "--name", "P", "--url", "https://p.example.com"],
         "--auth is cli-token, password or management-key."),
        (["proxy", "add", "--kind", "cliproxyapi", "--auth", "password", "--name", "P", "--url", "https://p.example.com"],
         "9router signs in with cli-token or password, cliproxyapi with management-key."),
        (["proxy", "add", "--kind", "9router", "--auth", "management-key", "--name", "P", "--url", "https://p.example.com"],
         "9router signs in with cli-token or password, cliproxyapi with management-key."),
    ])
    func usageErrorsExit64(args: [String], message: String) async {
        let machine = CLIMachine()
        let run = await machine.motas(args)
        #expect(run.code == 64 && run.err == "\(message) See `motas --help`.")
        #expect(run.out.isEmpty && run.prompts.isEmpty)
        #expect(machine.proxies.isEmpty && machine.notifications == 0)
    }

    @Test(arguments: ["ftp://p.example.com", "p.example.com", "https://", "https://user:pw@p.example.com", "https://p.example.com/?key=1",
                      "https://p.example.com/#top"])
    func badURLsExit65(url: String) async {
        let machine = CLIMachine()
        let run = await machine.motas("proxy", "add", "--kind", "9router", "--name", "P", "--url", url)
        #expect(run.code == 65 && run.err == "The URL must be http or https with a host, and no credentials, query or fragment.")
        #expect(machine.proxies.isEmpty && machine.notifications == 0)
    }

    @Test func anEmptyNameExits65() async {
        let machine = CLIMachine()
        let run = await machine.motas("proxy", "add", "--kind", "9router", "--name", "  ", "--url", "https://p.example.com")
        #expect(run.code == 65 && run.err == "The name is empty.")
        #expect(machine.proxies.isEmpty)
    }

    @Test func plainHTTPCarriesASecretOnlyToAPrivateHost() async throws {
        let machine = CLIMachine()
        let token = await machine.motas("proxy", "add", "--kind", "9router", "--name", "P", "--url", "http://router.example.com")
        #expect(token.code == 65 && token.err == "Refusing to send the secret over plain HTTP to router.example.com.")
        let key = await machine.motas("proxy", "add", "--kind", "cliproxyapi", "--name", "C", "--url", "http://cpa.example.com:8317",
                                      "--secret-stdin", input: [cliManagementKey])
        #expect(key.code == 65 && key.err == "Refusing to send the secret over plain HTTP to cpa.example.com.")
        #expect(machine.proxies.isEmpty && machine.notifications == 0)

        // A 9Router without a login: nothing to send, until a password is set.
        let open = await machine.motas("proxy", "add", "--kind", "9router", "--auth", "password", "--name", "Open", "--url",
                                       "http://router.example.com:20128")
        #expect(open.code == 0)
        let password = await machine.motas("proxy", "set-secret", "Open", "--secret-stdin", input: [cliPassword])
        #expect(password.code == 65 && password.err == "Refusing to send the secret over plain HTTP to router.example.com.")
        #expect(machine.secrets.presence() == .known([]))

        let lab = await machine.motas("proxy", "add", "--kind", "9router", "--name", "Lab", "--url", "http://192.168.1.20:20128",
                                      "--secret-stdin", input: [cliTestToken])
        #expect(lab.code == 0 && machine.secret("Lab") == cliTestToken)
        #expect(machine.notifications == 2)
    }

    @Test func aLockedKeychainExits75AndChangesNothing() async throws {
        let machine = CLIMachine(secrets: InMemorySecretStore([productionConfig.id: cliTestToken], needingApproval: true))
        try machine.settings.save(MotasSettings(proxies: [productionConfig]))
        let before = try Data(contentsOf: machine.settings.url)
        let approval = "Keychain needs approval for this Motas build: open Motas → Allow…, or rerun with --allow-keychain-prompt"

        let setSecret = await machine.motas("proxy", "set-secret", "Production 9Router", "--secret-stdin", input: [cliOtherToken])
        let add = await machine.motas("proxy", "add", "--kind", "9router", "--name", "Second", "--url", "https://second.example.com",
                                      "--secret-stdin", input: [cliOtherToken])
        let remove = await machine.motas("proxy", "remove", "Production 9Router")
        let test = await machine.motas("proxy", "test", "Production 9Router")
        for run in [setSecret, add, remove, test] {
            #expect(run.code == 75 && run.err == approval && run.out.isEmpty)
        }
        #expect(try Data(contentsOf: machine.settings.url) == before)
        #expect(machine.notifications == 0 && machine.http.requests.isEmpty)

        let list = await machine.motas("proxy", "list", "--json")
        #expect(list.code == 0 && list.out.contains(#""secret" : "locked""#))
        let disable = await machine.motas("proxy", "disable", "Production 9Router")    // no secret involved
        #expect(disable.code == 0 && machine.notifications == 1)

        let allowed = await machine.motas("proxy", "set-secret", "Production 9Router", "--secret-stdin", "--allow-keychain-prompt",
                                          input: [cliOtherToken])
        #expect(allowed.code == 0 && machine.notifications == 2)
        #expect(try machine.secrets.secret(for: productionConfig.id) == cliOtherToken)
    }

    @Test func allowingThePromptApprovesFirst() async throws {
        let machine = CLIMachine(secrets: InMemorySecretStore([productionConfig.id: cliTestToken], needingApproval: true),
                                 http: nineProduction(tokens: [cliTestToken]))
        try machine.settings.save(MotasSettings(proxies: [productionConfig]))
        let list = await machine.motas("proxy", "list", "--allow-keychain-prompt")
        #expect(list.code == 0 && list.out.contains("  set  "))
        machine.secrets.needingApproval = true
        let test = await machine.motas("proxy", "test", "Production 9Router", "--allow-keychain-prompt")
        #expect(test.code == 0 && test.out.hasPrefix("29 connections"))
    }

    @Test func testListsTheAccountsOnly() async throws {
        let machine = CLIMachine(http: nineProduction(tokens: [cliTestToken]))
        try machine.settings.save(MotasSettings(proxies: [productionConfig]))
        try await machine.secrets.setSecret(cliTestToken, for: productionConfig.id)
        let run = await machine.motas("proxy", "test", "production 9router")
        #expect(run.code == 0 && run.err.isEmpty)
        #expect(run.out == "29 connections (26 active): Codex 11, Qoder 10, Antigravity 2, OpenRouter 2, xAI 2, Chutes 1, quotax-oss 1")
        #expect(machine.http.requests.map(\.path) == ["/api/providers"])
        #expect(machine.http.requests.first?.value(forHTTPHeaderField: "x-9r-cli-token") == cliTestToken)
        #expect(machine.notifications == 0)
    }

    @Test func testExitCodes() async throws {
        for (error, message) in [(URLError(.cannotConnectToHost), "Cannot reach the proxy: Connection refused."),
                                 (URLError(.notConnectedToInternet), "Offline: Network unavailable.")] {
            let machine = CLIMachine(secrets: InMemorySecretStore([productionConfig.id: cliTestToken]), http: StubHTTP { _ in throw error })
            try machine.settings.save(MotasSettings(proxies: [productionConfig]))
            let run = await machine.motas("proxy", "test", "Production 9Router")
            #expect(run.code == 69 && run.err == message && run.out.isEmpty)
        }

        let rejected = CLIMachine(secrets: InMemorySecretStore([productionConfig.id: cliOtherToken]), http: nineProduction(tokens: [cliTestToken]))
        try rejected.settings.save(MotasSettings(proxies: [productionConfig]))
        let run = await rejected.motas("proxy", "test", "Production 9Router")
        #expect(run.code == 1 && run.err == tokenRejected.summary)

        let missing = CLIMachine(http: nineProduction(tokens: [cliTestToken]))
        try missing.settings.save(MotasSettings(proxies: [productionConfig]))
        let noSecret = await missing.motas("proxy", "test", "Production 9Router")
        #expect(noSecret.code == 1 && noSecret.err == ProxyAccessError.missingCredential.summary)
    }

    @Test func aCorruptSettingsFileIsNeverOverwritten() async throws {
        let machine = CLIMachine()
        let corrupt = Data(#"{"proxies": ["#.utf8)
        try FileManager.default.createDirectory(at: machine.settings.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try corrupt.write(to: machine.settings.url)

        let list = await machine.motas("proxy", "list")
        #expect(list.code == 1 && list.err.hasPrefix("settings.json is unreadable: "))
        let add = await machine.motas("proxy", "add", "--kind", "cliproxyapi", "--name", "C", "--url", "http://cpa.local:8317")
        #expect(add.code == 1 && add.err.hasPrefix("Could not update settings.json: "))
        let enable = await machine.motas("proxy", "enable", "C")
        #expect(enable.code == 1 && enable.err.hasPrefix("settings.json is unreadable: "))
        #expect(try Data(contentsOf: machine.settings.url) == corrupt)
        #expect(machine.notifications == 0)
    }

    @Test func noPieceOfASecretIsEverPrinted() async throws {
        let machine = CLIMachine(http: nineProduction(tokens: [cliTestToken]))
        let add = [
            ["--kind", "9router", "--name", "Production", "--url", "https://router.example.com", "--secret-stdin"],
            ["--kind", "cliproxyapi", "--name", "CPA", "--url", "http://cpa.local:8317", "--secret-stdin"],
            ["--kind", "9router", "--auth", "password", "--name", "Dash", "--url", "https://dash.example.com", "--secret-stdin"],
        ]
        for (args, secret) in zip(add, [cliTestToken, cliManagementKey, cliPassword]) {
            #expect(await machine.motas(["proxy", "add"] + args, input: [secret]).code == 0)
        }
        #expect(await machine.motas("proxy", "set-secret", "Production", "--secret-stdin", input: [cliSecretFile]).code == 65)
        #expect(await machine.motas("proxy", "set-secret", "CPA", "--secret-stdin", input: [cliManagementKey]).code == 0)
        #expect(await machine.motas("proxy", "list").code == 0)
        #expect(await machine.motas("proxy", "list", "--json").code == 0)
        #expect(await machine.motas("proxy", "test", "Production").code == 0)
        // Secrets mistakenly passed as arguments are never echoed.
        #expect(await machine.motas("proxy", "set-secret", "Production", cliOtherToken).code == 64)
        #expect(await machine.motas("proxy", "add", "--kind", "9router", "--name", "X", "--url", "https://x.example.com", "--token",
                                    cliOtherToken).code == 64)
        #expect(await machine.motas("proxy", "add", "--kind", "cliproxyapi", "--name", "X", "--url", "https://x.example.com",
                                    "--secret=\(cliManagementKey)").code == 64)
        #expect(await machine.motas("proxy", "list", cliPassword).code == 64)
        #expect(await machine.motas("proxy", "remove", cliSecretFile).code == 64)

        let transcript = machine.transcript
        let leaked = [cliTestToken, cliOtherToken, cliSecretFile, cliManagementKey, cliPassword]
            .flatMap(fragments(of:)).filter { transcript.contains($0) }
        #expect(leaked.isEmpty)
        #expect(machine.secret("Production") == cliTestToken && machine.secret("CPA") == cliManagementKey)
    }
}
