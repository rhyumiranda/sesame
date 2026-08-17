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

// MARK: - setup

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Put ~/.sesame/shims on your PATH (for on-demand shims) — idempotent shell-rc edit.",
        discussion: """
        Optional: only needed if you use on-demand secret shims (`sesame shim \
        install`). Appends exactly `export PATH="$HOME/.sesame/shims:$PATH"` to \
        ~/.zshrc (and ~/.bashrc if it exists) once — re-running is a no-op. The \
        core three steps (brew → `sesame add` → `sesame init` → `sesame exec`) \
        do NOT need this.
        """
    )

    @OptionGroup var common: CommonFlags

    func run() throws {
        // Ensure the shims dir exists so the PATH entry resolves.
        let shimsDir = Shims.dir()
        do {
            try FileManager.default.createDirectory(at: shimsDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o755])
        } catch {
            Out.failAndExit(.io("could not create \(shimsDir.path): \(error.localizedDescription)"),
                            json: common.json)
        }

        let home = URL(fileURLWithPath: NSHomeDirectory())
        // zsh is macOS's default shell → create the rc if absent; bash only if present.
        let targets: [(url: URL, create: Bool)] = [
            (home.appendingPathComponent(".zshrc"), true),
            (home.appendingPathComponent(".bashrc"), false)
        ]

        var updated: [String] = []
        var skipped: [String] = []
        for target in targets {
            let appended: Bool
            do {
                appended = try SesameCore.Setup.ensurePathLine(in: target.url, createIfMissing: target.create)
            } catch {
                Out.failAndExit(.io("could not update \(target.url.path): \(error.localizedDescription)"),
                                json: common.json)
            }
            let name = target.url.lastPathComponent
            if appended { updated.append(name) }
            else if FileManager.default.fileExists(atPath: target.url.path) { skipped.append(name) }
        }

        if common.json {
            Out.line(Out.json(["ok": true, "action": "setup",
                               "updated": updated, "already": skipped,
                               "shimsDir": shimsDir.path,
                               "line": SesameCore.Setup.pathLine]))
            return
        }

        Out.line(Banner.text)
        Out.line("")
        if updated.isEmpty {
            Out.line("ok: PATH already wired (\(skipped.joined(separator: ", "))) — you're set.")
        } else {
            Out.line("ok: added the shims dir to your PATH in \(updated.joined(separator: ", ")) — you're set.")
            Out.line("next: open a new shell (or 'source ~/.zshrc') so it takes effect.")
        }
        Out.line("help[1]: this is only for on-demand shims; 'sesame exec -- <cmd>' needs no PATH change")
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
            Out.line("next[2]: 'sesame add <NAME>' to store each secret · 'sesame exec -- <your agent>' to launch with them")
            Out.line("help[1]: for on-demand per-command shims, add a '[commands]' map then 'sesame shim install' (init never installs shims)")
        }
    }
}

// MARK: - agents

struct AgentTargetFlags: ParsableArguments {
    @Flag(name: .customLong("project"), help: "Target only the current repo AGENTS.md.")
    var project = false

    @Flag(name: .customLong("all"), help: "Target global agent files plus the current repo AGENTS.md.")
    var all = false

    func scope(json: Bool) -> Agents.TargetScope {
        if project && all {
            Out.failAndExit(message: "use only one target flag: --project or --all",
                            code: 2, json: json)
        }
        if all { return .all }
        if project { return .project }
        return .global
    }
}

struct AgentsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "Install Sesame secret lookup rules into Codex/Claude agent instruction files.",
        subcommands: [AgentsInstall.self, AgentsUninstall.self, AgentsDoctor.self]
    )
}

