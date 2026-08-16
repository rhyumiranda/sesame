import ArgumentParser
import Foundation
import SesameCore

// MARK: - Agent env integration
//
// Three layers on top of the base CLI so an AI agent can source env secrets from
// Sesame without knowing Sesame exists:
//   • `.sesame` project manifest (names + optional command→secrets map) — SesameCore.
//   • `sesame exec -- <cmd>`  — batch-load ALL the manifest's secrets, then run.
//   • `sesame shim install`   — PATH-directory wrapper scripts that inject only
//     the secret(s) a specific command needs, on demand, behind Touch ID.
// Secrets go to the child's ENVIRONMENT only (execve) — never disk/argv/log-value.

/// Absolute path to THIS `sesame` binary, baked into generated shims so they
/// call the real tool regardless of the caller's PATH.
private func currentSesamePath() -> String {
    if let p = Bundle.main.executablePath { return p }
    let argv0 = CommandLine.arguments.first ?? "sesame"
    if argv0.hasPrefix("/") { return argv0 }
    return argv0
}

/// Run `command` (env-only injection) — replacing our image, or via spawn+wait
/// for `--json` so the child's exit code can be reported.
private func runOrExec(command: [String], injected: [String: String],
                       injectedNames: [String], json: Bool) -> Never {
    if json {
        do {
            let code = try Runner.spawnWait(command: command, secrets: injected)
            Out.err(Out.json(["ok": true, "injected": injectedNames, "exitCode": Int(code)]))
            Foundation.exit(code)
        } catch let error as SesameError {
            Out.failAndExit(error, json: true)
        } catch {
            Out.failAndExit(.io(error.localizedDescription), json: true)
        }
    }
    if !injectedNames.isEmpty {
        Out.err("ok: injected \(injectedNames.joined(separator: " "))")
    }
    do {
        try Runner.exec(command: command, secrets: injected)
    } catch let error as SesameError {
        Out.failAndExit(error, json: false)
    } catch {
        Out.failAndExit(.io(error.localizedDescription), json: false)
    }
}

// MARK: - exec

struct Exec: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Batch-load the project's .sesame secrets (Touch ID) into a command's env, then run it.",
        discussion: """
        Reads the nearest .sesame, resolves ALL its declared secrets from Sesame \
        (one launch-time step), injects them via execve, and runs <command>. Use \
        this to launch an agent/shell once with the project's secrets already \
        present — every command it then spawns inherits them (the "quiet" mode). \
        Usage: sesame exec -- <command> [args…]
        """
    )

    @Argument(parsing: .captureForPassthrough, help: "-- <command> [args…]")
    var tokens: [String] = []

    @OptionGroup var common: CommonFlags

    func run() throws {
        let command: [String]
        if let sep = tokens.firstIndex(of: "--") {
            command = Array(tokens[(sep + 1)...])
        } else {
            command = tokens
        }
        guard !command.isEmpty else {
            Out.failAndExit(.io("no command to run — usage: sesame exec -- <cmd>"), json: common.json)
        }

        let manifest: Manifest
        do {
            manifest = try Manifest.load()
        } catch let error as ManifestError {
            Out.failAndExit(message: error.message, code: error.exitCode, json: common.json)
        }

        let names = manifest.secrets
        let wiring = resolveWiring()
        let log = makeLog()
        let requester = Requester.parentName()

        if names.isEmpty {
            // Nothing declared → just run the command unchanged.
            runOrExec(command: command, injected: [:], injectedNames: [], json: common.json)
        }

        // Presence check first, so a bad name is a clean error (not a wasted prompt).
        let stored = (try? wiring.store.list())?.map { $0.name } ?? []
        let missing = names.filter { !stored.contains($0) }
        if !missing.isEmpty {
            Out.failAndExit(message: ManifestError.unknownSecrets(missing: missing, stored: stored).message,
                            code: 2, json: common.json)
        }

        let injected: [String: String]
        do {
            injected = try Resolve.secrets(names: names, store: wiring.store, auth: wiring.auth,
                                           limiter: RateLimiter(), log: log, requester: requester,
                                           op: "run", skipIfPresent: false, env: [:])
        } catch let error as SesameError {
            Out.failAndExit(error, json: common.json)
        }

        runOrExec(command: command, injected: injected, injectedNames: names, json: common.json)
    }
}

