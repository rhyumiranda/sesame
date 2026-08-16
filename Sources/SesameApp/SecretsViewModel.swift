import Foundation
import AppKit
import SesameCore

/// The popover's data source. Wraps the shared `KeychainStore` (service
/// `dev.sesame` — the SAME login-Keychain items the `sesame` CLI uses) and the
/// Touch ID gate.
///
/// Listing NAMES needs no Touch ID (names are not values). Touch ID (via
/// `LAAuthenticator` from SesameCore) is raised only on destructive/reveal
/// actions — here, Remove. Advisory at Stage A, exactly like the CLI.
@MainActor
final class SecretsViewModel: ObservableObject {
    @Published private(set) var secrets: [SecretInfo] = []
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let store: StorageBackend
    private let auth: Authenticator
    private let log: AccessLog

    /// Label recorded as the log `requester` for app-originated actions.
    private let requester = "Sesame.app"

    init(store: StorageBackend = KeychainStore(service: "dev.sesame"),
         auth: Authenticator = LAAuthenticator(),
         log: AccessLog = AccessLog()) {
        self.store = store
        self.auth = auth
        self.log = log
    }

    /// Reload the names list. No Touch ID — names are not secret values.
    func refresh() {
        do {
            secrets = try store.list()
            errorMessage = nil
        } catch let error as SesameError {
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Add a secret. Same idempotent semantics as `sesame add`: re-adding an
    /// existing name is a no-op (never overwrites).
    func add(name: String, value: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try Name.validate(trimmedName)
        } catch let error as SesameError {
            errorMessage = error.message
            return
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        guard !value.isEmpty else {
            errorMessage = "value is empty — nothing to store"
            return
        }
        do {
            let added = try store.add(name: trimmedName, value: Data(value.utf8))
            log.append(LogEntry(ts: Time.iso(), op: "add", name: trimmedName,
                                requester: requester, result: "ok"))
            statusMessage = added ? "added \(trimmedName)" : "\(trimmedName) already exists"
            errorMessage = nil
            refresh()
        } catch let error as SesameError {
            log.append(LogEntry(ts: Time.iso(), op: "add", name: trimmedName,
                                requester: requester, result: error.logResult))
            errorMessage = error.message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Remove a secret behind a Touch ID prompt. Runs the (blocking) biometric
    /// evaluation off the main thread so the UI never stalls, then hops back to
    /// the main actor to publish the result.
    func remove(name: String) {
        // Capture immutable dependencies on the main actor before crossing
        // threads (KeychainStore/AccessLog are value types; Authenticator is a
        // Sendable existential in practice for LAAuthenticator).
        let store = self.store
        let auth = self.auth
        let log = self.log
        let requester = self.requester
        DispatchQueue.global(qos: .userInitiated).async {
            var result: Result<Void, SesameError>
            do {
                try auth.authenticate(reason: "remove secret “\(name)”")
                try store.delete(name: name)
                log.append(LogEntry(ts: Time.iso(), op: "rm", name: name,
                                    requester: requester, result: "ok"))
                result = .success(())
            } catch let error as SesameError {
                log.append(LogEntry(ts: Time.iso(), op: "rm", name: name,
                                    requester: requester, result: error.logResult))
                result = .failure(error)
            } catch {
                result = .failure(.io(error.localizedDescription))
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.statusMessage = "removed \(name)"
                    self.errorMessage = nil
                    self.refresh()
                case .failure(let error):
                    self.errorMessage = error.message
                }
            }
        }
    }

    /// Reveal a secret's value behind Touch ID and copy it to the clipboard —
    /// the value is NEVER rendered on screen or written to any log. Mirrors the
    /// CLI `get` path: authenticate → read → `recordUse` (stamps lastUsedAt +
    /// lastUsedBy so the row's "used X ago" is real) → log the release.
    ///
    /// Runs the blocking biometric evaluation + Keychain read off the main
    /// thread, then hops back to publish only metadata (a status line, never the
    /// value). The value lives on the worker thread's stack and the clipboard.
    func revealAndCopy(name: String) {
        let store = self.store
        let auth = self.auth
        let log = self.log
        let requester = self.requester
        DispatchQueue.global(qos: .userInitiated).async {
            var result: Result<Void, SesameError>
            do {
                try auth.authenticate(reason: "reveal secret “\(name)”")
                let value = try store.copyValue(name: name, reason: "reveal \(name)")
                // Stamp real last-used metadata, exactly like the CLI's get.
                store.recordUse(name: name, by: requester)
                log.append(LogEntry(ts: Time.iso(), op: "get", name: name,
                                    requester: requester, result: "ok"))
                // Copy to the clipboard — the ONLY place the value goes.
                DispatchQueue.main.async {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(String(data: value, encoding: .utf8) ?? "", forType: .string)
                }
                result = .success(())
            } catch let error as SesameError {
                log.append(LogEntry(ts: Time.iso(), op: "get", name: name,
                                    requester: requester, result: error.logResult))
                result = .failure(error)
            } catch {
                result = .failure(.io(error.localizedDescription))
            }
            DispatchQueue.main.async {
                switch result {
                case .success:
                    self.statusMessage = "copied \(name) to the clipboard"
                    self.errorMessage = nil
                    self.refresh() // pick up the fresh lastUsedAt
                case .failure(let error):
                    self.errorMessage = error.message
                }
            }
        }
    }
}

/// Humanizes an ISO-8601 timestamp into a friendly relative phrase for the UI
/// (e.g. "used 2m ago", "never used"). The store keeps timestamps as ISO
/// strings; the window must show a relative time, not a raw ISO string.
enum RelativeTime {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    /// Parse an ISO string to a `Date` (nil if absent/unparseable).
    static func date(from isoString: String?) -> Date? {
        guard let s = isoString else { return nil }
        return iso.date(from: s)
    }

    /// "used 2m ago" for a real last-use, "never used" when there is none.
    static func lastUsed(_ isoString: String?, now: Date = Date()) -> String {
        guard let date = date(from: isoString) else { return "never used" }
        return "used " + relative.localizedString(for: date, relativeTo: now)
    }
}
