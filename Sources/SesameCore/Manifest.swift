import Foundation

// MARK: - Manifest errors
//
// Config/usage errors (exit 2) surfaced by the `.sesame` loader. They carry
// enough context (line numbers, the offending content, the stored-name list)
// that the message alone tells the user exactly what to fix. The SHIM path never
// lets these break a command: it fails safe to a plain passthrough instead of
// throwing (see `sesame shim-exec`). `exec`/`init` surface them directly.

public enum ManifestError: Error, Equatable {
    /// No `.sesame` found walking up from this directory to the filesystem root.
    case notFound(searchedFrom: String)
    /// The same secret name is listed twice (in the names section).
    case duplicateSecret(name: String, lines: [Int])
    /// A line the parser could not make sense of.
    case malformed(line: Int, content: String, reason: String)
    /// A declared name that is not in the vault (checked against the store).
    case unknownSecrets(missing: [String], stored: [String])

    public var exitCode: Int32 { 2 } // all are user config/usage errors

    public var message: String {
        switch self {
        case .notFound(let dir):
            return "no .sesame manifest found (searched from \(dir) up to /) — run 'sesame init' to create one"
        case .duplicateSecret(let name, let lines):
            let where_ = lines.map(String.init).joined(separator: ", ")
            return "duplicate secret '\(name)' in .sesame (lines \(where_)) — list each name once"
        case .malformed(let line, let content, let reason):
            return "malformed .sesame line \(line): '\(content)' — \(reason)"
        case .unknownSecrets(let missing, let stored):
            let names = missing.joined(separator: ", ")
            let have = stored.isEmpty ? "(none stored yet)" : stored.joined(separator: ", ")
            return "secret(s) not in the vault: \(names) — 'sesame add <NAME>' to store. Stored names: \(have)"
        }
    }
}

// MARK: - The `.sesame` project manifest
//
// Names-only (safe to commit). Two parts:
//   1. A list of secret NAMES, one per line (`#` comments, blank lines ignored).
//   2. An optional `[commands]` section mapping a command prefix to the secrets
//      it needs: `COMMAND: SECRET [SECRET…]`. Longest (most-specific) prefix wins.
//
// The loader finds the NEAREST `.sesame` by walking up from a starting dir.

public struct Manifest: Equatable {
    /// One `COMMAND: SECRET [SECRET…]` rule from the `[commands]` section.
    public struct CommandRule: Equatable {
        /// The whitespace-separated command words that must match as a prefix,
        /// e.g. `["npm", "publish"]`.
        public let words: [String]
        /// The secret names to inject when this rule matches.
        public let secrets: [String]

        public init(words: [String], secrets: [String]) {
            self.words = words
            self.secrets = secrets
        }
    }

    /// The declared secret names (top section), in file order, de-duplicated.
    public let secrets: [String]
    /// The `[commands]` rules, in file order.
    public let rules: [CommandRule]
    /// Where this manifest was loaded from (nil for one parsed from a string).
    public let path: URL?

    public init(secrets: [String], rules: [CommandRule], path: URL? = nil) {
        self.secrets = secrets
        self.rules = rules
        self.path = path
    }

    /// Which secrets a concrete invocation needs. `command` is the full token
    /// list (binary name first, then args). The most-specific rule whose `words`
    /// are a prefix of `command` wins; flags beyond the matched prefix are
    /// ignored. Returns `[]` when nothing maps (→ the command runs unchanged).
    public func secrets(forCommand command: [String]) -> [String] {
        var best: CommandRule?
        for rule in rules {
            guard rule.words.count <= command.count else { continue }
            guard Array(command.prefix(rule.words.count)) == rule.words else { continue }
            if best == nil || rule.words.count > best!.words.count {
                best = rule
            }
        }
        return best?.secrets ?? []
    }

    // MARK: Loading

    /// The default starting directory (the process's cwd).
    public static func cwd() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    /// The nearest `.sesame` file walking up from `dir` to the filesystem root,
    /// or `nil` if none exists.
    public static func find(startingAt dir: URL = Manifest.cwd()) -> URL? {
        var current = dir.standardizedFileURL
        while true {
            let candidate = current.appendingPathComponent(".sesame")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { return nil } // reached root
            current = parent
        }
    }

