import XCTest
import Foundation
@testable import SesameCore
@testable import sesame

// MARK: - Test doubles

/// In-memory store: exercises the resolution logic with no Keychain/Enclave.
private final class FakeStore: StorageBackend {
    private var values: [String: Data]
    private(set) var recorded: [String] = []

    init(_ values: [String: Data]) { self.values = values }

    func exists(_ name: String) throws -> Bool { values[name] != nil }

    @discardableResult
    func add(name: String, value: Data) throws -> Bool {
        if values[name] != nil { return false }
        values[name] = value
        return true
    }

    func copyValue(name: String) throws -> Data {
        guard let d = values[name] else { throw SesameError.notFound(name) }
        return d
    }

    func delete(name: String) throws { values[name] = nil }

    func list() throws -> [SecretInfo] {
        values.keys.sorted().map { SecretInfo(name: $0, createdAt: "t", lastUsedAt: nil, lastUsedBy: nil) }
    }

    func recordUse(name: String, by requester: String?) { recorded.append(name) }
}

/// Counts how many times the gate was raised — proves the env-present / unmapped
/// paths never prompt.
private final class CountingAuthenticator: Authenticator, @unchecked Sendable {
    let approve: Bool
    private(set) var calls = 0
    init(approve: Bool) { self.approve = approve }
    func authenticate(reason: String) throws {
        calls += 1
        if !approve { throw SesameError.denied("fake denial") }
    }
}

private func tempLog() -> AccessLog {
    AccessLog(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("sesame-aenv-\(UUID().uuidString)")
        .appendingPathComponent("access.log"))
}

// MARK: - Manifest parsing

final class ManifestParseTests: XCTestCase {
    func testParsesNamesCommentsAndBlankLines() throws {
        let m = try Manifest.parse("""
        # project secrets
        NPM_TOKEN

        OPENAI_API_KEY   # inline comment
        """)
        XCTAssertEqual(m.secrets, ["NPM_TOKEN", "OPENAI_API_KEY"])
        XCTAssertTrue(m.rules.isEmpty)
    }

    func testParsesCommandMapAndLongestPrefixWins() throws {
        let m = try Manifest.parse("""
        NPM_TOKEN
        GH_TOKEN

        [commands]
        npm: NPM_TOKEN
        npm publish: NPM_TOKEN GH_TOKEN
        gh: GH_TOKEN
        """)
        // `npm publish …` is more specific than `npm`.
        XCTAssertEqual(m.secrets(forCommand: ["npm", "publish", "--dry-run"]), ["NPM_TOKEN", "GH_TOKEN"])
        // Bare `npm ci` only matches the `npm` rule.
        XCTAssertEqual(m.secrets(forCommand: ["npm", "ci"]), ["NPM_TOKEN"])
        // `gh pr` matches `gh`.
        XCTAssertEqual(m.secrets(forCommand: ["gh", "pr", "create"]), ["GH_TOKEN"])
        // An unmapped command → no secrets (runs unchanged).
        XCTAssertEqual(m.secrets(forCommand: ["cargo", "build"]), [])
    }

    func testEmptyManifestIsValid() throws {
        let m = try Manifest.parse("# nothing here\n\n")
        XCTAssertTrue(m.secrets.isEmpty)
        XCTAssertTrue(m.rules.isEmpty)
    }

    func testTemplateParsesToEmptyManifest() throws {
        let m = try Manifest.parse(Manifest.template)
        XCTAssertTrue(m.secrets.isEmpty, "the scaffold is all comments → empty but valid")
        XCTAssertTrue(m.rules.isEmpty)
    }

    // §7 edge cases

    func testDuplicateSecretErrorsWithLineNumbers() {
        XCTAssertThrowsError(try Manifest.parse("NPM_TOKEN\nGH_TOKEN\nNPM_TOKEN\n")) { error in
            guard case let ManifestError.duplicateSecret(name, lines)? = error as? ManifestError else {
                return XCTFail("expected duplicateSecret, got \(error)")
            }
            XCTAssertEqual(name, "NPM_TOKEN")
            XCTAssertEqual(lines, [1, 3])
        }
    }

