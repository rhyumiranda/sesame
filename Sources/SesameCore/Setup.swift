import Foundation

// MARK: - Shell PATH wiring (for on-demand shims)
//
// `sesame setup` puts `~/.sesame/shims` on the user's PATH so on-demand secret
// shims are intercepted. Only needed if the user opts into shims — it is NOT a
// required onboarding step (brew → `sesame add` → `sesame init` → `sesame exec`
// works without it).
//
// The append is EXPLICIT + IDEMPOTENT: the exact literal line is added once,
// guarded by a grep-for-literal so re-running never duplicates it.

public enum Setup {
    /// The exact line appended to the user's shell rc — kept as a literal so the
    /// idempotency grep matches byte-for-byte.
    public static let pathLine = "export PATH=\"$HOME/.sesame/shims:$PATH\""

    /// A one-line comment written above the PATH line for context (its presence
    /// does NOT affect idempotency — only `pathLine` is matched).
    public static let marker = "# Added by 'sesame setup' — on-demand secret shims"

    /// Append `line` to the file at `url` iff that EXACT line is not already
    /// present (matched against each existing line, trimmed of trailing
    /// whitespace). Creates the file when `createIfMissing` is true; when it is
    /// false and the file is absent, does nothing. Returns true iff it appended.
    @discardableResult
    public static func ensurePathLine(in url: URL, createIfMissing: Bool) throws -> Bool {
        let fm = FileManager.default
        let exists = fm.fileExists(atPath: url.path)
        if !exists && !createIfMissing { return false }

        let existing = exists ? (try? String(contentsOf: url, encoding: .utf8)) ?? "" : ""

        // Grep-for-literal: skip if any existing line already IS the PATH line.
        let present = existing
            .components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == pathLine }
        if present { return false }

        var addition = ""
        if !existing.isEmpty && !existing.hasSuffix("\n") { addition += "\n" }
        addition += "\n\(marker)\n\(pathLine)\n"

        let updated = existing + addition
        try updated.write(to: url, atomically: true, encoding: .utf8)
        return true
    }

    /// The exact reverse of `ensurePathLine`: drop any line that IS the PATH line
    /// or the marker comment (trimmed match), collapsing the blank line the append
    /// left behind. Leaves every OTHER line untouched, so a hand-edited rc keeps
    /// its content. Absent file → nothing to do. Returns true iff it removed
    /// anything. Used by the app's reversible "turn off tap-only" path.
    @discardableResult
    public static func removePathLine(in url: URL) throws -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return false }
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""

        var kept: [String] = []
        var removedAny = false
        for line in existing.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == pathLine || trimmed == marker {
                removedAny = true
                continue
            }
            kept.append(line)
        }
        if !removedAny { return false }

        // Collapse any 3+ run of newlines our removed block left behind.
        var text = kept.joined(separator: "\n")
        while text.contains("\n\n\n") {
            text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        return true
    }
}
