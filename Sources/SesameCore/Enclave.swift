import Foundation
import Security
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// The Secure-Enclave crypto seam. `SecureEnclaveStore` talks ONLY to this
/// protocol, so unit tests can substitute a deterministic fake (see decision #8:
/// the fake must model the real API — ECIES round-trip, throw on an
/// invalidated/absent key, serialize concurrent access, deny-path) and the whole
/// store/agent/CLI-client stack is exercised headlessly. The real Enclave only
/// runs on a signed + entitled build.
public protocol EnclaveProvider: AnyObject {
    /// True if the per-vault SE key already exists.
    func hasKey() -> Bool

    /// Create the per-vault Secure-Enclave key (idempotent — no-op if present).
    /// Real: a biometric-gated EC key on `kSecAttrTokenIDSecureEnclave`.
    func ensureKey() throws

    /// Encrypt with the PUBLIC key — no Touch ID (asymmetric wrap). Throws if the
    /// key is absent.
    func encrypt(_ plaintext: Data) throws -> Data

    /// Decrypt with the PRIVATE key — RAISES Touch ID on the real Enclave.
    /// `reason` is the prompt string (carries the verified requester). Throws on
    /// denial, an invalidated/absent key, or a corrupt blob.
    func decrypt(_ ciphertext: Data, reason: String) throws -> Data
}

/// The real Secure-Enclave provider.
///
/// COMPILES everywhere; only FUNCTIONS on a signed + entitled build with a
/// Secure Enclave. Per decision #3 the SE key is a keychain token item under the
/// app's OWN default access group — a signed app reaches its own items with NO
/// `keychain-access-groups` entitlement (that entitlement is only for cross-app
/// sharing). Per decision #1 the access control is `.privateKeyUsage` +
/// `.biometryAny` (durability: survives fingerprint enrollment changes, unlike
/// `.biometryCurrentSet` which would silently destroy the key — and thus every
/// secret — on any add/remove of a fingerprint).
public final class RealEnclaveProvider: EnclaveProvider {
    /// Keychain application tag identifying this vault's SE key.
    private let tag: Data
    private let label: String

    public init(keyTag: String = "dev.sesame.vault.key", label: String = "Sesame Vault Key") {
        self.tag = Data(keyTag.utf8)
        self.label = label
    }

    private func loadPrivateKey(context: Any? = nil) throws -> SecKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        #if canImport(LocalAuthentication)
        if let context = context {
            query[kSecUseAuthenticationContext as String] = context
        }
        #endif
        var ref: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess, let key = ref else {
            throw SesameError.enclave("SE key unavailable (status \(status))")
        }
        return (key as! SecKey)
    }

    public func hasKey() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: false
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func ensureKey() throws {
        if hasKey() { return }

        var acError: Unmanaged<CFError>?
        // .privateKeyUsage → the key may only be used for private-key ops after
        // biometric auth; .biometryAny → any enrolled fingerprint (durable).
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .biometryAny],
            &acError) else {
            throw SesameError.enclave("could not build SE access control")
        }

        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: tag,
                kSecAttrLabel as String: label,
                kSecAttrAccessControl as String: access
            ]
        ]

        var createError: Unmanaged<CFError>?
        guard SecKeyCreateRandomKey(keyAttrs as CFDictionary, &createError) != nil else {
            let msg = (createError?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown"
            throw SesameError.enclave("SecKeyCreateRandomKey failed — \(msg) (needs a signed+entitled build with a Secure Enclave)")
        }
    }

    public func encrypt(_ plaintext: Data) throws -> Data {
        let privateKey = try loadPrivateKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SesameError.enclave("could not derive SE public key")
        }
        let algorithm: SecKeyAlgorithm = .eciesEncryptionStandardX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else {
            throw SesameError.enclave("ECIES encrypt unsupported for this key")
        }
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(publicKey, algorithm, plaintext as CFData, &error) else {
            let msg = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown"
            throw SesameError.enclave("SecKeyCreateEncryptedData failed — \(msg)")
        }
        return cipher as Data
    }

    public func decrypt(_ ciphertext: Data, reason: String) throws -> Data {
        var authContext: Any?
        #if canImport(LocalAuthentication)
        let ctx = LAContext()
        ctx.localizedReason = reason
        authContext = ctx
        #endif
        let privateKey = try loadPrivateKey(context: authContext)
        let algorithm: SecKeyAlgorithm = .eciesEncryptionStandardX963SHA256AESGCM
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            throw SesameError.enclave("ECIES decrypt unsupported for this key")
        }
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(privateKey, algorithm, ciphertext as CFData, &error) else {
            // Touch ID denial, invalidated key, or a corrupt/foreign blob all land here.
            let msg = (error?.takeRetainedValue()).map { String(describing: $0) } ?? "unknown"
            throw SesameError.denied("Secure Enclave decrypt failed — \(msg)")
        }
        return plain as Data
    }
}

