import XCTest
import Foundation
@testable import SesameCore
@testable import sesame

// MARK: - Test doubles

/// Fake Secure-Enclave provider (pinned decision #8): models the REAL API so a
/// green fake-suite means the store/agent/client logic is real even though the
/// true Enclave only runs on a signed build. It performs a reversible ECIES-like
/// round-trip, THROWS on an invalidated/absent key, tracks concurrency (to prove
/// the agent serializes Touch ID), and honors a deny gate.
final class FakeEnclaveProvider: EnclaveProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var keyPresent = false

    /// Simulate `errSecInvalidKey` / a wiped Enclave.
    var invalidated = false
    /// Simulate the Touch ID outcome on decrypt.
    var gateApproves = true
    /// Optional hold injected into decrypt (for the timeout/serialization tests).
    var onDecrypt: (() -> Void)?

    private var activeDecrypts = 0
    private(set) var maxConcurrentDecrypts = 0

    func hasKey() -> Bool { lock.lock(); defer { lock.unlock() }; return keyPresent }

    func ensureKey() throws {
        lock.lock(); defer { lock.unlock() }
        if invalidated { throw SesameError.enclave("fake: enclave reset") }
        keyPresent = true
    }

    func encrypt(_ plaintext: Data) throws -> Data {
        lock.lock(); let present = keyPresent, bad = invalidated; lock.unlock()
        guard present, !bad else { throw SesameError.enclave("fake: no key") }
        return Self.xor(plaintext)
    }

    func decrypt(_ ciphertext: Data, reason: String) throws -> Data {
        lock.lock()
        let present = keyPresent, bad = invalidated
        if present && !bad {
            activeDecrypts += 1
            maxConcurrentDecrypts = max(maxConcurrentDecrypts, activeDecrypts)
        }
        lock.unlock()
        defer { lock.lock(); activeDecrypts = max(0, activeDecrypts - 1); lock.unlock() }

        guard present, !bad else { throw SesameError.denied("fake: invalidated/absent key") }
        onDecrypt?()
        guard gateApproves else { throw SesameError.denied("fake: gate denied") }
        return Self.xor(ciphertext)
    }

    /// XOR is its own inverse — a deterministic stand-in for the ECIES round-trip.
    private static func xor(_ d: Data) -> Data { Data(d.map { $0 ^ 0x5A }) }
}

/// In-memory `StorageBackend` — the advisory SOURCE in migrate/export tests
/// (avoids touching the real login Keychain).
final class InMemoryStore: StorageBackend, @unchecked Sendable {
    private var items: [String: Data] = [:]
    private var created: [String: String] = [:]

    func exists(_ name: String) throws -> Bool { items[name] != nil }
    @discardableResult
    func add(name: String, value: Data) throws -> Bool {
        if items[name] != nil { return false }
        items[name] = value
        created[name] = Time.iso()
        return true
    }
    func copyValue(name: String) throws -> Data {
        guard let v = items[name] else { throw SesameError.notFound(name) }
        return v
    }
    func delete(name: String) throws {
        guard items[name] != nil else { throw SesameError.notFound(name) }
        items[name] = nil
    }
    func list() throws -> [SecretInfo] {
        items.keys.sorted().map { SecretInfo(name: $0, createdAt: created[$0] ?? Time.iso(),
                                             lastUsedAt: nil, lastUsedBy: nil) }
    }
    func recordUse(name: String, by requester: String?) {}
}

/// Fake peer verifier — supplies a canned identity (signed or flagged-unsigned)
/// so the agent's peer handling is testable without a real signed process.
struct FakePeerVerifier: PeerVerifier {
    let identity: PeerIdentity
    func identify(fd: Int32) throws -> PeerIdentity { identity }
}

/// Spy store that COUNTS `copyValue` calls, so a test can prove the app-injected
/// authorize hook short-circuits BEFORE any release when the user denies.
final class CountingStore: StorageBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private(set) var copyValueCalls = 0

    func exists(_ name: String) throws -> Bool { items[name] != nil }
    @discardableResult
    func add(name: String, value: Data) throws -> Bool {
        if items[name] != nil { return false }
        items[name] = value
        return true
    }
    func copyValue(name: String) throws -> Data {
        lock.lock(); copyValueCalls += 1; lock.unlock()
        guard let v = items[name] else { throw SesameError.notFound(name) }
        return v
    }
    func delete(name: String) throws { items[name] = nil }
    func list() throws -> [SecretInfo] {
        items.keys.sorted().map { SecretInfo(name: $0, createdAt: Time.iso(),
                                             lastUsedAt: nil, lastUsedBy: nil) }
    }
    func recordUse(name: String, by requester: String?) {}
}

