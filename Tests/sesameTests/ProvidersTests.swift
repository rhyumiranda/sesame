import XCTest
@testable import SesameCore

// Provider-map resolution used by OPEN mode. `resolve` must only ever return
// names present in the vault, and pick the smallest correct set for known tools.
final class ProvidersTests: XCTestCase {
    // MARK: Known tools → their mapped, vault-present names

    func testKnownToolReturnsItsMappedSecret() {
        XCTAssertEqual(Providers.resolve(command: ["doctl", "compute", "droplet", "list"],
                                         vault: ["DIGITALOCEAN_ACCESS_TOKEN", "GH_TOKEN"]),
                       ["DIGITALOCEAN_ACCESS_TOKEN"])
        XCTAssertEqual(Providers.resolve(command: ["gh", "pr", "create"],
                                         vault: ["GH_TOKEN", "NPM_TOKEN"]),
                       ["GH_TOKEN"])
    }

    func testAwsReturnsBothKeysInOrder() {
        XCTAssertEqual(Providers.resolve(command: ["aws", "s3", "ls"],
                                         vault: ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "GH_TOKEN"]),
                       ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"])
    }

    // MARK: Absent mapped names are skipped (never injected, never an error)

    func testKnownToolSkipsVaultAbsentMappedNames() {
        // aws maps two names; only one is stored → release only that one.
        XCTAssertEqual(Providers.resolve(command: ["aws", "s3", "ls"],
                                         vault: ["AWS_ACCESS_KEY_ID"]),
                       ["AWS_ACCESS_KEY_ID"])
    }

    func testKnownToolWithNoStoredNamesReturnsEmpty() {
        // gh's secret isn't stored → nothing to inject, command runs bare.
        // Must NOT dump the rest of the vault for a KNOWN tool.
        XCTAssertEqual(Providers.resolve(command: ["gh", "pr", "list"],
                                         vault: ["NPM_TOKEN", "STRIPE_API_KEY"]),
                       [])
    }

    // MARK: Unknown tools → infer by name, else full vault

    func testUnknownToolInfersByName() {
        XCTAssertEqual(Providers.resolve(command: ["mytool", "deploy"],
                                         vault: ["MYTOOL_TOKEN", "GH_TOKEN"]),
                       ["MYTOOL_TOKEN"])
    }

    func testUnknownUninferableToolFallsBackToFullVault() {
        XCTAssertEqual(Providers.resolve(command: ["mystery", "run"],
                                         vault: ["GH_TOKEN", "NPM_TOKEN"]),
                       ["GH_TOKEN", "NPM_TOKEN"])
    }

    // MARK: Empty vault → nothing, for any tool

    func testEmptyVaultReturnsEmpty() {
        XCTAssertEqual(Providers.resolve(command: ["aws", "s3", "ls"], vault: []), [])
        XCTAssertEqual(Providers.resolve(command: ["mystery"], vault: []), [])
    }

    func testEmptyCommandReturnsEmpty() {
        XCTAssertEqual(Providers.resolve(command: [], vault: ["GH_TOKEN"]), [])
    }

    func testKnownCommandsCoversTheMap() {
        XCTAssertEqual(Set(Providers.knownCommands), Set(Providers.map.keys))
        XCTAssertTrue(Providers.knownCommands.contains("aws"))
        XCTAssertTrue(Providers.knownCommands.contains("doctl"))
        XCTAssertTrue(Providers.knownCommands.contains("gh"))
    }
}
