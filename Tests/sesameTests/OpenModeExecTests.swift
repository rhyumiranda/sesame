import XCTest
import Foundation
@testable import SesameCore
@testable import sesame

// Integration tests for the ShimExec OPEN-MODE execution path (`ShimExec.openAction`,
// the pure decision behind `runOpen`). These cover the REAL sequence a shimmed
// command with no `[commands]` rule takes in open mode:
//   Providers.resolve → announce (count + names) → Touch ID gate → inject → exec,
//   or run BARE when the best-effort release is denied/rate-limited/missing.
// The `Never`-returning execve tails (`passthrough`/`execInjected`) are exercised
// elsewhere (ExecInjectionTests); here we assert the DECISION and the announcement.

// MARK: - Test doubles

/// In-memory store whose `list()` and value reads agree — the normal case.
private final class FakeVault: StorageBackend {
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

/// Store that ADVERTISES names via `list()` but fails to hand back the value —
/// simulates a secret deleted/gone between the vault listing and the read, so the
/// open-mode release throws `notFound` (best-effort → the command still runs bare).
private final class VanishingVault: StorageBackend {
    private let names: [String]
    init(listing names: [String]) { self.names = names }
    func exists(_ name: String) throws -> Bool { names.contains(name) }
    @discardableResult func add(name: String, value: Data) throws -> Bool { false }
    func copyValue(name: String) throws -> Data { throw SesameError.notFound(name) }
    func delete(name: String) throws {}
    func list() throws -> [SecretInfo] {
        names.sorted().map { SecretInfo(name: $0, createdAt: "t", lastUsedAt: nil, lastUsedBy: nil) }
    }
    func recordUse(name: String, by requester: String?) {}
}

/// Counts gate calls; approves or denies with no real Touch ID prompt.
private final class GateSpy: Authenticator, @unchecked Sendable {
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
        .appendingPathComponent("sesame-open-\(UUID().uuidString)")
        .appendingPathComponent("access.log"))
}

/// Drive `ShimExec.openAction` while capturing the announcement line(s).
private func decide(command: [String], name: String, env: [String: String] = [:],
                    store: StorageBackend, gate: GateSpy,
                    limiter: RateLimiter = RateLimiter())
    -> (action: ShimExec.OpenAction, announced: [String]) {
    var announced: [String] = []
    let action = ShimExec.openAction(command: command, name: name, env: env,
                                     store: store, auth: gate, limiter: limiter,
                                     log: tempLog(), requester: "test",
                                     announce: { announced.append($0) })
    return (action, announced)
}

final class OpenModeExecTests: XCTestCase {

    // MARK: Known-tool resolution (built-in provider map) → inject + announce

    func testKnownToolResolvesMappedSecretAndInjects() {
        let store = FakeVault(["GH_TOKEN": Data("ghp_x".utf8), "NPM_TOKEN": Data("npm_x".utf8)])
        let gate = GateSpy(approve: true)
        let (action, announced) = decide(command: ["gh", "pr", "create"], name: "gh",
                                         store: store, gate: gate)
        XCTAssertEqual(action, .inject(["GH_TOKEN": "ghp_x"]),
                       "gh's mapped secret is released — never the rest of the vault")
        XCTAssertEqual(gate.calls, 1, "exactly one tap for the one released secret")
        XCTAssertEqual(store.recorded, ["GH_TOKEN"], "use is recorded only for what was released")
        XCTAssertEqual(announced, ["sesame: open mode — releasing 1 secret(s) to gh: GH_TOKEN"])
    }

    func testKnownMultiKeyToolReleasesBothKeys() {
        // aws → two mapped keys; open mode surfaces BOTH (multi-key tools depend on it).
        let store = FakeVault(["AWS_ACCESS_KEY_ID": Data("id".utf8),
                               "AWS_SECRET_ACCESS_KEY": Data("sk".utf8),
                               "GH_TOKEN": Data("gh".utf8)])
        let gate = GateSpy(approve: true)
        let (action, announced) = decide(command: ["aws", "s3", "ls"], name: "aws",
                                         store: store, gate: gate)
        XCTAssertEqual(action, .inject(["AWS_ACCESS_KEY_ID": "id", "AWS_SECRET_ACCESS_KEY": "sk"]))
        XCTAssertEqual(gate.calls, 2, "one tap per released key")
        XCTAssertEqual(announced,
                       ["sesame: open mode — releasing 2 secret(s) to aws: AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY"])
    }

    // MARK: Unknown-tool NAME INFERENCE (case-insensitive substring)

    func testUnknownToolInfersByNameSubstring() {
        // `git` is not in the provider map → infer every vault name mentioning GIT.
        let store = FakeVault(["GIT_TOKEN": Data("g1".utf8),
                               "GITHUB_TOKEN": Data("g2".utf8),
                               "NPM_TOKEN": Data("n".utf8)])
        let gate = GateSpy(approve: true)
        let (action, announced) = decide(command: ["git", "push"], name: "git",
                                         store: store, gate: gate)
        XCTAssertEqual(action, .inject(["GIT_TOKEN": "g1", "GITHUB_TOKEN": "g2"]),
                       "substring inference surfaces every GIT-mentioning name (by design), not NPM")
        XCTAssertEqual(gate.calls, 2)
        // Inference preserves the vault's (sorted) order: GITHUB_TOKEN < GIT_TOKEN ('H' < '_').
        XCTAssertEqual(announced, ["sesame: open mode — releasing 2 secret(s) to git: GITHUB_TOKEN, GIT_TOKEN"])
    }

    // MARK: Full-vault fallback (uninferable tool) with the announcement

