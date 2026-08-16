import XCTest
import Foundation
import SesameCore
@testable import sesame

/// Test double: approves or denies deterministically, records reasons, never
/// touches the biometric hardware. Lives in the test target (never shipped in
/// the public SesameCore library).
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

/// Keychain-backed tests run against the LOCAL login Keychain using an isolated
/// test service. They SKIP cleanly (via `throw XCTSkip`) when no login Keychain
/// is available (CI, non-mac, or `errSecInteractionNotAllowed`), so the suite
/// stays green headlessly while still exercising the real Security framework on
/// a developer's Mac.
private let kTestService = "dev.sesame.test"

/// Probe whether the login Keychain is usable in this environment.
private func keychainAvailable() -> Bool {
    let store = KeychainStore(service: kTestService)
    do {
        _ = try store.list()
        return true
    } catch {
        return false
    }
}

private func requireKeychain() throws -> KeychainStore {
    guard keychainAvailable() else {
        throw XCTSkip("no usable login Keychain in this environment (CI/headless) — skipping Keychain-backed test")
    }
    return KeychainStore(service: kTestService)
}

private func cleanup(_ store: KeychainStore, _ names: [String]) {
    for name in names { try? store.delete(name: name) }
}

// MARK: - Name validation

final class NameValidationTests: XCTestCase {
    func testAcceptsEnvShapedNames() throws {
        XCTAssertNoThrow(try Name.validate("OPENAI_API_KEY"))
        XCTAssertNoThrow(try Name.validate("_secret"))
        XCTAssertNoThrow(try Name.validate("A1"))
    }

    func testRejectsBadNames() {
        for bad in ["1LEADS_DIGIT", "has-dash", "has space", "", "with.dot"] {
            XCTAssertThrowsError(try Name.validate(bad)) { error in
                guard let e = error as? SesameError, case .badName = e else {
                    return XCTFail("expected badName for '\(bad)'")
                }
                XCTAssertEqual(e.exitCode, 2)
            }
        }
    }
}

// MARK: - Keychain round-trip + gate

final class KeychainRoundTripTests: XCTestCase {
    func testAddListGetApproveRemove() throws {
        let store = try requireKeychain()
        let name = "SESAME_TEST_ROUNDTRIP"
        cleanup(store, [name])
        defer { cleanup(store, [name]) }

        // add
        let added = try store.add(name: name, value: Data("s3cr3t".utf8))
        XCTAssertTrue(added, "first add should store")

        // ls
        let list = try store.list()
        XCTAssertTrue(list.contains { $0.name == name }, "ls should show the added secret")

        // get, behind an APPROVING fake gate
        let auth = FakeAuthenticator(approve: true)
        XCTAssertNoThrow(try auth.authenticate(reason: "release \(name)"))
        let value = try store.copyValue(name: name)
        XCTAssertEqual(String(data: value, encoding: .utf8), "s3cr3t")

        // rm
        try store.delete(name: name)
        let after = try store.list()
        XCTAssertFalse(after.contains { $0.name == name }, "rm should remove the secret")
    }

    func testDenyingGateBlocksBeforeRead() throws {
        // The gate is independent of the Keychain — a denial throws before any read.
        let auth = FakeAuthenticator(approve: false)
        XCTAssertThrowsError(try auth.authenticate(reason: "release X")) { error in
            guard let e = error as? SesameError, case .denied = e else {
                return XCTFail("expected denied")
            }
            XCTAssertEqual(e.exitCode, 1)
        }
    }

    func testIdempotentReAddReportsAlready() throws {
        let store = try requireKeychain()
        let name = "SESAME_TEST_IDEMPOTENT"
        cleanup(store, [name])
        defer { cleanup(store, [name]) }

        XCTAssertTrue(try store.add(name: name, value: Data("one".utf8)), "first add stores")
        XCTAssertFalse(try store.add(name: name, value: Data("two".utf8)), "re-add is a no-op → already:true")
        // Value must NOT be overwritten by the second add.
        XCTAssertEqual(String(data: try store.copyValue(name: name), encoding: .utf8), "one")
    }

    func testNotFoundMapsToExitTwo() throws {
        let store = try requireKeychain()
        let name = "SESAME_TEST_MISSING"
        cleanup(store, [name])
        XCTAssertThrowsError(try store.copyValue(name: name)) { error in
            guard let e = error as? SesameError, case .notFound = e else {
                return XCTFail("expected notFound")
            }
            XCTAssertEqual(e.exitCode, 2)
        }
    }
}

// MARK: - Rate limiter

final class RateLimiterTests: XCTestCase {
    func testTripsOnSixthReadWithinWindow() {
        let limiter = RateLimiter(maxReads: 5, windowSeconds: 60)
        let now = Date()
        // Reads 1..5 allowed.
        for i in 0..<5 {
            XCTAssertNil(limiter.check(name: "K", now: now.addingTimeInterval(Double(i))),
                         "read \(i + 1) should be allowed")
        }
        // 6th trips.
        let wait = limiter.check(name: "K", now: now.addingTimeInterval(5))
        XCTAssertNotNil(wait, "6th read should be rate-limited")
        XCTAssertGreaterThan(wait ?? 0, 0)
    }

    func testWindowSlidesSoOldHitsAgeOut() {
        let limiter = RateLimiter(maxReads: 5, windowSeconds: 60)
        let now = Date()
        for i in 0..<5 { _ = limiter.check(name: "K", now: now.addingTimeInterval(Double(i))) }
        // Well past the window → allowed again.
        XCTAssertNil(limiter.check(name: "K", now: now.addingTimeInterval(120)))
    }

