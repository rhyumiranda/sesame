import ArgumentParser
import Foundation
import SesameCore

// MARK: - Shared wiring
//
// The CLI is a THIN CLIENT (Stage B). It resolves — per config — how to reach
// the store:
//   • data_source = agent (default) + an agent is listening → route every op
//     through the signed agent over its socket. The agent owns the Secure-
//     Enclave key and raises Touch ID, so the CLI uses a NullAuthenticator (no
//     second, redundant prompt) and AgentBackedStore.
//   • data_source = agent + agent DOWN → FAIL SAFE to the advisory local path
//     (login Keychain "dev.sesame" + the real LAContext gate) = Stage-A behavior.
//   • data_source = local → the config-selected local store directly.
//
// Tests bypass these wrappers and exercise the core types with fakes.

private let kService = "dev.sesame"

// Single source of truth for the CLI version. release-please bumps the literal on
// the marker line at each release — keep the `x-release-please-version` marker
// comment on the SAME line as the version number, or the generic updater skips it.
let sesameVersion = "0.5.1" // x-release-please-version

func makeLog() -> AccessLog { AccessLog() }

/// The advisory login-Keychain store the CLI can always reach on its own — the
/// Stage-A store and the fail-safe fallback.
func advisoryStore() -> KeychainStore { KeychainStore(service: kService) }

/// Resolved store + gate for one command invocation.
struct Wiring {
    let store: StorageBackend
    let auth: Authenticator
    /// True when routed through the agent (the agent, not the CLI, prompts).
    let routedToAgent: Bool
}

/// Resolve the store/gate from config, applying the agent-down fail-safe.
func resolveWiring(config: Config = .load()) -> Wiring {
    if config.dataSource == .agent {
        let client = AgentClient(socketPath: config.agentSocket)
        if client.isAvailable() {
            return Wiring(store: AgentBackedStore(client: client, requester: Requester.parentName()),
                          auth: NullAuthenticator(),
                          routedToAgent: true)
        }
        // Agent not listening → fail safe to the advisory local path (Stage A).
        return Wiring(store: advisoryStore(), auth: LAAuthenticator(), routedToAgent: false)
    }
    // Explicit local: honor the configured backend directly.
    return Wiring(store: StoreFactory.local(config), auth: LAAuthenticator(), routedToAgent: false)
}

struct CommonFlags: ParsableArguments {
    @Flag(name: .customLong("json"),
          help: "Machine-readable JSON output (never includes secret values).")
    var json = false
}

// MARK: - TOON rendering helpers

private func toonRows(_ header: String, fields: [String], rows: [[String]]) -> String {
    var lines = ["\(header)[\(rows.count)]{\(fields.joined(separator: ","))}:"]
    for row in rows {
        lines.append("  " + row.joined(separator: "  "))
    }
    return lines.joined(separator: "\n")
}

private func orNull(_ s: String?) -> String { s ?? "null" }

// MARK: - Root / dashboard

