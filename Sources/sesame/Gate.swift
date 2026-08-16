import Foundation
import LocalAuthentication

/// The Touch ID gate, behind a protocol so tests can supply a fake that
/// approves/denies with no prompt.
///
/// SECURITY MODEL (Free MVP): this is a CLI-LAYER / ADVISORY gate. We call
/// `LAContext.evaluatePolicy` before reading the Keychain item, but the item
/// itself carries no biometric `SecAccessControl` — so the fingerprint is a
/// user-facing courtesy check, NOT a cryptographic binding. A same-user
/// process could read the login-Keychain item directly, bypassing this gate.
/// Milestone 2 (Secure Enclave key-wrap in a signed daemon) closes that gap.
protocol Authenticator {
    /// Raises the gate. Returns normally on approval; throws `SesameError`
    /// (`.denied` / `.authUnavailable`) otherwise.
    func authenticate(reason: String) throws
}

/// Real Touch ID via LocalAuthentication. Works from an unsigned CLI so long
/// as it runs inside a logged-in GUI session (see README §9).
struct LAAuthenticator: Authenticator {
    func authenticate(reason: String) throws {
        let context = LAContext()
        var policyError: NSError?
        let policy: LAPolicy = .deviceOwnerAuthenticationWithBiometrics
        guard context.canEvaluatePolicy(policy, error: &policyError) else {
            throw SesameError.authUnavailable(policyError?.localizedDescription ?? "biometrics not available")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var outcome: Result<Void, SesameError> = .failure(.denied("no response"))
        context.evaluatePolicy(policy, localizedReason: reason) { success, evalError in
            if success {
                outcome = .success(())
            } else {
                outcome = .failure(.denied(evalError?.localizedDescription ?? "denied"))
            }
            semaphore.signal()
        }
        semaphore.wait()
        try outcome.get()
    }
}

/// Test double: approves or denies deterministically, records reasons, never
/// touches the biometric hardware.
final class FakeAuthenticator: Authenticator {
    let approve: Bool
    private(set) var prompts: [String] = []

    init(approve: Bool) {
        self.approve = approve
    }

    func authenticate(reason: String) throws {
        prompts.append(reason)
        if !approve {
            throw SesameError.denied("fake denial")
        }
    }
}

/// In-memory sliding-window rate limiter, per secret: max 5 reads / 60 s.
///
/// Single-process only (persistence deferred to Milestone 2), so a fresh
/// `sesame get` never trips it; it exists to throttle rapid repeated reads
/// within one long-lived process and is unit-tested directly.
final class RateLimiter {
    let maxReads: Int
    let windowSeconds: TimeInterval
    private var hits: [String: [Date]] = [:]

    init(maxReads: Int = 5, windowSeconds: TimeInterval = 60) {
        self.maxReads = maxReads
        self.windowSeconds = windowSeconds
    }

    /// Records an attempt. Returns `nil` if allowed, or the whole seconds the
    /// caller must wait before the oldest hit ages out of the window.
    func check(name: String, now: Date = Date()) -> Int? {
        let cutoff = now.addingTimeInterval(-windowSeconds)
        var recent = (hits[name] ?? []).filter { $0 > cutoff }

        if recent.count >= maxReads {
            hits[name] = recent
            if let oldest = recent.min() {
                let secondsLeft = windowSeconds - now.timeIntervalSince(oldest)
                return max(1, Int(secondsLeft.rounded(.up)))
            }
            return 1
        }

        recent.append(now)
        hits[name] = recent
        return nil
    }
}