private func agentTargets(scope: Agents.TargetScope) -> [URL] {
    Agents.targets(scope: scope,
                   home: URL(fileURLWithPath: NSHomeDirectory()),
                   cwd: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
}

private func printAgentResults(_ results: [Agents.Result], action: String, json: Bool) {
    if json {
        let touched = results.map { ["path": $0.path, "action": $0.action, "present": $0.present] as [String: Any] }
        Out.line(Out.json(["ok": true, "action": action, "touched": touched]))
        return
    }
    if results.isEmpty {
        Out.line("targets[0]: none")
        return
    }
    let rows = results.map { [$0.path, $0.action, $0.present ? "yes" : "no"] }
    Out.line(toonRows("targets", fields: ["path", "action", "present"], rows: rows))
}

struct AgentsInstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Add/update Sesame managed secret lookup rules in agent instruction files."
    )

    @OptionGroup var targets: AgentTargetFlags
    @OptionGroup var common: CommonFlags

    func run() throws {
        var results: [Agents.Result] = []
        for target in agentTargets(scope: targets.scope(json: common.json)) {
            do {
                results.append(try Agents.install(in: target))
            } catch {
                Out.failAndExit(.io("could not update \(target.path): \(error.localizedDescription)"),
                                json: common.json)
            }
        }
        printAgentResults(results, action: "agents-install", json: common.json)
    }
}

struct AgentsUninstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove only Sesame's managed agent instruction block."
    )

    @OptionGroup var targets: AgentTargetFlags
    @OptionGroup var common: CommonFlags

    func run() throws {
        var results: [Agents.Result] = []
        for target in agentTargets(scope: targets.scope(json: common.json)) {
            do {
                results.append(try Agents.uninstall(from: target))
            } catch {
                Out.failAndExit(.io("could not update \(target.path): \(error.localizedDescription)"),
                                json: common.json)
            }
        }
        printAgentResults(results, action: "agents-uninstall", json: common.json)
    }
}

struct AgentsDoctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Report where Sesame agent instruction rules are installed."
    )

    @OptionGroup var targets: AgentTargetFlags
    @OptionGroup var common: CommonFlags

    func run() throws {
        let results = agentTargets(scope: targets.scope(json: common.json)).map { Agents.doctor(url: $0) }
        printAgentResults(results, action: "agents-doctor", json: common.json)
    }
}

// MARK: - shim (group)

/// Write executable shims for `names` into `shimsDir`, resolving each against the
/// process PATH and baking in THIS `sesame` binary's path. A thin wrapper over the
/// shared `Shims.install` seam (which the app's one-click enable also calls) — the
/// shim-authoring logic lives in SesameCore, not here.
func installShims(_ names: [String], into shimsDir: URL)
    -> (installed: [String], skipped: [(name: String, reason: String)]) {
    Shims.install(names, into: shimsDir,
                  sesamePath: currentSesamePath(),
                  path: ProcessInfo.processInfo.environment["PATH"] ?? "")
}

// MARK: - open (toggle the access mode)

