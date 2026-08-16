import Foundation
import SesameCore

/// Shared secret-resolution used by `run`, `exec`, and `shim-exec`. Pure and
/// testable: it THROWS `SesameError` on any failure (the caller decides how to
/// report/exit), and on success returns ONLY the map of secrets it fetched —
/// which is then injected into the child's environment (never disk/argv/log-value).
///
/// `skipIfPresent` implements PINNED DECISION #3: a name already present +
/// non-empty in `env` is inherited by the child, so it is skipped entirely — no
/// vault read, no Touch ID prompt.
enum Resolve {
    static func secrets(names: [String],
                        store: StorageBackend,
                        auth: Authenticator,
                        limiter: RateLimiter,
                        log: AccessLog,
                        requester: String?,
                        op: String,
                        skipIfPresent: Bool,
                        env: [String: String]) throws -> [String: String] {
        var injected: [String: String] = [:]
        for name in names {
            if skipIfPresent, let existing = env[name], !existing.isEmpty { continue }
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
                log.append(LogEntry(ts: Time.iso(), op: op, name: name, requester: requester, result: "ok"))
            } catch let error as SesameError {
                log.append(LogEntry(ts: Time.iso(), op: op, name: name, requester: requester, result: error.logResult))
                throw error
            }
        }
        return injected
    }
}