    func testMalformedSecretNameErrorsWithLine() {
        XCTAssertThrowsError(try Manifest.parse("NPM_TOKEN\nhas-a-dash\n")) { error in
            guard case let ManifestError.malformed(line, content, _)? = error as? ManifestError else {
                return XCTFail("expected malformed, got \(error)")
            }
            XCTAssertEqual(line, 2)
            XCTAssertEqual(content, "has-a-dash")
        }
    }

    func testMalformedCommandLineErrorsWhenNoColon() {
        XCTAssertThrowsError(try Manifest.parse("[commands]\nnpm NPM_TOKEN\n")) { error in
            guard case let ManifestError.malformed(line, _, _)? = error as? ManifestError else {
                return XCTFail("expected malformed, got \(error)")
            }
            XCTAssertEqual(line, 2)
        }
    }

    func testUnknownSectionHeaderErrors() {
        XCTAssertThrowsError(try Manifest.parse("[weird]\nX\n")) { error in
            guard case ManifestError.malformed? = error as? ManifestError else {
                return XCTFail("expected malformed for unknown section, got \(error)")
            }
        }
    }

    func testCommandRuleWithNoSecretsErrors() {
        XCTAssertThrowsError(try Manifest.parse("[commands]\nnpm:\n")) { error in
            guard case ManifestError.malformed? = error as? ManifestError else {
                return XCTFail("expected malformed, got \(error)")
            }
        }
    }
}

// MARK: - Manifest walk-up

final class ManifestFindTests: XCTestCase {
    func testFindsNearestWalkingUp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sesame-find-\(UUID().uuidString)")
        let deep = root.appendingPathComponent("a/b/c")
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let manifest = root.appendingPathComponent(".sesame")
        try "NPM_TOKEN\n".write(to: manifest, atomically: true, encoding: .utf8)

        let found = Manifest.find(startingAt: deep)
        XCTAssertEqual(found?.standardizedFileURL.path, manifest.standardizedFileURL.path)
    }

    func testFindReturnsNilWhenNoneExists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sesame-none-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // A tmp subtree that has no .sesame up to /tmp — may find one higher, so
        // assert load()'s notFound instead of an absolute nil here.
        XCTAssertThrowsError(try Manifest.load(startingAt: root)) { error in
            // If the CI box happens to have a .sesame at $HOME this could pass; in
            // the hermetic tmp tree there is none, so we expect notFound.
            if let e = error as? ManifestError { if case .notFound = e { return } }
            XCTFail("expected notFound, got \(error)")
        }
    }
}

// MARK: - Secret resolution (shared by exec / shim-exec / run)

final class ResolveTests: XCTestCase {
    func testInjectsFetchedValuesAndRecordsUse() throws {
        let store = FakeStore(["A": Data("va".utf8), "B": Data("vb".utf8)])
        let auth = CountingAuthenticator(approve: true)
        let injected = try Resolve.secrets(names: ["A", "B"], store: store, auth: auth,
                                           limiter: RateLimiter(), log: tempLog(), requester: "test",
                                           op: "run", skipIfPresent: false, env: [:])
        XCTAssertEqual(injected, ["A": "va", "B": "vb"])
        XCTAssertEqual(auth.calls, 2, "one gate per fetched secret")
        XCTAssertEqual(Set(store.recorded), ["A", "B"])
    }

    func testSkipsSecretsAlreadyPresentInEnvWithoutPrompting() throws {
        let store = FakeStore(["A": Data("va".utf8), "B": Data("vb".utf8)])
        let auth = CountingAuthenticator(approve: true)
        // A is already in the env (inherited) → skipped; only B is fetched.
        let injected = try Resolve.secrets(names: ["A", "B"], store: store, auth: auth,
                                           limiter: RateLimiter(), log: tempLog(), requester: "test",
                                           op: "run", skipIfPresent: true, env: ["A": "inherited"])
        XCTAssertEqual(injected, ["B": "vb"], "present secret is skipped, not re-fetched")
        XCTAssertEqual(auth.calls, 1, "no prompt for the already-present secret")
        XCTAssertFalse(store.recorded.contains("A"))
    }