/// Per-secret metadata persisted alongside each ciphertext blob (never the value).
private struct VaultMeta: Codable {
    var createdAt: String
    var lastUsedAt: String?
    var lastUsedBy: String?
}

/// Stage-B cryptographic store. Each secret is ECIES-wrapped to the vault's
/// Secure-Enclave key and written as a FILE (decision #3):
///   `~/Library/Application Support/Sesame/vault/<name>.bin`  (ciphertext, 0600)
///   `~/Library/Application Support/Sesame/vault/<name>.meta` (JSON metadata, 0600)
/// Storing the ciphertext as a file (not a keychain item) avoids the keychain
/// entitlement path entirely — only the SE *key* is a keychain item, reachable
/// by the signed app with no special entitlement.
public final class SecureEnclaveStore: StorageBackend {
    private let provider: EnclaveProvider
    private let vaultDir: URL

    public init(provider: EnclaveProvider, vaultDir: URL = Paths.vaultDir()) {
        self.provider = provider
        self.vaultDir = vaultDir
    }

    private func blobURL(_ name: String) -> URL { vaultDir.appendingPathComponent("\(name).bin") }
    private func metaURL(_ name: String) -> URL { vaultDir.appendingPathComponent("\(name).meta") }

    private func ensureDir() throws {
        try FileManager.default.createDirectory(
            at: vaultDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        // createDirectory won't tighten an existing dir — enforce 0700.
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: vaultDir.path)
    }

    public func exists(_ name: String) throws -> Bool {
        FileManager.default.fileExists(atPath: blobURL(name).path)
    }

    @discardableResult
    public func add(name: String, value: Data) throws -> Bool {
        if try exists(name) { return false }
        try ensureDir()
        try provider.ensureKey()
        let cipher = try provider.encrypt(value)
        try cipher.write(to: blobURL(name), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blobURL(name).path)
        let meta = VaultMeta(createdAt: Time.iso(), lastUsedAt: nil, lastUsedBy: nil)
        try writeMeta(name, meta)
        return true
    }

    public func copyValue(name: String) throws -> Data {
        try copyValue(name: name, reason: "release \(name)")
    }

    public func copyValue(name: String, reason: String) throws -> Data {
        guard try exists(name) else { throw SesameError.notFound(name) }
        let cipher = try Data(contentsOf: blobURL(name))
        return try provider.decrypt(cipher, reason: reason)
    }

    public func delete(name: String) throws {
        guard try exists(name) else { throw SesameError.notFound(name) }
        try? FileManager.default.removeItem(at: metaURL(name))
        try FileManager.default.removeItem(at: blobURL(name))
    }

    public func list() throws -> [SecretInfo] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: vaultDir, includingPropertiesForKeys: nil) else {
            return []
        }
        var infos: [SecretInfo] = []
        for url in entries where url.pathExtension == "bin" {
            let name = url.deletingPathExtension().lastPathComponent
            let meta = readMeta(name)
            infos.append(SecretInfo(name: name,
                                    createdAt: meta.createdAt,
                                    lastUsedAt: meta.lastUsedAt,
                                    lastUsedBy: meta.lastUsedBy))
        }
        return infos.sorted { $0.name < $1.name }
    }

    public func recordUse(name: String, by requester: String?) {
        var meta = readMeta(name)
        meta.lastUsedAt = Time.iso()
        meta.lastUsedBy = requester
        try? writeMeta(name, meta)
    }

    // MARK: - Metadata sidecar

    private func writeMeta(_ name: String, _ meta: VaultMeta) throws {
        let data = try JSONEncoder().encode(meta)
        try data.write(to: metaURL(name), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL(name).path)
    }

    private func readMeta(_ name: String) -> VaultMeta {
        guard let data = try? Data(contentsOf: metaURL(name)),
              let meta = try? JSONDecoder().decode(VaultMeta.self, from: data) else {
            // No sidecar (or unreadable) — fall back to the blob's creation time.
            let created = (try? FileManager.default.attributesOfItem(atPath: blobURL(name).path)[.creationDate] as? Date)
                .flatMap { $0 }.map { Time.iso($0) } ?? Time.iso()
            return VaultMeta(createdAt: created, lastUsedAt: nil, lastUsedBy: nil)
        }
        return meta
    }
}
