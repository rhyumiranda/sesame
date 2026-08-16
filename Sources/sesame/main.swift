import ArgumentParser
import Foundation
import SesameCore

// MARK: - Shared wiring
//
// Real commands use the login Keychain (service "dev.sesame"), the real Touch
// ID gate, and the default access log. Tests bypass these command wrappers and
// exercise the core types (KeychainStore, Runner, RateLimiter, AccessLog)
// directly with fakes — see Tests/sesameTests.

private let kService = "dev.sesame"

private func makeStore() -> KeychainStore { KeychainStore(service: kService) }
private func makeAuth() -> Authenticator { LAAuthenticator() }
private func makeLog() -> AccessLog { AccessLog() }

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
        Free MVP (Milestone 1): the Touch ID gate is CLI-layer / ADVISORY \
        (LAContext) — it is NOT cryptographically enforced by the login \
        Keychain. Any same-user process can read the stored item directly. \
        Milestone 2 (Secure Enclave in a signed daemon) hardens it. See the \
        README's security note.
        """,
        version: "sesame 0.1.0 (Free MVP)",
        subcommands: [Add.self, Get.self, Run.self, List.self, Remove.self, Log.self]
    )

    @Flag(name: .customShort("v"), help: "Print the version.")
    var showVersion = false

    @OptionGroup var common: CommonFlags

    func run() throws {
        if showVersion {
            Out.line("sesame 0.1.0 (Free MVP)")
            return
        }
        let store = makeStore()
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

        let store = makeStore()
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

        let store = makeStore()
        let log = makeLog()
        let auth = makeAuth()
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

        let store = makeStore()
        let log = makeLog()
        let auth = makeAuth()
        let limiter = RateLimiter()
        let requester = Requester.parentName()

        var injected: [String: String] = [:]
        for name in names {
            do {
                try Name.validate(name)
                guard try store.exists(name) else { throw SesameError.notFound(name) }
                if let wait = limiter.check(name: name) {
                    throw SesameError.rateLimited(name: name, secondsLeft: wait)
                }
                try auth.authenticate(reason: "release \(name)")
                let value = try store.copyValue(name: name)
                injected[name] = String(data: value, encoding: .utf8) ?? ""
                store.recordUse(name: name, by: requester)
                log.append(LogEntry(ts: Time.iso(), op: "run", name: name, requester: requester, result: "ok"))
            } catch let error as SesameError {
                log.append(LogEntry(ts: Time.iso(), op: "run", name: name, requester: requester, result: error.logResult))
                Out.failAndExit(error, json: common.json)
            }
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
        let store = makeStore()
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

        let store = makeStore()
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

Sesame.main()