private let approvingAuth = FakeAuthenticator(approve: true)

/// A short, unique socket path under /tmp — AF_UNIX `sun_path` is 104 bytes, and
/// the default temp dir under /var/folders can blow past that.
private func tempSocketPath() -> String {
    "/tmp/sesame-\(UUID().uuidString.prefix(8)).sock"
}

private func tempVaultDir() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("sesame-vault-\(UUID().uuidString.prefix(8))")
}

private func tempLog() -> AccessLog {
    AccessLog(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-log-\(UUID().uuidString.prefix(8))")
        .appendingPathComponent("access.log"))
}

// MARK: - SecureEnclaveStore (fake provider)

final class SecureEnclaveStoreTests: XCTestCase {
    func testRoundTripAndCiphertextOnDisk() throws {
        let dir = tempVaultDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let provider = FakeEnclaveProvider()
        let store = SecureEnclaveStore(provider: provider, vaultDir: dir)

        XCTAssertTrue(try store.add(name: "API", value: Data("s3cr3t".utf8)))
        XCTAssertFalse(try store.add(name: "API", value: Data("other".utf8)), "re-add is a no-op")

        // The value comes back byte-for-byte through the fake Enclave.
        XCTAssertEqual(String(data: try store.copyValue(name: "API"), encoding: .utf8), "s3cr3t")

        // The blob ON DISK is ciphertext, never the plaintext (the crux of Stage B).
        let blob = try Data(contentsOf: dir.appendingPathComponent("API.bin"))
        XCTAssertNotEqual(blob, Data("s3cr3t".utf8), "on-disk blob must be ciphertext")

        // list() surfaces the name (never the value); delete removes it.
        XCTAssertEqual(try store.list().map { $0.name }, ["API"])
        try store.delete(name: "API")
        XCTAssertFalse(try store.exists("API"))
    }

    func testDeniedGateThrows() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = FakeEnclaveProvider()
        let store = SecureEnclaveStore(provider: provider, vaultDir: dir)
        try store.add(name: "K", value: Data("v".utf8))
        provider.gateApproves = false
        XCTAssertThrowsError(try store.copyValue(name: "K")) { error in
            guard let e = error as? SesameError, case .denied = e else { return XCTFail("expected denied") }
        }
    }

    func testInvalidatedKeyThrows() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = FakeEnclaveProvider()
        let store = SecureEnclaveStore(provider: provider, vaultDir: dir)
        try store.add(name: "K", value: Data("v".utf8))
        provider.invalidated = true // Enclave reset / device loss
        XCTAssertThrowsError(try store.copyValue(name: "K"))
    }
}

// MARK: - Recovery: migrate / export / import

final class RecoveryTests: XCTestCase {
    func testMigrateAdvisoryToSecureEnclave() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let source = InMemoryStore()
        try source.add(name: "A", value: Data("aaa".utf8))
        try source.add(name: "B", value: Data("bbb".utf8))
        let dest = SecureEnclaveStore(provider: FakeEnclaveProvider(), vaultDir: dir)

        let report = Recovery.migrate(from: source, to: dest, auth: approvingAuth, log: tempLog())
        XCTAssertEqual(report.moved.sorted(), ["A", "B"])
        XCTAssertTrue(report.failed.isEmpty)
        // Advisory source is LEFT INTACT (decision #5).
        XCTAssertTrue(try source.exists("A"))
        // Values round-trip through the SE dest.
        XCTAssertEqual(String(data: try dest.copyValue(name: "A"), encoding: .utf8), "aaa")
        // Re-running is idempotent → all skipped.
        let again = Recovery.migrate(from: source, to: dest, auth: approvingAuth, log: tempLog())
        XCTAssertEqual(again.skipped.sorted(), ["A", "B"])
        XCTAssertTrue(again.moved.isEmpty)
    }

    func testExportImportRoundTrip() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecureEnclaveStore(provider: FakeEnclaveProvider(), vaultDir: dir)
        try store.add(name: "TOKEN", value: Data("tok=en-with-eq".utf8))
        try store.add(name: "KEY", value: Data("plainkey".utf8))

        let pairs = try Recovery.export(from: store, auth: approvingAuth)
        let text = pairs.map { "\($0.name)=\($0.value)" }.joined(separator: "\n")

        // Restore into a FRESH vault.
        let dir2 = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir2) }
        let restored = SecureEnclaveStore(provider: FakeEnclaveProvider(), vaultDir: dir2)
        let parsed = try Recovery.parseEnv(text)
        let report = Recovery.importSecrets(parsed, into: restored, log: tempLog())
        XCTAssertEqual(report.moved.sorted(), ["KEY", "TOKEN"])
        // Value with an '=' survives (value = everything after the first '=').
        XCTAssertEqual(String(data: try restored.copyValue(name: "TOKEN"), encoding: .utf8), "tok=en-with-eq")
    }

    func testParseEnvSkipsCommentsAndRejectsBadNames() throws {
        let ok = try Recovery.parseEnv("# comment\n\nA=1\nB=2\n")
        XCTAssertEqual(ok.map { $0.name }, ["A", "B"])
        XCTAssertThrowsError(try Recovery.parseEnv("1BAD=x"))
    }
}

