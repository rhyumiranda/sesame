import Foundation
import Security

/// Metadata we track per secret beyond the value + creation date.
/// Stored as a small JSON blob in the item's `kSecAttrComment` field
/// (never contains the value).
public struct Usage: Codable {
    public var lastUsedAt: String?
    public var lastUsedBy: String?

    public init(lastUsedAt: String?, lastUsedBy: String?) {
        self.lastUsedAt = lastUsedAt
        self.lastUsedBy = lastUsedBy
    }
}

/// A secret's metadata as surfaced to `ls` / the dashboard — NEVER the value.
public struct SecretInfo {
    public var name: String
    public var createdAt: String
    public var lastUsedAt: String?
    public var lastUsedBy: String?

    public init(name: String, createdAt: String, lastUsedAt: String?, lastUsedBy: String?) {
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastUsedBy = lastUsedBy
    }
}

/// Login-Keychain storage for Sesame secrets.
///
/// SECURITY MODEL (Free MVP): items are plain `kSecClassGenericPassword`
/// entries with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` and **no**
/// biometric `SecAccessControl`. That means the Keychain itself does NOT
/// require Touch ID to read — the Touch ID gate lives at the CLI layer
/// (see `Gate.swift`). Any same-user process with a login session can read
/// these items directly. This is the accepted $0-tier tradeoff; Milestone 2
/// (signed daemon + Secure-Enclave key-wrap) makes the gate cryptographic.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "dev.sesame") {
        self.service = service
    }

    private func baseQuery(account: String? = nil) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let account = account {
            q[kSecAttrAccount as String] = account
        }
        return q
    }

    /// True if an item with this name already exists (no value read).
    public func exists(_ name: String) throws -> Bool {
        var q = baseQuery(account: name)
        q[kSecReturnAttributes as String] = false
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw mapStatus(status, name: name)
        }
    }

    /// Idempotent add: if the name already exists, returns `false` (no
    /// overwrite); otherwise stores the value and returns `true`.
    /// CopyMatching-first per the pinned spec.
    @discardableResult
    public func add(name: String, value: Data) throws -> Bool {
        if try exists(name) { return false } // already: true

        var attrs = baseQuery(account: name)
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attrs[kSecValueData as String] = value
        // Seed empty usage metadata.
        if let comment = encodeUsage(Usage(lastUsedAt: nil, lastUsedBy: nil)) {
            attrs[kSecAttrComment as String] = comment
        }
        let status = SecItemAdd(attrs as CFDictionary, nil)
        switch status {
        case errSecSuccess: return true
        case errSecDuplicateItem: return false // treat as already present
        default: throw mapStatus(status, name: name)
        }
    }

    /// Reads the raw secret value. This is the ONLY method that returns the
    /// value; callers must have passed the CLI-layer Touch ID gate first.
    public func copyValue(name: String) throws -> Data {
        var q = baseQuery(account: name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        guard status == errSecSuccess else { throw mapStatus(status, name: name) }
        guard let data = item as? Data else { throw SesameError.keychain(errSecInternalError) }
        return data
    }

    public func delete(name: String) throws {
        let status = SecItemDelete(baseQuery(account: name) as CFDictionary)
        guard status == errSecSuccess else { throw mapStatus(status, name: name) }
    }

    /// All secrets' metadata (names + dates + last-use), never values.
    /// Sorted by name for a stable field order.
    public func list() throws -> [SecretInfo] {
        var q = baseQuery()
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw mapStatus(status, name: "*") }
        guard let items = result as? [[String: Any]] else { return [] }

        var infos: [SecretInfo] = []
        for item in items {
            guard let name = item[kSecAttrAccount as String] as? String else { continue }
            let created = (item[kSecAttrCreationDate as String] as? Date).map { Time.iso($0) } ?? Time.iso()
            let usage = decodeUsage(item[kSecAttrComment as String] as? String)
            infos.append(SecretInfo(name: name,
                                    createdAt: created,
                                    lastUsedAt: usage.lastUsedAt,
                                    lastUsedBy: usage.lastUsedBy))
        }
        return infos.sorted { $0.name < $1.name }
    }

    /// Record a successful release: stamp lastUsedAt/lastUsedBy on the item.
    public func recordUse(name: String, by requester: String?) {
        let usage = Usage(lastUsedAt: Time.iso(), lastUsedBy: requester)
        guard let comment = encodeUsage(usage) else { return }
        let attrs: [String: Any] = [kSecAttrComment as String: comment]
        _ = SecItemUpdate(baseQuery(account: name) as CFDictionary, attrs as CFDictionary)
    }

    // MARK: - Metadata (de)serialization

    private func encodeUsage(_ usage: Usage) -> String? {
        guard let data = try? JSONEncoder().encode(usage) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeUsage(_ comment: String?) -> Usage {
        guard let comment = comment,
              let data = comment.data(using: .utf8),
              let usage = try? JSONDecoder().decode(Usage.self, from: data) else {
            return Usage(lastUsedAt: nil, lastUsedBy: nil)
        }
        return usage
    }

    // MARK: - OSStatus mapping (exact per the pinned spec)

    func mapStatus(_ status: OSStatus, name: String) -> SesameError {
        switch status {
        case errSecItemNotFound:
            return .notFound(name)
        case errSecInteractionNotAllowed:
            return .keychainLocked
        case errSecAuthFailed:
            return .denied("keychain auth failed")
        default:
            return .keychain(status)
        }
    }
}