struct Sesame: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sesame",
        abstract: "Open sesame — a fingerprint-gated vault for your agent's env secrets.",
        discussion: """
        The CLI is a thin client. By default (data_source=agent) it routes get/run \
        through the signed Sesame agent, which owns the Secure-Enclave key and \
        raises Touch ID. When no agent is running it FAILS SAFE to the advisory \
        local path (Stage-A login-Keychain + a CLI-layer LAContext gate — NOT a \
        cryptographic binding). Set storage_backend=secure-enclave (with the agent \
        running) for the hardware-bound gate. See the README's security note.
        """,
        version: "sesame \(sesameVersion)",
        subcommands: [Add.self, Get.self, Run.self, Exec.self, List.self, Remove.self, Log.self,
                      Migrate.self, Export.self, Import.self,
                      Setup.self, Init.self, Shim.self, ShimExec.self]
    )

    @Flag(name: .customShort("v"), help: "Print the version.")
    var showVersion = false

    @OptionGroup var common: CommonFlags

    func run() throws {
        if showVersion {
            Out.line("sesame \(sesameVersion)")
            return
        }
        let store = resolveWiring().store
        let infos: [SecretInfo]
        do {
            infos = try store.list()
        } catch let error as SesameError {
            Out.failAndExit(error, json: common.json)
        }

        // Recent-first by lastUsedAt (nulls last), minimal fields.
        let recent = infos.sorted { a, b in
            switch (a.lastUsedAt, b.lastUsedAt) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.name < b.name
            }
        }

        if common.json {
            let secrets = recent.map { info -> [String: Any] in
                ["name": info.name,
                 "lastUsedAt": info.lastUsedAt as Any? ?? NSNull(),
                 "lastUsedBy": info.lastUsedBy as Any? ?? NSNull()]
            }
            Out.line(Out.json(["secrets": secrets, "total": infos.count]))
            return
        }

        Out.line(Banner.text)
        Out.line("")
        if recent.isEmpty {
            Out.line("secrets[0]: (none added yet)")
        } else {
            let rows = recent.prefix(10).map { [$0.name, orNull($0.lastUsedAt), orNull($0.lastUsedBy)] }
            Out.line(toonRows("secrets", fields: ["name", "lastUsedAt", "lastUsedBy"], rows: Array(rows)))
        }
        Out.line("summary: total: \(infos.count)")
        Out.line("help[3]: 'sesame add <NAME>' to store · 'sesame run <NAME> -- <cmd>' to use · 'sesame ls' for all")
    }
}

// MARK: - add

struct Add: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Store a secret; the value is read from STDIN (never argv, so it can't leak via ps)."
    )

    @Argument(help: "The secret's name (env-var shaped).")
    var name: String

    @OptionGroup var common: CommonFlags

    func run() throws {
        do {
            try Name.validate(name)
        } catch let error as SesameError {
            Out.failAndExit(error, json: common.json)
        }

        var data = FileHandle.standardInput.readDataToEndOfFile()
        // Strip a single trailing newline (so `echo secret | sesame add X` is clean).
        if data.last == 0x0A {
            data.removeLast()
            if data.last == 0x0D { data.removeLast() }
        }
        if data.isEmpty {
            Out.failAndExit(.io("empty value on stdin — nothing to store"), json: common.json)
        }

        let store = resolveWiring().store
        let log = makeLog()
        let requester = Requester.parentName()

        let added: Bool
        do {
            added = try store.add(name: name, value: data)
        } catch let error as SesameError {
            log.append(LogEntry(ts: Time.iso(), op: "add", name: name, requester: requester, result: error.logResult))
            Out.failAndExit(error, json: common.json)
        }

        log.append(LogEntry(ts: Time.iso(), op: "add", name: name, requester: requester, result: "ok"))
        let createdAt = Time.iso()

        if common.json {
            Out.line(Out.json(["ok": true, "action": "add", "name": name,
                               "createdAt": createdAt, "already": !added]))
        } else if added {
            Out.line("ok: added \(name)")
            Out.line("help[1]: 'sesame run \(name) -- <cmd>' to use it")
        } else {
            Out.line("already: true")
            Out.line("help[1]: 'sesame run \(name) -- <cmd>' to use it")
        }
    }
}

// MARK: - get