    func testUnmappedEmptyNamesNeverPrompts() throws {
        let store = FakeStore([:])
        let auth = CountingAuthenticator(approve: true)
        let injected = try Resolve.secrets(names: [], store: store, auth: auth,
                                           limiter: RateLimiter(), log: tempLog(), requester: nil,
                                           op: "run", skipIfPresent: false, env: [:])
        XCTAssertTrue(injected.isEmpty)
        XCTAssertEqual(auth.calls, 0, "no mapped secrets → no prompt (passthrough)")
    }

    func testMissingSecretThrowsNotFoundBeforeExec() {
        let store = FakeStore(["A": Data("va".utf8)])
        let auth = CountingAuthenticator(approve: true)
        XCTAssertThrowsError(try Resolve.secrets(names: ["A", "MISSING"], store: store, auth: auth,
                                                 limiter: RateLimiter(), log: tempLog(), requester: nil,
                                                 op: "run", skipIfPresent: false, env: [:])) { error in
            guard let e = error as? SesameError, case .notFound = e else {
                return XCTFail("expected notFound, got \(error)")
            }
        }
    }

    func testDeniedGateThrowsAndInjectsNothing() {
        let store = FakeStore(["A": Data("va".utf8)])
        let auth = CountingAuthenticator(approve: false)
        XCTAssertThrowsError(try Resolve.secrets(names: ["A"], store: store, auth: auth,
                                                 limiter: RateLimiter(), log: tempLog(), requester: nil,
                                                 op: "run", skipIfPresent: false, env: [:])) { error in
            guard let e = error as? SesameError, case .denied = e else {
                return XCTFail("expected denied, got \(error)")
            }
        }
        XCTAssertTrue(store.recorded.isEmpty, "a denied gate must never read/record the value")
    }
}

// MARK: - Child actually sees the injected env (exec/shim inject via execve)

final class ExecInjectionTests: XCTestCase {
    func testChildSeesInjectedManifestSecretParentDoesNot() throws {
        let key = "SESAME_TEST_EXEC_VAR"
        XCTAssertNil(ProcessInfo.processInfo.environment[key], "precondition: not in parent env")
        let code = try Runner.spawnWait(command: ["sh", "-c", "test \"$\(key)\" = zzz"],
                                        secrets: [key: "zzz"])
        XCTAssertEqual(code, 0, "child sees the injected manifest secret")
        XCTAssertNil(ProcessInfo.processInfo.environment[key], "parent env stays clean after")
    }
}

// MARK: - Shim generation (PATH-dir wrapper scripts, no recursion)

final class ShimTests: XCTestCase {
    func testRenderBakesAbsoluteRealPathAndExecsIt() {
        let script = Shims.render(name: "npm", realPath: "/usr/local/bin/npm", sesamePath: "/opt/sesame")
        XCTAssertTrue(script.hasPrefix("#!/bin/sh"), "must be an executable script, not a shell function")
        XCTAssertTrue(script.contains("shim-exec"), "delegates to the runtime worker")
        XCTAssertTrue(script.contains("--real \"/usr/local/bin/npm\""),
                      "execs the REAL absolute path (baked in) — never bare `npm` → no recursion")
        XCTAssertTrue(script.contains("\"/opt/sesame\" shim-exec"), "calls the real sesame by absolute path")
        XCTAssertFalse(script.contains("exec npm"), "must never exec the bare command name")
    }

    func testResolveRealBinarySkipsTheShimsDir() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sesame-bin-\(UUID().uuidString)")
        let shims = base.appendingPathComponent("shims")
        let realDir = base.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        // A shim named `tool` in the shims dir, and the REAL `tool` in realDir.
        for dir in [shims, realDir] {
            let f = dir.appendingPathComponent("tool")
            try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }

        // PATH with the shims dir FIRST — resolution must still skip it.
        let path = "\(shims.path):\(realDir.path)"
        let resolved = Shims.resolveRealBinary("tool", path: path, excluding: shims.path)
        XCTAssertEqual(resolved, realDir.appendingPathComponent("tool").path,
                       "resolveRealBinary must skip the shims dir so the shim never resolves to itself")
    }

    func testResolveRealBinaryReturnsNilWhenAbsent() {
        XCTAssertNil(Shims.resolveRealBinary("definitely-not-a-real-binary-xyz",
                                             path: "/nonexistent", excluding: "/nope"))
    }
}