// MARK: - Agent server: request handling + peer flagging

final class AgentHandlingTests: XCTestCase {
    private func makeServer(store: StorageBackend, verifier: PeerVerifier,
                            timeout: TimeInterval = 60) -> AgentServer {
        AgentServer(socketPath: tempSocketPath(), store: store,
                    log: tempLog(), verifier: verifier, authTimeout: timeout)
    }

    func testGetSurfacesVerifiedSignatureAndValue() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecureEnclaveStore(provider: FakeEnclaveProvider(), vaultDir: dir)
        try store.add(name: "K", value: Data("v".utf8))
        let peer = PeerIdentity(pid: 42, signature: "com.acme.claude", isSigned: true)
        let server = makeServer(store: store, verifier: FakePeerVerifier(identity: peer))

        let resp = server.handle(AgentRequest(op: "get", name: "K"), peer: peer)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.value, "v")
        XCTAssertEqual(resp.requesterSignature, "com.acme.claude", "the prompt/log names the verified peer")
    }

    func testUnsignedPeerIsFlaggedNotRejected() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecureEnclaveStore(provider: FakeEnclaveProvider(), vaultDir: dir)
        try store.add(name: "K", value: Data("v".utf8))
        let unsigned = PeerIdentity(pid: 99, signature: "unsigned:/tmp/x:99", isSigned: false)
        let server = makeServer(store: store, verifier: FakePeerVerifier(identity: unsigned))

        // OPEN policy (decision #7): unsigned is ALLOWED but flagged.
        let resp = server.handle(AgentRequest(op: "get", name: "K"), peer: unsigned)
        XCTAssertTrue(resp.ok, "unsigned peer is allowed (fingerprint is the gate)")
        XCTAssertEqual(resp.requesterSignature, "unsigned:/tmp/x:99", "unsigned peer is clearly flagged")
    }

    func testConcurrentGetsAreSerializedAtOnePromptAtATime() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = FakeEnclaveProvider()
        let store = SecureEnclaveStore(provider: provider, vaultDir: dir)
        try store.add(name: "K", value: Data("v".utf8))
        // Each decrypt lingers briefly so overlap WOULD show if unserialized.
        provider.onDecrypt = { usleep(40_000) }
        let peer = PeerIdentity(pid: 1, signature: "peer", isSigned: true)
        let server = makeServer(store: store, verifier: FakePeerVerifier(identity: peer))

        let group = DispatchGroup()
        for _ in 0..<6 {
            group.enter()
            DispatchQueue.global().async {
                _ = server.handle(AgentRequest(op: "get", name: "K"), peer: peer)
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(provider.maxConcurrentDecrypts, 1, "the agent must serialize Touch ID")
    }

    // MARK: authorizeRelease hook (the app-injected background-approval seam)

    func testAuthorizeHookRunsBeforeReleaseAndPasses() throws {
        let store = CountingStore()
        try store.add(name: "K", value: Data("v".utf8))
        let peer = PeerIdentity(pid: 5, signature: "com.acme.agent", isSigned: true)
        let server = makeServer(store: store, verifier: FakePeerVerifier(identity: peer))

        var sawHookBeforeRelease = false
        server.authorizeRelease = { name, requester, release in
            XCTAssertEqual(name, "K")
            XCTAssertEqual(requester, "com.acme.agent")
            // The hook fires BEFORE any release has happened.
            sawHookBeforeRelease = (store.copyValueCalls == 0)
            return try release() // Allow → perform the release
        }

        let resp = server.handle(AgentRequest(op: "get", name: "K"), peer: peer)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.value, "v")
        XCTAssertTrue(sawHookBeforeRelease, "hook must run before copyValue")
        XCTAssertEqual(store.copyValueCalls, 1, "release runs exactly once on approve")
    }

    func testDenyingHookReturnsDeniedWithoutReleasing() throws {
        let store = CountingStore()
        try store.add(name: "K", value: Data("v".utf8))
        let peer = PeerIdentity(pid: 5, signature: "com.acme.agent", isSigned: true)
        let server = makeServer(store: store, verifier: FakePeerVerifier(identity: peer))

        // nil = user pressed Deny.
        server.authorizeRelease = { _, _, _ in nil }

        let resp = server.handle(AgentRequest(op: "get", name: "K"), peer: peer)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, "denied")
        XCTAssertEqual(store.copyValueCalls, 0, "deny must short-circuit before any release")
    }

    func testNilHookLeavesReleaseUnchanged() throws {
        let store = CountingStore()
        try store.add(name: "K", value: Data("v".utf8))
        let peer = PeerIdentity(pid: 5, signature: "p", isSigned: true)
        let server = makeServer(store: store, verifier: FakePeerVerifier(identity: peer))
        // authorizeRelease left nil → today's behavior: release inline.

        let resp = server.handle(AgentRequest(op: "get", name: "K"), peer: peer)
        XCTAssertTrue(resp.ok)
        XCTAssertEqual(resp.value, "v")
        XCTAssertEqual(store.copyValueCalls, 1)
    }

    func testHookReleaseThrowIsMappedLikeTheNonHookPath() throws {
        let store = CountingStore() // "K" is never added → release throws notFound
        let peer = PeerIdentity(pid: 5, signature: "com.acme.agent", isSigned: true)
        let log = tempLog()
        let server = AgentServer(socketPath: tempSocketPath(), store: store,
                                 log: log, verifier: FakePeerVerifier(identity: peer),
                                 authTimeout: 60)
        // Allow at the prompt, but the Touch ID-gated release itself fails — the
        // hook rethrows, and handleGet must map/log it exactly like no-hook.
        server.authorizeRelease = { _, _, release in try release() }

        let resp = server.handle(AgentRequest(op: "get", name: "K"), peer: peer)
        XCTAssertFalse(resp.ok)
        XCTAssertEqual(resp.error, "notfound:K", "rethrown error maps to the normal wire token")

        // And it is logged with the normal result, not swallowed.
        let last = log.read().last
        XCTAssertEqual(last?["result"] as? String, "notfound")
        XCTAssertEqual(last?["op"] as? String, "get")
    }

    func testQueuedRequestTimesOut() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let provider = FakeEnclaveProvider()
        let store = SecureEnclaveStore(provider: provider, vaultDir: dir)
        try store.add(name: "K", value: Data("v".utf8))
        // First decrypt holds the gate well past the (tiny) timeout.
        provider.onDecrypt = { usleep(500_000) }
        let peer = PeerIdentity(pid: 1, signature: "peer", isSigned: true)
        let server = makeServer(store: store, verifier: FakePeerVerifier(identity: peer),
                                timeout: 0.15)

        var second: AgentResponse?
        let done = DispatchGroup()
        done.enter()
        DispatchQueue.global().async {
            _ = server.handle(AgentRequest(op: "get", name: "K"), peer: peer) // holds the gate
            done.leave()
        }
        usleep(60_000) // let the first grab the gate
        second = server.handle(AgentRequest(op: "get", name: "K"), peer: peer) // must time out
        XCTAssertEqual(second?.error, "timeout")
        XCTAssertEqual(second?.ok, false)
        _ = done.wait(timeout: .now() + 5)
    }
}

