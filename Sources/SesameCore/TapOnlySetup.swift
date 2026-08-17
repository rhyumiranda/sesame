import Foundation

// MARK: - One-click "tap-only injection" (open mode) setup
//
// Factored out of the CLI's `sesame open` + `sesame setup` so the desktop app can
// perform the SAME one-time onboarding without a terminal. Enabling has three
// reversible effects, all under the user's HOME:
//   1. install the built-in provider-map shims into ~/.sesame/shims,
//   2. set access = open in the HOME config (Config.access),
//   3. put ~/.sesame/shims on PATH via an idempotent shell-rc edit (.zshrc always,
//      .bashrc only if it already exists).
// `disable` reverses all three; `status` reports the current state without
// changing anything. Every effect reuses the shared Shims / Setup / Config seams
// — this type is the orchestrator, not a second copy of that logic.
//
// The caller supplies `sesamePath` (the absolute path to the real `sesame` CLI,
// which the shims exec) and `path` (the PATH to resolve each tool's real binary
// against). A GUI app's own PATH is minimal, so it augments both itself before
// calling — this keeps SesameCore free of environment-sniffing and testable.
public enum TapOnlySetup {
    /// What `enable` changed. Names only (reasons are dropped for the UI).
    public struct EnableResult: Equatable, Sendable {
        public let installed: [String]
        public let skipped: [String]
        public let shellUpdated: [String]
        public let shellAlready: [String]
        public let shimsDir: URL
    }

    /// What `disable` reverted.
    public struct DisableResult: Equatable, Sendable {
        public let removedShims: [String]
        public let shellCleared: [String]
        public let shimsDir: URL
    }

    /// The current tap-only state, for the app to render.
    public struct Status: Equatable, Sendable {
        /// access == .open in the HOME config.
        public let enabled: Bool
        /// How many Sesame-generated shims live in ~/.sesame/shims.
        public let shimCount: Int
        /// The PATH line is present in at least one shell rc.
        public let pathWired: Bool
        public let shimsDir: URL

        public init(enabled: Bool, shimCount: Int, pathWired: Bool, shimsDir: URL) {
            self.enabled = enabled
            self.shimCount = shimCount
            self.pathWired = pathWired
            self.shimsDir = shimsDir
        }
    }

    /// The shell rc files `enable`/`disable`/`status` touch: zsh is macOS's
    /// default (created if absent on enable), bash only if it already exists.
    private static func rcTargets(home: URL) -> [(url: URL, create: Bool)] {
        [(home.appendingPathComponent(".zshrc"), true),
         (home.appendingPathComponent(".bashrc"), false)]
    }

    /// Turn tap-only injection ON: install the known-tool shims, flip the config to
    /// open mode, and wire the shims dir onto PATH. Idempotent — re-running only
    /// (re)writes shims and leaves an already-wired rc untouched.
    public static func enable(sesamePath: String, path: String,
                              home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                              configURL: URL = Paths.configFile()) throws -> EnableResult {
        let shimsDir = Shims.dir(home: home)
        try FileManager.default.createDirectory(at: shimsDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        let (installed, skipped) = Shims.install(Providers.knownCommands, into: shimsDir,
                                                 sesamePath: sesamePath, path: path)

        var config = Config.load(url: configURL)
        config.access = .open
        try config.save(url: configURL)

        var updated: [String] = []
        var already: [String] = []
        for target in rcTargets(home: home) {
            let appended = try Setup.ensurePathLine(in: target.url, createIfMissing: target.create)
            let name = target.url.lastPathComponent
            if appended {
                updated.append(name)
            } else if FileManager.default.fileExists(atPath: target.url.path) {
                already.append(name)
            }
        }

        return EnableResult(installed: installed, skipped: skipped.map { $0.name },
                            shellUpdated: updated, shellAlready: already, shimsDir: shimsDir)
    }

    /// Turn tap-only injection OFF, reversing all three effects: flip the config
    /// back to the default allowlist, remove the Sesame-generated shims, and strip
    /// the PATH line from the shell rc files. Idempotent — safe if already off.
    public static func disable(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                               configURL: URL = Paths.configFile()) throws -> DisableResult {
        var config = Config.load(url: configURL)
        config.access = .allowlist
        try config.save(url: configURL)

        let shimsDir = Shims.dir(home: home)
        let removed = Shims.uninstallGenerated(from: shimsDir)

        var cleared: [String] = []
        for target in rcTargets(home: home) {
            if (try? Setup.removePathLine(in: target.url)) == true {
                cleared.append(target.url.lastPathComponent)
            }
        }

        return DisableResult(removedShims: removed, shellCleared: cleared, shimsDir: shimsDir)
    }

    /// Report the current tap-only state without changing anything.
    public static func status(home: URL = URL(fileURLWithPath: NSHomeDirectory()),
                              configURL: URL = Paths.configFile()) -> Status {
        let config = Config.load(url: configURL)
        let shimsDir = Shims.dir(home: home)
        let count = Shims.countGenerated(in: shimsDir)

        var wired = false
        for target in rcTargets(home: home) {
            guard let text = try? String(contentsOf: target.url, encoding: .utf8) else { continue }
            if text.components(separatedBy: "\n")
                .contains(where: { $0.trimmingCharacters(in: .whitespaces) == Setup.pathLine }) {
                wired = true
                break
            }
        }

        return Status(enabled: config.access == .open, shimCount: count,
                      pathWired: wired, shimsDir: shimsDir)
    }
}