    func testUninferableToolFallsBackToFullVaultAndAnnouncesAll() {
        let store = FakeVault(["GH_TOKEN": Data("g".utf8), "NPM_TOKEN": Data("n".utf8)])
        let gate = GateSpy(approve: true)
        let (action, announced) = decide(command: ["mystery", "run"], name: "mystery",
                                         store: store, gate: gate)
        XCTAssertEqual(action, .inject(["GH_TOKEN": "g", "NPM_TOKEN": "n"]),
                       "open mode = full-vault access for a tool it can't infer")
        XCTAssertEqual(announced, ["sesame: open mode — releasing 2 secret(s) to mystery: GH_TOKEN, NPM_TOKEN"],
                       "the prompt names EVERY secret about to be released, so the tap is informed")
    }

    // MARK: Best-effort — a denied gate still runs the command (bare)

    func testDeniedGateRunsBareAndAnnouncesFirst() {
        let store = FakeVault(["GH_TOKEN": Data("g".utf8)])
        let gate = GateSpy(approve: false)
        let (action, announced) = decide(command: ["gh", "pr", "list"], name: "gh",
                                         store: store, gate: gate)
        XCTAssertEqual(action, .bare, "denied release is best-effort → command runs unchanged")
        XCTAssertEqual(gate.calls, 1, "the gate was raised (and denied)")
        XCTAssertEqual(store.recorded, [], "a denied release never reads/records the value")
        XCTAssertEqual(announced, ["sesame: open mode — releasing 1 secret(s) to gh: GH_TOKEN"],
                       "the announcement precedes the gate — shown even when the tap is denied")
    }

    // MARK: Best-effort — rate-limited runs bare

    func testRateLimitedRunsBare() {
        let store = FakeVault(["GH_TOKEN": Data("g".utf8)])
        let gate = GateSpy(approve: true)
        // maxReads=0 trips the limiter on the first check → Resolve throws rateLimited.
        let (action, _) = decide(command: ["gh"], name: "gh", store: store, gate: gate,
                                 limiter: RateLimiter(maxReads: 0, windowSeconds: 60))
        XCTAssertEqual(action, .bare, "rate-limited release is best-effort → command runs bare")
        XCTAssertEqual(gate.calls, 0, "the limiter trips BEFORE the gate is raised")
    }

    // MARK: Best-effort — a secret that vanished after listing runs bare

    func testMissingSecretRunsBare() {
        // list() advertises GH_TOKEN but the value read throws notFound.
        let store = VanishingVault(listing: ["GH_TOKEN"])
        let gate = GateSpy(approve: true)
        let (action, announced) = decide(command: ["gh"], name: "gh", store: store, gate: gate)
        XCTAssertEqual(action, .bare, "a gone secret is best-effort → command runs bare, never errors")
        XCTAssertEqual(announced, ["sesame: open mode — releasing 1 secret(s) to gh: GH_TOKEN"])
    }

    // MARK: Environment inheritance — an already-present secret is skipped

    func testAlreadyPresentSecretIsSkippedNoPromptNoAnnounce() {
        let store = FakeVault(["GH_TOKEN": Data("vault".utf8)])
        let gate = GateSpy(approve: true)
        // GH_TOKEN already in the child's inherited env → nothing left to release.
        let (action, announced) = decide(command: ["gh", "pr", "create"], name: "gh",
                                         env: ["GH_TOKEN": "inherited"], store: store, gate: gate)
        XCTAssertEqual(action, .bare, "the only candidate is inherited → run bare")
        XCTAssertEqual(gate.calls, 0, "no prompt for an already-present secret")
        XCTAssertTrue(announced.isEmpty, "nothing released → no announcement")
    }

    func testPartiallyPresentReleasesOnlyTheMissingKey() {
        // aws maps two keys; one is already inherited → release only the other.
        let store = FakeVault(["AWS_ACCESS_KEY_ID": Data("id".utf8),
                               "AWS_SECRET_ACCESS_KEY": Data("sk".utf8)])
        let gate = GateSpy(approve: true)
        let (action, announced) = decide(command: ["aws", "s3", "ls"], name: "aws",
                                         env: ["AWS_ACCESS_KEY_ID": "already"],
                                         store: store, gate: gate)
        XCTAssertEqual(action, .inject(["AWS_SECRET_ACCESS_KEY": "sk"]),
                       "the inherited key is skipped; only the missing one is fetched")
        XCTAssertEqual(gate.calls, 1, "one tap for the single missing key")
        XCTAssertEqual(announced,
                       ["sesame: open mode — releasing 1 secret(s) to aws: AWS_SECRET_ACCESS_KEY"],
                       "the announced count/names reflect only what is actually released")
    }

    // MARK: Nothing to inject → bare, no prompt, no announcement

    func testEmptyVaultRunsBareWithoutPrompt() {
        let store = FakeVault([:])
        let gate = GateSpy(approve: true)
        let (action, announced) = decide(command: ["gh"], name: "gh", store: store, gate: gate)
        XCTAssertEqual(action, .bare, "empty vault → nothing to infer → bare")
        XCTAssertEqual(gate.calls, 0)
        XCTAssertTrue(announced.isEmpty)
    }

    func testKnownToolWithNoStoredNamesRunsBareNoVaultDump() {
        // gh's secret isn't stored → a KNOWN tool injects nothing (must NOT dump the vault).
        let store = FakeVault(["NPM_TOKEN": Data("n".utf8), "STRIPE_API_KEY": Data("s".utf8)])
        let gate = GateSpy(approve: true)
        let (action, announced) = decide(command: ["gh", "pr", "list"], name: "gh",
                                         store: store, gate: gate)
        XCTAssertEqual(action, .bare, "a known tool with none of its names stored runs bare, never a full-vault dump")
        XCTAssertEqual(gate.calls, 0)
        XCTAssertTrue(announced.isEmpty)
    }
}