// MARK: - End-to-end socket: client <-> server

final class AgentSocketRoundTripTests: XCTestCase {
    func testClientRoundTripOverRealSocket() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecureEnclaveStore(provider: FakeEnclaveProvider(), vaultDir: dir)
        let path = tempSocketPath()
        let peer = PeerIdentity(pid: 7, signature: "com.acme.cli", isSigned: true)
        let server = AgentServer(socketPath: path, store: store, log: tempLog(),
                                 verifier: FakePeerVerifier(identity: peer), authTimeout: 5)
        try server.start()
        defer { server.stop() }

        let client = AgentClient(socketPath: path)
        XCTAssertTrue(client.isAvailable(), "agent should be listening")

        // add -> list -> get -> delete, all over the wire.
        let backed = AgentBackedStore(client: client)
        XCTAssertTrue(try backed.add(name: "WIRE", value: Data("value-1".utf8)))
        XCTAssertEqual(try backed.list().map { $0.name }, ["WIRE"])
        XCTAssertEqual(String(data: try backed.copyValue(name: "WIRE"), encoding: .utf8), "value-1")
        try backed.delete(name: "WIRE")
        XCTAssertFalse(try backed.exists("WIRE"))
    }

    func testClientFailsSafeWhenAgentDown() throws {
        // No server bound at this path.
        let client = AgentClient(socketPath: tempSocketPath())
        XCTAssertFalse(client.isAvailable(), "no agent -> not available -> CLI falls back")
        let backed = AgentBackedStore(client: client)
        XCTAssertThrowsError(try backed.list()) { error in
            guard let e = error as? SesameError, case .agentUnavailable = e else {
                return XCTFail("expected agentUnavailable")
            }
        }
    }
}

