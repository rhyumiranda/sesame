import XCTest
import Foundation
@testable import SesameCore

// MARK: - One-click tap-only setup (the app's no-terminal path), hermetic

/// Exercises the shared `TapOnlySetup` orchestrator the app calls, against a
/// throwaway HOME + config so it never touches the real ~/.sesame or ~/.zshrc.
final class TapOnlySetupTests: XCTestCase {
    private var home: URL!
    private var configURL: URL!
    private var binDir: URL!   // a fake PATH dir holding real-looking tool binaries

    override func setUpWithError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-tap-\(UUID().uuidString)")
        home = root.appendingPathComponent("home")
        binDir = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        configURL = home.appendingPathComponent("config.json")

        // Drop a couple of executables the known-tool shims can resolve against.
        for tool in ["gh", "npm"] {
            let f = binDir.appendingPathComponent(tool)
            try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func enable() throws -> TapOnlySetup.EnableResult {
        try TapOnlySetup.enable(sesamePath: "/opt/sesame", path: binDir.path,
                                home: home, configURL: configURL)
    }

    func testEnablePerformsAllThreeEffects() throws {
        let result = try enable()

        // 1. Shims installed for the tools present on the fake PATH.
        XCTAssertTrue(result.installed.contains("gh"))
        XCTAssertTrue(result.installed.contains("npm"))
        let ghShim = Shims.dir(home: home).appendingPathComponent("gh")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: ghShim.path))
        let script = try String(contentsOf: ghShim, encoding: .utf8)
        XCTAssertTrue(script.contains("\"/opt/sesame\" shim-exec"), "shim must exec the given sesame CLI")

        // 2. Config flipped to open mode.
        XCTAssertEqual(Config.load(url: configURL).access, .open)

        // 3. PATH line added to .zshrc (created).
        let zshrc = home.appendingPathComponent(".zshrc")
        let rc = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(rc.contains(Setup.pathLine))
        XCTAssertTrue(result.shellUpdated.contains(".zshrc"))
    }

    func testStatusReflectsEnableThenDisable() throws {
        var status = TapOnlySetup.status(home: home, configURL: configURL)
        XCTAssertFalse(status.enabled)
        XCTAssertEqual(status.shimCount, 0)
        XCTAssertFalse(status.pathWired)

        _ = try enable()
        status = TapOnlySetup.status(home: home, configURL: configURL)
        XCTAssertTrue(status.enabled)
        XCTAssertGreaterThanOrEqual(status.shimCount, 2)
        XCTAssertTrue(status.pathWired)

        _ = try TapOnlySetup.disable(home: home, configURL: configURL)
        status = TapOnlySetup.status(home: home, configURL: configURL)
        XCTAssertFalse(status.enabled, "config back to allowlist")
        XCTAssertEqual(status.shimCount, 0, "generated shims removed")
        XCTAssertFalse(status.pathWired, "PATH line stripped")
    }

    func testDisableRevertsAllThree() throws {
        _ = try enable()
        let result = try TapOnlySetup.disable(home: home, configURL: configURL)

        XCTAssertTrue(result.removedShims.contains("gh"))
        XCTAssertEqual(Config.load(url: configURL).access, .allowlist)

        let zshrc = home.appendingPathComponent(".zshrc")
        let rc = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertFalse(rc.contains(Setup.pathLine), "PATH line must be gone")
        XCTAssertTrue(result.shellCleared.contains(".zshrc"))
    }

    func testEnableIsIdempotentOnPath() throws {
        _ = try enable()
        let second = try enable()
        XCTAssertTrue(second.shellUpdated.isEmpty, "second enable must not re-append the PATH line")
        XCTAssertTrue(second.shellAlready.contains(".zshrc"))

        let rc = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        XCTAssertEqual(rc.components(separatedBy: Setup.pathLine).count - 1, 1,
                       "the PATH line must appear exactly once after re-enabling")
    }

    func testDisableLeavesUnrelatedShellContentAndBinaries() throws {
        // A hand-written line the user cares about, plus a non-Sesame binary sharing
        // the shims dir — neither may be touched by disable.
        let zshrc = home.appendingPathComponent(".zshrc")
        try "export EDITOR=vim\n".write(to: zshrc, atomically: true, encoding: .utf8)
        _ = try enable()

        let shimsDir = Shims.dir(home: home)
        let foreign = shimsDir.appendingPathComponent("not-ours")
        try "#!/bin/sh\necho hi\n".write(to: foreign, atomically: true, encoding: .utf8)

        _ = try TapOnlySetup.disable(home: home, configURL: configURL)

        let rc = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(rc.contains("export EDITOR=vim"), "unrelated rc content must survive")
        XCTAssertTrue(FileManager.default.fileExists(atPath: foreign.path),
                      "a non-Sesame file in the shims dir must never be removed")
    }
}

// MARK: - removePathLine (the reverse of ensurePathLine)

final class RemovePathLineTests: XCTestCase {
    private func tempFile(_ contents: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-rc-\(UUID().uuidString)")
        try? contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRemovesTheLineAndMarkerButKeepsOtherContent() throws {
        let rc = tempFile("export FOO=1\n\n\(Setup.marker)\n\(Setup.pathLine)\nexport BAR=2\n")
        defer { try? FileManager.default.removeItem(at: rc) }

        XCTAssertTrue(try Setup.removePathLine(in: rc))
        let text = try String(contentsOf: rc, encoding: .utf8)
        XCTAssertFalse(text.contains(Setup.pathLine))
        XCTAssertFalse(text.contains(Setup.marker))
        XCTAssertTrue(text.contains("export FOO=1"))
        XCTAssertTrue(text.contains("export BAR=2"))
    }

    func testNoOpWhenLineAbsent() throws {
        let rc = tempFile("export FOO=1\n")
        defer { try? FileManager.default.removeItem(at: rc) }
        XCTAssertFalse(try Setup.removePathLine(in: rc), "nothing to remove → false")
    }

    func testNoOpWhenFileMissing() throws {
        let rc = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-absent-\(UUID().uuidString)")
        XCTAssertFalse(try Setup.removePathLine(in: rc))
    }
}
