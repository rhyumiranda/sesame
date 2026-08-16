import Foundation

/// The storage abstraction both Stage-A advisory storage (`KeychainStore`) and
/// the Stage-B cryptographic store (`SecureEnclaveStore`) implement. Callers
/// (the CLI, the app, the agent) hold a `StorageBackend` and never care which
/// concrete store is behind it — selection is by config (`storage_backend`).
///
/// SECURITY MODEL by backend:
/// - `KeychainStore` (advisory): the value lives in a plain login-Keychain item
///   with no biometric `SecAccessControl`; the Touch ID gate is CLI-layer only.
/// - `SecureEnclaveStore` (secure-enclave): the value is ECIES-wrapped to a
///   Secure-Enclave key whose private half never leaves the chip; reading it
///   REQUIRES Touch ID because the Enclave will not decrypt without it. Reading
///   the stored blob directly yields ciphertext.
public protocol StorageBackend {
    /// True if an item with this name exists (no value read).
    func exists(_ name: String) throws -> Bool

    /// Idempotent add: `false` if the name already exists (never overwrites),
    /// `true` once stored.
    @discardableResult
    func add(name: String, value: Data) throws -> Bool

    /// The ONLY method that returns the raw value. For `SecureEnclaveStore` this
    /// raises Touch ID (the Enclave decrypts); for `KeychainStore` the CLI-layer
    /// gate must have run first.
    func copyValue(name: String) throws -> Data

    func delete(name: String) throws

    /// All secrets' metadata (names + dates + last-use), never values.
    func list() throws -> [SecretInfo]

    /// Record a successful release: stamp lastUsedAt/lastUsedBy.
    func recordUse(name: String, by requester: String?)
}

public extension StorageBackend {
    /// Backends that gate at decrypt-time (Secure Enclave) can override to thread
    /// a caller-supplied prompt reason (e.g. the verified requester) into the
    /// Touch ID prompt. Backends that gate elsewhere ignore `reason`.
    func copyValue(name: String, reason: String) throws -> Data {
        try copyValue(name: name)
    }
}

/// Canonical on-disk locations, all under `~/Library/Application Support/Sesame`.
/// Centralized so the CLI, app, and agent never drift on a path.
public enum Paths {
    /// `~/Library/Application Support/Sesame`.
    public static func appSupport() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sesame")
    }

    /// `…/Sesame/vault` — the Secure-Enclave ciphertext blobs (`<name>.bin`, 0600; dir 0700).
    public static func vaultDir() -> URL {
        appSupport().appendingPathComponent("vault")
    }

    /// `…/Sesame/agent.sock` — the agent's Unix-domain listen socket.
    public static func agentSocket() -> URL {
        appSupport().appendingPathComponent("agent.sock")
    }

    /// `…/Sesame/config.json`.
    public static func configFile() -> URL {
        appSupport().appendingPathComponent("config.json")
    }
}