struct Open: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open",
        abstract: "Switch to open mode: any shimmed command gets its secret on a single Touch ID tap — no .sesame allowlist.",
        discussion: """
        Sets access = open in the HOME config (set once, applies everywhere) and \
        installs shims for the built-in provider-map tools found on PATH, so a \
        shimmed command with NO .sesame mapping resolves the secret(s) it needs, \
        shows them in the Allow prompt, and injects them on one tap. Add a custom \
        tool with 'sesame shim install --commands <tool>'. Run 'sesame open --off' \
        to return to the default allowlist. You accept that a tap releases whatever \
        the command is shown to need — the prompt is the gate.
        """
    )

    @Flag(name: .customLong("off"), help: "Return to the default allowlist mode (leaves installed shims in place).")
    var off = false

    @OptionGroup var common: CommonFlags

    func run() throws {
        var config = Config.load()
        config.access = off ? .allowlist : .open
        do {
            try config.save()
        } catch {
            Out.failAndExit(.io("could not write config: \(error.localizedDescription)"), json: common.json)
        }

        if off {
            if common.json {
                Out.line(Out.json(["ok": true, "action": "open", "access": "allowlist"]))
            } else {
                Out.line("ok: back to allowlist mode — commands get only their .sesame-mapped secrets.")
            }
            return
        }

        // Enabling open mode → make the shims exist so "only thumb" holds at runtime.
        let shimsDir = Shims.dir()
        try? FileManager.default.createDirectory(at: shimsDir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o755])
        let (installed, skipped) = installShims(Providers.knownCommands, into: shimsDir)

        if common.json {
            Out.line(Out.json(["ok": true, "action": "open", "access": "open",
                               "installed": installed,
                               "skipped": skipped.map { ["name": $0.name, "reason": $0.reason] },
                               "dir": shimsDir.path]))
            return
        }
        Out.line("ok: open mode on — a tap releases whatever a shimmed command needs (no .sesame).")
        Out.line("shims[\(installed.count)]: \(installed.joined(separator: " "))")
        Out.line("dir: \(shimsDir.path)")
        Out.line("next: ensure the shims dir is on PATH (also in your agent's env) — 'sesame setup' wires it:")
        Out.line("  export PATH=\"\(shimsDir.path):$PATH\"")
        Out.line("help[1]: custom tool? 'sesame shim install --commands <tool>' · turn off with 'sesame open --off'")
    }
}

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

    @Flag(name: .customLong("known"),
          help: "Shim every built-in provider-map tool found on PATH (for open mode); no .sesame needed.")
    var known = false

    @OptionGroup var common: CommonFlags

    func run() throws {
        let shimsDir = Shims.dir()

        // Which commands to wrap.
        var names: [String]
        if known {
            // Open mode: shim the tools Sesame can resolve without a manifest.
            // Absent-on-PATH ones are simply skipped below (never an error).
            names = Providers.knownCommands
        } else if let raw = commands {
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

        let (installed, skipped) = installShims(names, into: shimsDir)

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

        let filter: Set<String>?
        if let raw = commands {
            filter = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        } else {
            filter = nil
        }

        // Only removes files carrying the generated marker — never an unrelated
        // binary in the dir. Shared with the app's off path (SesameCore.Shims).
        let removed = Shims.uninstallGenerated(from: shimsDir, only: filter)

        if common.json {
            Out.line(Out.json(["ok": true, "action": "shim-uninstall", "removed": removed]))
        } else if removed.isEmpty && !FileManager.default.fileExists(atPath: shimsDir.path) {
            Out.line("removed[0]: (no shims installed)")
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

        let config = Config.load()
        let openMode = (config.access == .open)

        // Parse the nearest manifest if there is one. A bad manifest never breaks
        // the wrapped command — warn + passthrough.
        var manifest: Manifest?
        if let manifestURL = Manifest.find() {
            do {
                let text = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
                manifest = try Manifest.parse(text, path: manifestURL)
            } catch let error as ManifestError {
                Out.err("sesame: warning: \(error.message) — running \(name) without injection")
                passthrough(realCommand)
            }
        } else if !openMode {
            // Allowlist mode with no manifest → run unchanged (fail-safe, no prompt).
            passthrough(realCommand)
        }

        let mapped = manifest?.secrets(forCommand: commandTokens) ?? []
        if !mapped.isEmpty {
            // An explicit [commands] rule always wins — today's allowlist path,
            // byte-for-byte unchanged in either mode.
            runAllowlist(mapped: mapped, realCommand: realCommand, config: config)
        } else if openMode {
            // No rule + open mode → resolve the likely secret(s) ourselves.
            runOpen(commandTokens: commandTokens, realCommand: realCommand, config: config)
        } else {
            passthrough(realCommand) // unmapped, allowlist → no prompt
        }
    }

    /// The allowlist path: an explicit `[commands]` rule mapped these secrets.
    /// Behavior is exactly as before open mode existed — a missing/denied secret
    /// stops the command (the rule declared it required).
    private func runAllowlist(mapped: [String], realCommand: [String], config: Config) -> Never {
        // Skip any already present + non-empty (inherited); only fetch the rest.
        let env = ProcessInfo.processInfo.environment
        let needed = mapped.filter { (env[$0] ?? "").isEmpty }
        if needed.isEmpty { passthrough(realCommand) } // all present → no prompt

        let wiring = resolveWiring(config: config)
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
        } catch {
            Out.failAndExit(.io(error.localizedDescription), json: false)
        }

        execInjected(realCommand, injected: injected)
    }

    /// The open-mode path: no `[commands]` rule, so infer the secret(s) via the
    /// built-in provider map (else name-inference, else the full vault). Resolution
    /// is BEST-EFFORT — a denied/failed release never breaks the command, it just
    /// runs bare. Every name about to be released is announced (count + names) so
    /// the tap stays an informed gate even without a pre-approved manifest.
    private func runOpen(commandTokens: [String], realCommand: [String], config: Config) -> Never {
        let wiring = resolveWiring(config: config)
        let action = ShimExec.openAction(command: commandTokens, name: name,
                                         env: ProcessInfo.processInfo.environment,
                                         store: wiring.store, auth: wiring.auth,
                                         limiter: RateLimiter(), log: makeLog(),
                                         requester: Requester.parentName(),
                                         announce: { Out.err($0) })
        switch action {
        case .bare:
            passthrough(realCommand) // nothing to inject / present / denied → run bare
        case .inject(let injected):
            execInjected(realCommand, injected: injected)
        }
    }

    /// What an OPEN-mode invocation should do, once the (side-effect-free) decision
    /// is made. Split out so the decision is unit-testable without execve/Keychain.
    enum OpenAction: Equatable {
        /// Run the command unchanged — nothing inferred, all inherited, or a
        /// best-effort release was denied/rate-limited/gone.
        case bare
        /// Exec the command with exactly these resolved secrets injected.
        case inject([String: String])
    }

    /// The pure decision behind `runOpen`, extracted as a TEST-ONLY seam (no
    /// behavior change): `runOpen` is now a thin interpreter over this. Same order
    /// of operations as before — infer candidate secret(s) via the provider map,
    /// drop any already present+non-empty in `env`, `announce` EXACTLY what is about
    /// to be released (count + names) BEFORE the gate, then attempt a BEST-EFFORT
    /// release. Any `SesameError` (denied / rate-limited / missing) yields `.bare`,
    /// never an error — open mode never breaks the wrapped command.
    static func openAction(command: [String], name: String, env: [String: String],
                           store: StorageBackend, auth: Authenticator, limiter: RateLimiter,
                           log: AccessLog, requester: String?,
                           announce: (String) -> Void) -> OpenAction {
        let vault = (try? store.list())?.map { $0.name } ?? []

        let candidates = Providers.resolve(command: command, vault: vault)
        if candidates.isEmpty { return .bare } // nothing to inject → bare

        // Skip any already present + non-empty (inherited); only fetch the rest.
        let needed = candidates.filter { (env[$0] ?? "").isEmpty }
        if needed.isEmpty { return .bare } // all present → no prompt

        // Announce EXACTLY what open mode is about to release for this command, so
        // the user sees it before the Touch ID tap and can Deny.
        announce("sesame: open mode — releasing \(needed.count) secret(s) to \(name): \(needed.joined(separator: ", "))")

        do {
            let injected = try Resolve.secrets(names: needed, store: store, auth: auth,
                                               limiter: limiter, log: log, requester: requester,
                                               op: "run", skipIfPresent: false, env: [:])
            return .inject(injected)
        } catch {
            // Denied / rate-limited / gone: open mode is best-effort → run bare.
            return .bare
        }
    }

    /// Exec the real binary with the resolved secrets injected.
    private func execInjected(_ realCommand: [String], injected: [String: String]) -> Never {
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
