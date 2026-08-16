import Foundation

/// Outcome of a migrate/import pass.
public struct RecoveryReport: Sendable {
    public var moved: [String] = []                 // successfully written to dest
    public var skipped: [String] = []               // already present in dest
    public var failed: [(name: String, error: String)] = []  // left intact in source

    public init() {}
}

/// Key-durability / recovery workflows (pinned decisions #2, #5).
///
/// An SE key is per-device and non-exportable, so an OS reinstall / device loss /
/// Enclave reset means the SE-wrapped secrets are gone. `.biometryAny` prevents
/// loss on fingerprint changes, but not on device loss. These commands are the
/// user-controlled backup + restore + migration story — no hidden second copy
/// (that would defeat the SE gate).
public enum Recovery {
    /// Re-wrap each advisory (Stage-A login-Keychain) secret into the SE store
    /// (pinned decision #5). Touch-ID-gated per source read. On ANY per-secret
    /// failure the advisory copy is LEFT INTACT (we never delete the source);
    /// the caller reports and the user drops old copies later with
    /// `sesame rm --advisory` after verifying.
    public static func migrate(from source: StorageBackend,
                               to dest: StorageBackend,
                               auth: Authenticator,
                               log: AccessLog) -> RecoveryReport {
        var report = RecoveryReport()
        let names: [String]
        do { names = try source.list().map { $0.name } } catch { return report }

        for name in names.sorted() {
            do {
                if try dest.exists(name) {
                    report.skipped.append(name)
                    continue
                }
                try auth.authenticate(reason: "migrate \(name) into the Secure Enclave")
                let value = try source.copyValue(name: name)
                let added = try dest.add(name: name, value: value)
                if added {
                    report.moved.append(name)
                    log.append(LogEntry(ts: Time.iso(), op: "migrate", name: name,
                                        requester: "sesame migrate", result: "ok"))
                } else {
                    report.skipped.append(name)
                }
            } catch let error as SesameError {
                report.failed.append((name, error.message))
                log.append(LogEntry(ts: Time.iso(), op: "migrate", name: name,
                                    requester: "sesame migrate", result: error.logResult))
            } catch {
                report.failed.append((name, error.localizedDescription))
            }
        }
        return report
    }

    /// Dump every secret as `NAME=value` (pinned decision #2 — a backup the user
    /// controls). Touch-ID-gated per read (each `copyValue` may raise a prompt on
    /// the SE store). Returns pairs so the caller renders them; ordering is by name.
    public static func export(from store: StorageBackend,
                              auth: Authenticator) throws -> [(name: String, value: String)] {
        let names = try store.list().map { $0.name }.sorted()
        var pairs: [(name: String, value: String)] = []
        for name in names {
            try auth.authenticate(reason: "export \(name)")
            let value = try store.copyValue(name: name)
            pairs.append((name, String(data: value, encoding: .utf8) ?? ""))
        }
        return pairs
    }

    /// Parse `NAME=value` lines (a prior `export`) into pairs. Blank lines and
    /// `#` comments are ignored; the value is everything after the first `=`
    /// (so values may contain `=`). Invalid names are rejected.
    public static func parseEnv(_ text: String) throws -> [(name: String, value: String)] {
        var pairs: [(name: String, value: String)] = []
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                throw SesameError.io("bad import line (no '='): \(line)")
            }
            let name = String(line[..<eq])
            let value = String(line[line.index(after: eq)...])
            try Name.validate(name)
            pairs.append((name, value))
        }
        return pairs
    }

    /// Restore parsed pairs into a fresh store (pinned decision #2). Idempotent:
    /// an existing name is skipped (never overwritten).
    public static func importSecrets(_ pairs: [(name: String, value: String)],
                                     into store: StorageBackend,
                                     log: AccessLog) -> RecoveryReport {
        var report = RecoveryReport()
        for (name, value) in pairs {
            do {
                let added = try store.add(name: name, value: Data(value.utf8))
                if added {
                    report.moved.append(name)
                    log.append(LogEntry(ts: Time.iso(), op: "import", name: name,
                                        requester: "sesame import", result: "ok"))
                } else {
                    report.skipped.append(name)
                }
            } catch let error as SesameError {
                report.failed.append((name, error.message))
                log.append(LogEntry(ts: Time.iso(), op: "import", name: name,
                                    requester: "sesame import", result: error.logResult))
            } catch {
                report.failed.append((name, error.localizedDescription))
            }
        }
        return report
    }
}