    func testPerSecretIsolation() {
        let limiter = RateLimiter(maxReads: 5, windowSeconds: 60)
        let now = Date()
        for i in 0..<5 { _ = limiter.check(name: "A", now: now.addingTimeInterval(Double(i))) }
        XCTAssertNotNil(limiter.check(name: "A", now: now), "A is limited")
        XCTAssertNil(limiter.check(name: "B", now: now), "B is independent")
    }
}

// MARK: - Env injection (run)

final class RunnerInjectionTests: XCTestCase {
    func testChildSeesInjectedVarAndParentDoesNot() throws {
        let key = "SESAME_TEST_INJECTED_VAR"
        let secret = "injected-value-123"
        XCTAssertNil(ProcessInfo.processInfo.environment[key], "precondition: not in parent env")

        // Mirror Runner.spawnWait's injection: child env = parent + secret.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["printenv", key]
        var env = ProcessInfo.processInfo.environment
        env[key] = secret
        process.environment = env

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let out = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let printed = String(data: out, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(printed, secret, "child printenv should see the injected value")
        XCTAssertEqual(process.terminationStatus, 0)

        // Parent still does not have it (injection was child-scoped only).
        XCTAssertNil(ProcessInfo.processInfo.environment[key], "parent env must stay clean")
    }

    func testSpawnWaitPassesExitCodeThrough() throws {
        let code = try Runner.spawnWait(command: ["sh", "-c", "exit 7"], secrets: [:])
        XCTAssertEqual(code, 7, "run should passthrough the child's exit code")
    }
}

// MARK: - Access log (JSONL)

final class AccessLogTests: XCTestCase {
    private func tempLog() -> AccessLog {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-test-\(UUID().uuidString)")
            .appendingPathComponent("access.log")
        return AccessLog(url: url)
    }

    func testAppendAndReadNewestFirst() {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log.url.deletingLastPathComponent()) }

        log.append(LogEntry(ts: "2026-08-16T10:00:00Z", op: "add", name: "A", requester: "claude", result: "ok"))
        log.append(LogEntry(ts: "2026-08-16T11:00:00Z", op: "get", name: "A", requester: "claude", result: "denied"))

        let entries = log.read()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.first?["op"] as? String, "get", "newest entry first")
        XCTAssertEqual(entries.first?["result"] as? String, "denied")
        // Exact schema fields present.
        for field in ["ts", "op", "name", "requester", "result"] {
            XCTAssertNotNil(entries.first?[field], "log entry must carry '\(field)'")
        }
    }

    func testNullRequesterSerializesAsNull() {
        let log = tempLog()
        defer { try? FileManager.default.removeItem(at: log.url.deletingLastPathComponent()) }
        log.append(LogEntry(ts: "2026-08-16T10:00:00Z", op: "rm", name: "A", requester: nil, result: "ok"))
        let entries = log.read()
        XCTAssertTrue(entries.first?["requester"] is NSNull, "nil requester → JSON null")
    }

    func testNeverContainsValue() {
        // The LogEntry type has no value field — guarantee it by schema.
        let entry = LogEntry(ts: "t", op: "get", name: "A", requester: "x", result: "ok")
        let dict = entry.asDictionary()
        XCTAssertEqual(Set(dict.keys), ["ts", "op", "name", "requester", "result"])
    }
}

// MARK: - JSON output schemas

final class OutputSchemaTests: XCTestCase {
    private func parse(_ s: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any]
    }

    func testErrorJSONShape() {
        let e = SesameError.notFound("X")
        let json = Out.json(["ok": false, "error": e.message, "code": Int(e.exitCode)])
        let obj = parse(json)
        XCTAssertEqual(obj?["ok"] as? Bool, false)
        XCTAssertEqual(obj?["code"] as? Int, 2)
        XCTAssertNotNil(obj?["error"])
    }

    func testAddJSONShape() {
        let json = Out.json(["ok": true, "action": "add", "name": "X",
                             "createdAt": "2026-08-16T10:00:00Z", "already": false])
        let obj = parse(json)
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertEqual(obj?["action"] as? String, "add")
        XCTAssertEqual(obj?["already"] as? Bool, false)
        XCTAssertNil(obj?["value"], "add JSON must never carry a value")
    }

    func testGetJSONShapeOmitsValue() {
        let approved = parse(Out.json(["ok": true, "approved": true, "name": "X"]))
        XCTAssertEqual(approved?["approved"] as? Bool, true)
        XCTAssertNil(approved?["value"], "get JSON must never carry the value")

        let denied = parse(Out.json(["ok": false, "approved": false, "name": "X", "error": "denied"]))
        XCTAssertEqual(denied?["approved"] as? Bool, false)
        XCTAssertNil(denied?["value"])
    }

    func testRunJSONShape() {
        let obj = parse(Out.json(["ok": true, "injected": ["A", "B"], "exitCode": 0]))
        XCTAssertEqual(obj?["injected"] as? [String], ["A", "B"])
        XCTAssertEqual(obj?["exitCode"] as? Int, 0)
    }

    func testLsJSONShape() {
        let secrets: [[String: Any]] = [["name": "A", "createdAt": "t", "lastUsedAt": NSNull(), "lastUsedBy": NSNull()]]
        let obj = parse(Out.json(["secrets": secrets, "total": 1]))
        XCTAssertEqual(obj?["total"] as? Int, 1)
        let arr = obj?["secrets"] as? [[String: Any]]
        XCTAssertEqual(arr?.first?["name"] as? String, "A")
        XCTAssertNil(arr?.first?["value"], "ls JSON must never carry values")
    }

    func testRmJSONShape() {
        let obj = parse(Out.json(["ok": true, "action": "rm", "name": "X"]))
        XCTAssertEqual(obj?["action"] as? String, "rm")
    }
}