// MARK: - init

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Scaffold a .sesame manifest in the current directory (names only; safe to commit)."
    )

    @OptionGroup var common: CommonFlags

    func run() throws {
        let url = Manifest.cwd().appendingPathComponent(".sesame")
        if FileManager.default.fileExists(atPath: url.path) {
            if common.json {
                Out.line(Out.json(["ok": true, "action": "init", "created": false, "path": url.path]))
            } else {
                Out.line("already: \(url.path) exists — left unchanged")
            }
            return
        }
        do {
            try Manifest.template.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Out.failAndExit(.io("could not write \(url.path): \(error.localizedDescription)"), json: common.json)
        }
        if common.json {
            Out.line(Out.json(["ok": true, "action": "init", "created": true, "path": url.path]))
        } else {
            Out.line("ok: wrote \(url.path)")
            Out.line("help[2]: add secret names + optional '[commands]' mappings · 'sesame add <NAME>' to store values")
        }
    }
}

// MARK: - shim (group)

struct Shim: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shim",
        abstract: "Install/remove PATH-directory wrapper scripts that inject secrets on demand.",
        subcommands: [ShimInstall.self, ShimUninstall.self]
    )
}

struct ShimInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Generate executable shims in ~/.sesame/shims for the mapped commands.",
        discussion: """
        Writes a wrapper script per command to ~/.sesame/shims/. Each wrapper \
        resolves the command's mapped secret(s) from the nearest .sesame at run \
        time, injects only the ones NOT already in the env (each behind Touch ID), \
        then execs the REAL binary by an absolute path baked in now — so there is \
        no recursion. Prepend the shims dir to PATH (see the printed instructions), \
        INCLUDING in the environment your agent runs commands in.
        """
    )

    @Option(name: .customLong("commands"),
            help: "Comma-separated commands to shim (e.g. npm,gh). Default: the commands mapped in .sesame.")
    var commands: String?

    @OptionGroup var common: CommonFlags

    func run() throws {
        let shimsDir = Shims.dir()

        // Which commands to wrap.
        var names: [String]
        if let raw = commands {
            names = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !names.isEmpty else {
                Out.failAndExit(.io("--commands was empty — e.g. --commands npm,gh"), json: common.json)
            }
        } else {
            guard let manifest = try? Manifest.load() else {
                Out.failAndExit(.io("no --commands given and no .sesame found — run 'sesame init' or pass --commands npm,gh"),
                                json: common.json)
            }
            var seen = Set<String>()
            names = []
            for rule in manifest.rules {
                if let first = rule.words.first, !seen.contains(first) {
                    seen.insert(first)
                    names.append(first)
                }
            }
            guard !names.isEmpty else {
                Out.failAndExit(.io(".sesame has no [commands] mappings — add some, or pass --commands npm,gh"),
                                json: common.json)
            }
        }

        do {
            try FileManager.default.createDirectory(at: shimsDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        } catch {
            Out.failAndExit(.io("could not create \(shimsDir.path): \(error.localizedDescription)"), json: common.json)
        }

        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let sesamePath = currentSesamePath()
        var installed: [String] = []
        var skipped: [(name: String, reason: String)] = []

        for name in names {
            guard let real = Shims.resolveRealBinary(name, path: path, excluding: shimsDir.path) else {
                skipped.append((name, "not found on PATH"))
                continue
            }
            let script = Shims.render(name: name, realPath: real, sesamePath: sesamePath)
            let file = shimsDir.appendingPathComponent(name)
            do {
                try script.write(to: file, atomically: true, encoding: .utf8)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            } catch {
                skipped.append((name, "write failed: \(error.localizedDescription)"))
                continue
            }
            installed.append(name)
        }

        if common.json {
            Out.line(Out.json(["ok": true, "action": "shim-install",
                               "installed": installed,
                               "skipped": skipped.map { ["name": $0.name, "reason": $0.reason] },
                               "dir": shimsDir.path]))
            return
        }

        Out.line("installed[\(installed.count)]: \(installed.joined(separator: " "))")
        for s in skipped { Out.err("skipped: \(s.name) — \(s.reason)") }
        Out.line("dir: \(shimsDir.path)")
        Out.line("next: prepend the shims dir to PATH (also in your agent's environment):")
        Out.line("  export PATH=\"\(shimsDir.path):$PATH\"")
        Out.line("help[1]: a shimmed command with no .sesame mapping runs unchanged (no prompt)")
    }
}