struct Get: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Release a secret behind Touch ID — the bare value on STDOUT, metadata on STDERR."
    )

    @Argument(help: "The secret's name.")
    var name: String

    @OptionGroup var common: CommonFlags

    func run() throws {
        do {
            try Name.validate(name)
        } catch let error as SesameError {
            Out.failAndExit(error, json: common.json)
        }

        let wiring = resolveWiring()
        let store = wiring.store
        let log = makeLog()
        let auth = wiring.auth
        let limiter = RateLimiter()
        let requester = Requester.parentName()

        // Exist check first, so a missing secret is exit 2 (not a wasted prompt).
        do {
            guard try store.exists(name) else { throw SesameError.notFound(name) }
        } catch let error as SesameError {
            log.append(LogEntry(ts: Time.iso(), op: "get", name: name, requester: requester, result: error.logResult))
            Out.failAndExit(error, json: common.json)
        }

        if let wait = limiter.check(name: name) {
            let error = SesameError.rateLimited(name: name, secondsLeft: wait)
            log.append(LogEntry(ts: Time.iso(), op: "get", name: name, requester: requester, result: "ratelimited"))
            Out.failAndExit(error, json: common.json)
        }

        do {
            try auth.authenticate(reason: "release \(name)")
        } catch let error as SesameError {
            log.append(LogEntry(ts: Time.iso(), op: "get", name: name, requester: requester, result: "denied"))
            if common.json {
                Out.line(Out.json(["ok": false, "approved": false, "name": name, "error": "denied"]))
                Foundation.exit(error.exitCode)
            }
            Out.failAndExit(error, json: false)
        }

        let value: Data
        do {
            value = try store.copyValue(name: name)
        } catch let error as SesameError {
            log.append(LogEntry(ts: Time.iso(), op: "get", name: name, requester: requester, result: error.logResult))
            Out.failAndExit(error, json: common.json)
        }

        store.recordUse(name: name, by: requester)
        log.append(LogEntry(ts: Time.iso(), op: "get", name: name, requester: requester, result: "ok"))

        if common.json {
            // Metadata only — value is deliberately omitted.
            Out.line(Out.json(["ok": true, "approved": true, "name": name]))
        } else {
            Out.err("ok: released \(name)")
            Out.bareValue(String(data: value, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - run

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Approve secrets (one Touch ID prompt each) and inject them into a command's env.",
        discussion: "Usage: sesame run NAME [NAME…] -- <command> [args…]"
    )

    // Capture everything after the flags as raw tokens (this keeps the `--`
    // terminator), then split on `--` ourselves: names before, command after.
    @Argument(parsing: .captureForPassthrough,
              help: "NAME [NAME…] -- <command> [args…]")
    var tokens: [String] = []

    @OptionGroup var common: CommonFlags

    func run() throws {
        guard let sep = tokens.firstIndex(of: "--") else {
            Out.failAndExit(.io("missing '--' separator — usage: sesame run NAME -- <cmd>"), json: common.json)
        }
        let names = Array(tokens[..<sep])
        let command = Array(tokens[(sep + 1)...])

        guard !names.isEmpty else {
            Out.failAndExit(.io("no secrets named — usage: sesame run NAME -- <cmd>"), json: common.json)
        }
        guard !command.isEmpty else {
            Out.failAndExit(.io("no command after -- — usage: sesame run NAME -- <cmd>"), json: common.json)
        }

        let wiring = resolveWiring()
        let log = makeLog()
        let requester = Requester.parentName()

        var injected: [String: String] = [:]
        do {
            injected = try Resolve.secrets(names: names, store: wiring.store, auth: wiring.auth,
                                           limiter: RateLimiter(), log: log, requester: requester,
                                           op: "run", skipIfPresent: false, env: [:])
        } catch let error as SesameError {
            Out.failAndExit(error, json: common.json)
        }

        // JSON mode must report the child's exitCode → spawn + wait.
        if common.json {
            do {
                let code = try Runner.spawnWait(command: command, secrets: injected)
                Out.err(Out.json(["ok": true, "injected": names, "exitCode": Int(code)]))
                Foundation.exit(code)
            } catch let error as SesameError {
                Out.failAndExit(error, json: true)
            }
        }

        // Default: announce, then replace our process image with the command
        // (truest stdout/exit passthrough).
        Out.err("ok: injected \(names.joined(separator: " "))")
        do {
            try Runner.exec(command: command, secrets: injected)
        } catch let error as SesameError {
            Out.failAndExit(error, json: false)
        }
    }
}

// MARK: - ls

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List stored secrets (names + metadata, never values)."
    )

    @Flag(name: .customLong("full"), help: "Show all fields (untruncated).")
    var full = false

    @OptionGroup var common: CommonFlags

    func run() throws {
        let store = resolveWiring().store
        let infos: [SecretInfo]
        do {
            infos = try store.list()
        } catch let error as SesameError {
            Out.failAndExit(error, json: common.json)
        }

        if common.json {
            let secrets = infos.map { info -> [String: Any] in
                ["name": info.name,
                 "createdAt": info.createdAt,
                 "lastUsedAt": info.lastUsedAt as Any? ?? NSNull(),
                 "lastUsedBy": info.lastUsedBy as Any? ?? NSNull()]
            }
            Out.line(Out.json(["secrets": secrets, "total": infos.count]))
            return
        }

        if infos.isEmpty {
            Out.line("secrets[0]: (none added yet)")
        } else {
            let rows = infos.map { [$0.name, $0.createdAt, orNull($0.lastUsedAt), orNull($0.lastUsedBy)] }
            Out.line(toonRows("secrets",
                              fields: ["name", "createdAt", "lastUsedAt", "lastUsedBy"],
                              rows: rows))
        }
        Out.line("summary: total: \(infos.count)")
        Out.line("help[2]: 'sesame add <NAME>' to store one · 'sesame run <NAME> -- <cmd>' to use one")
    }
}