// MARK: - Config + CLI wiring resolution

final class ConfigWiringTests: XCTestCase {
    func testDefaultsPreserveStageABehavior() {
        let def = Config()
        XCTAssertEqual(def.storageBackend, .advisory, "default backend stays advisory")
        XCTAssertEqual(def.dataSource, .agent, "default source is agent (fails safe to advisory when down)")
    }

    func testConfigCodableRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString.prefix(8))").appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var cfg = Config()
        cfg.storageBackend = .secureEnclave
        try cfg.save(url: url)
        let loaded = Config.load(url: url)
        XCTAssertEqual(loaded.storageBackend, .secureEnclave)
        XCTAssertEqual(loaded.dataSource, .agent)
    }

    func testAccessDefaultsToAllowlist() {
        XCTAssertEqual(Config().access, .allowlist, "default access is the safe allowlist")
    }

    func testOldConfigWithoutAccessKeyDefaultsToAllowlist() throws {
        // A pre-open-mode config.json (no `access` key) must decode as allowlist.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString.prefix(8))").appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"storage_backend":"advisory","data_source":"agent"}"#.utf8).write(to: url)
        XCTAssertEqual(Config.load(url: url).access, .allowlist)
    }

    func testAccessRoundTripsOpen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString.prefix(8))").appendingPathComponent("config.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        var cfg = Config()
        cfg.access = .open
        try cfg.save(url: url)
        XCTAssertEqual(Config.load(url: url).access, .open)
    }

    func testWiringFailsSafeToAdvisoryWhenAgentDown() {
        var cfg = Config()
        cfg.agentSocket = tempSocketPath() // nothing listening
        let wiring = resolveWiring(config: cfg)
        XCTAssertFalse(wiring.routedToAgent, "no agent -> not routed")
        XCTAssertTrue(wiring.store is KeychainStore, "fail-safe lands on the advisory store")
    }

    func testWiringRoutesToAgentWhenUp() throws {
        let dir = tempVaultDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = SecureEnclaveStore(provider: FakeEnclaveProvider(), vaultDir: dir)
        let path = tempSocketPath()
        let server = AgentServer(socketPath: path, store: store, log: tempLog(),
                                 verifier: FakePeerVerifier(identity: PeerIdentity(pid: 1, signature: "p", isSigned: true)),
                                 authTimeout: 5)
        try server.start()
        defer { server.stop() }

        var cfg = Config()
        cfg.agentSocket = path
        let wiring = resolveWiring(config: cfg)
        XCTAssertTrue(wiring.routedToAgent, "agent up -> routed")
        XCTAssertTrue(wiring.store is AgentBackedStore)
        XCTAssertTrue(wiring.auth is NullAuthenticator, "agent gates; CLI must not double-prompt")
    }
}

// MARK: - Real Secure Enclave (skips cleanly without a signed + entitled build)

final class RealEnclaveTests: XCTestCase {
    func testRealEnclaveRoundTripOrSkip() throws {
        let provider = RealEnclaveProvider(keyTag: "dev.sesame.test.key")
        do {
            try provider.ensureKey()
        } catch {
            throw XCTSkip("no signed+entitled build / Secure Enclave here — skipping real-SE test (\(error))")
        }
        // If we got here we're on a signed build with an Enclave: prove the round trip.
        let cipher = try provider.encrypt(Data("real".utf8))
        XCTAssertNotEqual(cipher, Data("real".utf8))
        let plain = try provider.decrypt(cipher, reason: "test")
        XCTAssertEqual(String(data: plain, encoding: .utf8), "real")
    }
}
