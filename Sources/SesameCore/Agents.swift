import Foundation

public enum Agents {
    public static let startMarker = "<!-- sesame-agents:start -->"
    public static let endMarker = "<!-- sesame-agents:end -->"

    public enum TargetScope {
        case global
        case project
        case all
    }

    public struct Result: Equatable {
        public let path: String
        public let action: String
        public let present: Bool
    }

    public static func globalTargets(home: URL,
                                     installedOnly: Bool = true,
                                     fileExists: ((String) -> Bool)? = nil) -> [URL] {
        let targets = [
            home.appendingPathComponent(".codex/AGENTS.md"),
            home.appendingPathComponent(".claude/CLAUDE.md")
        ]
        guard installedOnly else { return targets }
        let fm = FileManager.default
        let exists = fileExists ?? { fm.fileExists(atPath: $0) }
        return targets.filter { url in
            exists(url.path) || exists(url.deletingLastPathComponent().path)
        }
    }

    public static func targets(scope: TargetScope,
                               home: URL,
                               cwd: URL,
                               fileExists: ((String) -> Bool)? = nil) -> [URL] {
        let project = [repoRoot(startingAt: cwd, fileExists: fileExists).appendingPathComponent("AGENTS.md")]
        switch scope {
        case .global:
            return globalTargets(home: home, fileExists: fileExists)
        case .project:
            return project
        case .all:
            return globalTargets(home: home, fileExists: fileExists) + project
        }
    }

    public static func repoRoot(startingAt cwd: URL,
                                fileExists: ((String) -> Bool)? = nil) -> URL {
        let fm = FileManager.default
        let exists = fileExists ?? { fm.fileExists(atPath: $0) }
        let originalPath = cwd.standardizedFileURL.path
        var path = originalPath
        while true {
            let marker = (path as NSString).appendingPathComponent(".git")
            if exists(marker) { return URL(fileURLWithPath: path) }
            let parent = (path as NSString).deletingLastPathComponent
            if path == "/" || parent.isEmpty || parent == path {
                return URL(fileURLWithPath: originalPath)
            }
            path = parent
        }
    }

    public static func block() -> String {
        let providerRows = Providers.knownCommands.map { command -> String in
            let names = Providers.map[command] ?? []
            return "- \(command): \(names.joined(separator: ", "))"
        }.joined(separator: "\n")

        return """
        \(startMarker)
        ## Sesame Secret Lookup

        When a command needs a secret, follow these rules:

        - Check the environment first. If the needed env var is set and non-empty, use it.
        - If the env var is unset and `sesame` exists on PATH, run `sesame ls` to see stored secret names.
        - For an exact secret-name match, use `sesame get NAME` when the user asks to access, retrieve, get, show, print, or reveal that secret from Sesame; those words mean value reveal. Let Sesame request the fingerprint/unlock through its own flow; do not ask the user to restate permission first.
        - Prefer `sesame run NAME -- <cmd>` only when the user asks to run/use a command with the secret without showing it.
        - For known tools, infer the provider env names from Sesame's provider map:
        \(providerRows)
        - Never print secret values for vague command-use requests. If the user asks to access/retrieve/get/show/print/reveal a named secret from Sesame, that is explicit enough to run `sesame get NAME`, let Sesame request fingerprint/unlock, then print it after unlock.
        - Distinguish "env unset" from "vault missing": unset means check Sesame; missing means ask the user to add it with `sesame add NAME`.
        \(endMarker)
        """
    }

    @discardableResult
    public static func install(in url: URL) throws -> Result {
        let fm = FileManager.default
        let existed = fm.fileExists(atPath: url.path)
        let existing = existed ? try String(contentsOf: url, encoding: .utf8) : ""
        let managed = block()
        let updated: String
        let action: String

        let ranges = managedBlockRanges(in: existing)
        if let first = ranges.first {
            if ranges.count == 1 && String(existing[first]) == managed {
                return Result(path: url.path, action: "noop", present: true)
            }
            updated = replaceManagedBlocks(in: existing, ranges: ranges, with: managed)
            action = "updated"
        } else {
            var next = existing
            if !next.isEmpty && !next.hasSuffix("\n") { next += "\n" }
            if !next.isEmpty { next += "\n" }
            next += managed + "\n"
            updated = next
            action = existed ? "installed" : "created"
        }

        try fm.createDirectory(at: url.deletingLastPathComponent(),
                               withIntermediateDirectories: true)
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return Result(path: url.path, action: action, present: true)
    }

    @discardableResult
    public static func uninstall(from url: URL) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return Result(path: url.path, action: "missing", present: false)
        }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let ranges = managedBlockRanges(in: existing)
        guard !ranges.isEmpty else {
            return Result(path: url.path, action: "noop", present: false)
        }

        var updated = removeManagedBlocks(in: existing, ranges: ranges)
        while updated.contains("\n\n\n") {
            updated = updated.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return Result(path: url.path, action: "uninstalled", present: false)
    }

    public static func doctor(url: URL) throws -> Result {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return Result(path: url.path, action: "missing", present: false)
        }
        let existing = try String(contentsOf: url, encoding: .utf8)
        let present = !managedBlockRanges(in: existing).isEmpty
        return Result(path: url.path, action: present ? "present" : "absent", present: present)
    }

    private static func managedBlockRanges(in text: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let start = text.range(of: startMarker, range: searchStart..<text.endIndex),
              let end = text.range(of: endMarker, range: start.upperBound..<text.endIndex) {
            ranges.append(start.lowerBound..<end.upperBound)
            searchStart = end.upperBound
        }
        return ranges
    }

    private static func replaceManagedBlocks(in text: String,
                                             ranges: [Range<String.Index>],
                                             with block: String) -> String {
        var output = ""
        var cursor = text.startIndex
        for (index, range) in ranges.enumerated() {
            output += text[cursor..<range.lowerBound]
            if index == 0 { output += block }
            cursor = range.upperBound
        }
        output += text[cursor..<text.endIndex]
        return output
    }

    private static func removeManagedBlocks(in text: String,
                                            ranges: [Range<String.Index>]) -> String {
        var output = ""
        var cursor = text.startIndex
        for range in ranges {
            let expanded = expandedRemovalRange(range, in: text)
            output += text[cursor..<expanded.lowerBound]
            cursor = expanded.upperBound
        }
        output += text[cursor..<text.endIndex]
        return output
    }

    private static func expandedRemovalRange(_ range: Range<String.Index>,
                                             in text: String) -> Range<String.Index> {
        var lower = range.lowerBound
        var upper = range.upperBound
        if lower > text.startIndex, text[text.index(before: lower)] == "\n" {
            lower = text.index(before: lower)
        }
        if upper < text.endIndex, text[upper] == "\n" {
            upper = text.index(after: upper)
        }
        return lower..<upper
    }
}