    /// Find + parse the nearest `.sesame`. Throws `ManifestError.notFound` when
    /// there is none.
    public static func load(startingAt dir: URL = Manifest.cwd()) throws -> Manifest {
        guard let url = find(startingAt: dir) else {
            throw ManifestError.notFound(searchedFrom: dir.standardizedFileURL.path)
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return try parse(text, path: url)
    }

    /// Parse manifest text. `path` is carried through for reference only.
    public static func parse(_ text: String, path: URL? = nil) throws -> Manifest {
        var order: [String] = []
        var secretLines: [String: [Int]] = [:]
        var rules: [CommandRule] = []
        var inCommands = false

        // Split preserving line numbers (including blank lines).
        let lines = text.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let lineNo = index + 1
            // Strip a trailing `#` comment (names/commands can't contain `#`).
            let noComment: Substring
            if let hash = rawLine.firstIndex(of: "#") {
                noComment = rawLine[..<hash]
            } else {
                noComment = Substring(rawLine)
            }
            let trimmed = noComment.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Section header.
            if trimmed.hasPrefix("[") {
                if trimmed == "[commands]" {
                    inCommands = true
                    continue
                }
                throw ManifestError.malformed(line: lineNo, content: trimmed,
                    reason: "unknown section header (only [commands] is supported)")
            }

            if !inCommands {
                // A secret name.
                do {
                    try Name.validate(trimmed)
                } catch {
                    throw ManifestError.malformed(line: lineNo, content: trimmed,
                        reason: "not a valid secret name (letters, digits, underscore; not starting with a digit)")
                }
                if secretLines[trimmed] == nil { order.append(trimmed) }
                secretLines[trimmed, default: []].append(lineNo)
            } else {
                // A command rule: split on the first ':'.
                guard let colon = trimmed.firstIndex(of: ":") else {
                    throw ManifestError.malformed(line: lineNo, content: trimmed,
                        reason: "expected 'COMMAND: SECRET [SECRET…]'")
                }
                let cmdPart = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
                let secPart = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                let words = cmdPart.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                let secs = secPart.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard !words.isEmpty else {
                    throw ManifestError.malformed(line: lineNo, content: trimmed,
                        reason: "missing command before ':'")
                }
                guard !secs.isEmpty else {
                    throw ManifestError.malformed(line: lineNo, content: trimmed,
                        reason: "no secrets mapped to '\(cmdPart)'")
                }
                for s in secs {
                    do {
                        try Name.validate(s)
                    } catch {
                        throw ManifestError.malformed(line: lineNo, content: trimmed,
                            reason: "'\(s)' is not a valid secret name")
                    }
                }
                rules.append(CommandRule(words: words, secrets: secs))
            }
        }

        // Duplicate detection (earliest offender first, for a stable message).
        let dups = secretLines.filter { $0.value.count > 1 }
        if let first = dups.min(by: { ($0.value.first ?? 0) < ($1.value.first ?? 0) }) {
            throw ManifestError.duplicateSecret(name: first.key, lines: first.value.sorted())
        }

        return Manifest(secrets: order, rules: rules, path: path)
    }

    /// The scaffold `sesame init` writes: a commented template that parses to an
    /// empty (but valid) manifest.
    public static let template = """
    # .sesame — the env secrets this project needs (NAMES only; safe to commit).
    #
    # One secret name per line. Store the value once with:  sesame add <NAME>
    # Then launch your agent/command with the secrets present via:
    #   sesame exec -- <cmd>          (batch pre-load; no further prompts)
    # or install on-demand shims (per-secret Touch ID, only when a command needs it):
    #   sesame shim install
    #   export PATH="$HOME/.sesame/shims:$PATH"

    # NPM_TOKEN
    # OPENAI_API_KEY

    # Optional: map a command prefix to only the secrets it needs.
    # Longest (most-specific) match wins; a command with no mapping runs unchanged.
    # [commands]
    # npm publish: NPM_TOKEN
    # gh: GH_TOKEN

    """
}