// MARK: - rm

struct Remove: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete a secret (permanent) — requires --confirm/--force."
    )

    @Argument(help: "The secret's name.")
    var name: String

    @Flag(name: .customLong("confirm"), help: "Confirm the permanent deletion.")
    var confirm = false

    @Flag(name: .customLong("force"), help: "Alias for --confirm.")
    var force = false

    @Flag(name: .customLong("advisory"),
          help: "Delete from the ADVISORY login-Keychain store directly (drop a Stage-A copy after 'sesame migrate').")
    var advisory = false

    @OptionGroup var common: CommonFlags

    func run() throws {
        do {
            try Name.validate(name)
        } catch let error as SesameError {
            Out.failAndExit(error, json: common.json)
        }

        guard confirm || force else {
            Out.failAndExit(.missingConfirm, json: common.json)
        }

        // --advisory always targets the login-Keychain store directly (never the
        // agent), so a verified migration can drop the old advisory copies.
        let store: StorageBackend = advisory ? advisoryStore() : resolveWiring().store
        let log = makeLog()
        let requester = Requester.parentName()

        do {
            try store.delete(name: name)
        } catch let error as SesameError {
            log.append(LogEntry(ts: Time.iso(), op: "rm", name: name, requester: requester, result: error.logResult))
            Out.failAndExit(error, json: common.json)
        }

        log.append(LogEntry(ts: Time.iso(), op: "rm", name: name, requester: requester, result: "ok"))
        if common.json {
            Out.line(Out.json(["ok": true, "action": "rm", "name": name]))
        } else {
            Out.line("ok: deleted \(name)")
        }
    }
}

// MARK: - log

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Show the access log (newest-first) — requests + approvals/denials, never values."
    )

    @Option(name: .customLong("limit"), help: "Max entries to show (default 50).")
    var limit: Int = 50

    @Option(name: .customLong("since"), help: "Only entries at/after this ISO8601 timestamp.")
    var since: String?

    @Flag(name: .customLong("full"), help: "Show all entries (no truncation).")
    var full = false

    @OptionGroup var common: CommonFlags

    func run() throws {
        let log = makeLog()
        var entries = log.read()

        if let since = since {
            entries = entries.filter { ($0["ts"] as? String).map { $0 >= since } ?? false }
        }

        let total = entries.count
        let shown: [[String: Any]]
        var truncated = false
        if full {
            shown = entries
        } else if entries.count > limit {
            shown = Array(entries.prefix(limit))
            truncated = true
        } else {
            shown = entries
        }

        if common.json {
            Out.line(Out.json(["log": shown, "total": total]))
            return
        }

        if shown.isEmpty {
            Out.line("log[0]: (no requests yet)")
            Out.line("help[2]: run a 'sesame get'/'run' to generate entries · '--json' for machine output")
            return
        }

        let rows = shown.map { entry -> [String] in
            [orNull(entry["ts"] as? String),
             orNull(entry["op"] as? String),
             orNull(entry["name"] as? String),
             orNull(entry["requester"] as? String),
             orNull(entry["result"] as? String)]
        }
        Out.line(toonRows("log",
                          fields: ["timestamp", "operation", "name", "requester", "result"],
                          rows: rows))
        if truncated {
            Out.line("summary: showing \(shown.count) of \(total) — '--full' for all")
        } else {
            Out.line("summary: total: \(total)")
        }
        Out.line("help[2]: '--since <ISO>' to filter · '--json' for machine output")
    }
}

// MARK: - migrate