struct ShimUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove generated shims from ~/.sesame/shims."
    )

    @Option(name: .customLong("commands"),
            help: "Comma-separated commands to remove. Default: all sesame-generated shims.")
    var commands: String?

    @OptionGroup var common: CommonFlags

    func run() throws {
        let shimsDir = Shims.dir()
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: shimsDir.path) else {
            if common.json {
                Out.line(Out.json(["ok": true, "action": "shim-uninstall", "removed": [String]()]))
            } else {
                Out.line("removed[0]: (no shims installed)")
            }
            return
        }

        let filter: Set<String>?
        if let raw = commands {
            filter = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        } else {
            filter = nil
        }

        var removed: [String] = []
        for name in entries {
            if let filter = filter, !filter.contains(name) { continue }
            let file = shimsDir.appendingPathComponent(name)
            // Only remove files we generated (carry the marker), never anything else.
            let contents = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
            guard contents.contains("generated by `sesame shim install`") else { continue }
            if (try? fm.removeItem(at: file)) != nil { removed.append(name) }
        }

        if common.json {
            Out.line(Out.json(["ok": true, "action": "shim-uninstall", "removed": removed]))
        } else {
            Out.line("removed[\(removed.count)]: \(removed.joined(separator: " "))")
        }
    }
}

// MARK: - shim-exec (hidden; the runtime worker each shim delegates to)

struct ShimExec: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shim-exec",
        abstract: "Internal: resolve a shimmed command's mapped secrets and exec the real binary.",
        shouldDisplay: false
    )

    @Option(name: .customLong("name"), help: "The wrapped command's name.")
    var name: String

    @Option(name: .customLong("real"), help: "Absolute path to the real binary.")
    var real: String

    @Argument(parsing: .captureForPassthrough, help: "-- <args…>")
    var tokens: [String] = []

    func run() throws {
        var args = tokens
        if args.first == "--" { args.removeFirst() }
        let realCommand = [real] + args
        let commandTokens = [name] + args

        // No manifest anywhere → run unchanged (fail-safe, no prompt).
        guard let manifestURL = Manifest.find() else { passthrough(realCommand) }

        let manifest: Manifest
        do {
            let text = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
            manifest = try Manifest.parse(text, path: manifestURL)
        } catch let error as ManifestError {
            // Never break the wrapped command on a bad manifest — warn + passthrough.
            Out.err("sesame: warning: \(error.message) — running \(name) without injection")
            passthrough(realCommand)
        }

        let mapped = manifest.secrets(forCommand: commandTokens)
        if mapped.isEmpty { passthrough(realCommand) } // unmapped → no prompt

        // Skip any already present + non-empty (inherited); only fetch the rest.
        let env = ProcessInfo.processInfo.environment
        let needed = mapped.filter { (env[$0] ?? "").isEmpty }
        if needed.isEmpty { passthrough(realCommand) } // all present → no prompt

        let wiring = resolveWiring()
        let log = makeLog()
        let requester = Requester.parentName()

        let stored = (try? wiring.store.list())?.map { $0.name } ?? []
        let missing = needed.filter { !stored.contains($0) }
        if !missing.isEmpty {
            Out.failAndExit(message: ManifestError.unknownSecrets(missing: missing, stored: stored).message,
                            code: 2, json: false)
        }

        let injected: [String: String]
        do {
            injected = try Resolve.secrets(names: needed, store: wiring.store, auth: wiring.auth,
                                           limiter: RateLimiter(), log: log, requester: requester,
                                           op: "run", skipIfPresent: false, env: [:])
        } catch let error as SesameError {
            Out.failAndExit(error, json: false)
        }

        do {
            try Runner.exec(command: realCommand, secrets: injected)
        } catch let error as SesameError {
            Out.failAndExit(error, json: false)
        } catch {
            Out.failAndExit(.io(error.localizedDescription), json: false)
        }
    }

    /// Exec the real binary with no injection (env inherited as-is).
    private func passthrough(_ command: [String]) -> Never {
        do {
            try Runner.exec(command: command, secrets: [:])
        } catch let error as SesameError {
            Out.failAndExit(error, json: false)
        } catch {
            Out.failAndExit(.io(error.localizedDescription), json: false)
        }
    }
}