struct Migrate: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "migrate",
        abstract: "Re-wrap advisory (Stage-A login-Keychain) secrets into the Secure-Enclave vault.",
        discussion: """
        Reads each advisory secret behind Touch ID and re-encrypts it into the SE \
        store via the agent. The advisory copies are LEFT INTACT; after verifying, \
        drop them with 'sesame rm <NAME> --advisory'. Requires the signed Sesame \
        agent to be running (only it owns the Secure-Enclave key).
        """
    )

    @OptionGroup var common: CommonFlags

    func run() throws {
        let wiring = resolveWiring()
        guard wiring.routedToAgent else {
            Out.failAndExit(.agentUnavailable("migrate needs the signed Sesame agent running (start Sesame.app; set storage_backend=secure-enclave)"),
                            json: common.json)
        }
        // Source = advisory login-Keychain; dest = the SE store via the agent.
        let report = Recovery.migrate(from: advisoryStore(), to: wiring.store,
                                      auth: LAAuthenticator(), log: makeLog())
        if common.json {
            Out.line(Out.json(["ok": report.failed.isEmpty,
                               "migrated": report.moved,
                               "skipped": report.skipped,
                               "failed": report.failed.map { ["name": $0.name, "error": $0.error] }]))
        } else {
            Out.line("migrated[\(report.moved.count)]: \(report.moved.joined(separator: " "))")
            if !report.skipped.isEmpty {
                Out.line("skipped[\(report.skipped.count)]: \(report.skipped.joined(separator: " ")) (already in SE vault)")
            }
            for f in report.failed {
                Out.err("failed: \(f.name) — \(f.error) (advisory copy left intact)")
            }
            Out.line("help[1]: verify with 'sesame get <NAME>', then 'sesame rm <NAME> --advisory --confirm' to drop old copies")
        }
        if !report.failed.isEmpty { Foundation.exit(1) }
    }
}

// MARK: - export

struct Export: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Dump every secret as NAME=value (a Touch-ID-gated backup YOU control).",
        discussion: """
        SE-backed secrets live only on this Mac and cannot be re-derived after a \
        device loss/reset. Run this to produce a backup you store yourself, then \
        restore with 'sesame import'. Each secret is released behind Touch ID; the \
        values print to STDOUT (redirect to a file you protect).
        """
    )

    @OptionGroup var common: CommonFlags

    func run() throws {
        let wiring = resolveWiring()
        let pairs: [(name: String, value: String)]
        do {
            pairs = try Recovery.export(from: wiring.store, auth: wiring.auth)
        } catch let error as SesameError {
            Out.failAndExit(error, json: common.json)
        }
        Out.err("ok: exported \(pairs.count) secret(s) — store this backup securely; anyone with it has your secrets")
        for (name, value) in pairs {
            Out.line("\(name)=\(value)")
        }
    }
}

// MARK: - import

struct Import: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Restore NAME=value lines from STDIN (a prior 'sesame export') into the vault.",
        discussion: "Idempotent: an existing name is skipped, never overwritten. Reads from STDIN."
    )

    @OptionGroup var common: CommonFlags

    func run() throws {
        let text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pairs: [(name: String, value: String)]
        do {
            pairs = try Recovery.parseEnv(text)
        } catch let error as SesameError {
            Out.failAndExit(error, json: common.json)
        }
        guard !pairs.isEmpty else {
            Out.failAndExit(.io("no NAME=value lines on stdin — nothing to import"), json: common.json)
        }
        let report = Recovery.importSecrets(pairs, into: resolveWiring().store, log: makeLog())
        if common.json {
            Out.line(Out.json(["ok": report.failed.isEmpty,
                               "imported": report.moved,
                               "skipped": report.skipped,
                               "failed": report.failed.map { ["name": $0.name, "error": $0.error] }]))
        } else {
            Out.line("imported[\(report.moved.count)]: \(report.moved.joined(separator: " "))")
            if !report.skipped.isEmpty {
                Out.line("skipped[\(report.skipped.count)]: \(report.skipped.joined(separator: " ")) (already present)")
            }
            for f in report.failed { Out.err("failed: \(f.name) — \(f.error)") }
        }
        if !report.failed.isEmpty { Foundation.exit(1) }
    }
}

Sesame.main()
