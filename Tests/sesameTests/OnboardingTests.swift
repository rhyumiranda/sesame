import XCTest
import Foundation
@testable import SesameCore
@testable import sesame

// MARK: - Branded banner

final class BannerTests: XCTestCase {
    func testCarriesWordmarkAndTagline() {
        // The SESAME wordmark is solid figlet-style block art; assert a
        // distinctive slice of its baseline row.
        XCTAssertTrue(Banner.text.contains(" #####  #######  #####"), "the wordmark should be present")
        XCTAssertTrue(Banner.text.contains("Open sesame — one key, one touch"),
                      "the tagline should be present")
    }

    func testIsPlainMultilineWithNoANSI() {
        // Must be safe in brew caveats + non-TTY pipes: no ANSI escapes.
        XCTAssertFalse(Banner.text.contains("\u{1b}"), "banner must contain no ANSI escape codes")
        let lines = Banner.text.components(separatedBy: "\n")
        XCTAssertGreaterThanOrEqual(lines.count, 4, "banner should be a few lines of art")
        XCTAssertFalse(Banner.text.hasSuffix("\n"), "no trailing newline — callers add their own")
    }

    func testFitsStandardTerminalWidth() {
        // ≤ 64 columns so it never wraps in a terminal or `brew` output.
        for line in Banner.text.components(separatedBy: "\n") {
            XCTAssertLessThanOrEqual(line.count, 64, "banner line too wide (wraps): \(line)")
        }
    }

    /// The Homebrew formula `caveats` embeds the banner VERBATIM. This locks the
    /// two together so neither can silently drift: every banner line must appear
    /// in the formula source (with heredoc backslashes doubled, as Ruby needs).
    func testFormulaCaveatsEmbedTheBannerVerbatim() throws {
        let root = URL(fileURLWithPath: #filePath)   // .../Tests/sesameTests/OnboardingTests.swift
            .deletingLastPathComponent()             // .../Tests/sesameTests
            .deletingLastPathComponent()             // .../Tests
            .deletingLastPathComponent()             // repo root
        let formula = root
            .appendingPathComponent("packaging/homebrew/sesame.rb")
        let source = try String(contentsOf: formula, encoding: .utf8)

        for line in Banner.text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            // Ruby's `<<~EOS` heredoc processes escapes, so a literal `\` in the
            // banner is written `\\` in the formula source.
            let escaped = line.replacingOccurrences(of: "\\", with: "\\\\")
            XCTAssertTrue(source.contains(escaped),
                          "formula caveats must embed banner line verbatim: \(line)")
        }
    }
}

// MARK: - `sesame setup` PATH wiring (hermetic, via the SesameCore seam)

final class SetupTests: XCTestCase {
    private func tempFile(contents: String? = nil) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-rc-\(UUID().uuidString)")
        if let contents = contents {
            try? contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func testAppendsThePathLineOnce() throws {
        let rc = tempFile(contents: "export FOO=1\n")
        defer { try? FileManager.default.removeItem(at: rc) }

        let first = try Setup.ensurePathLine(in: rc, createIfMissing: true)
        XCTAssertTrue(first, "first call should append")

        let text = try String(contentsOf: rc, encoding: .utf8)
        XCTAssertTrue(text.contains(Setup.pathLine), "the exact PATH line should be present")
        XCTAssertTrue(text.contains("export FOO=1"), "existing content must be preserved")
    }

    func testIsIdempotentOnRepeat() throws {
        let rc = tempFile(contents: "")
        defer { try? FileManager.default.removeItem(at: rc) }

        XCTAssertTrue(try Setup.ensurePathLine(in: rc, createIfMissing: true))
        XCTAssertFalse(try Setup.ensurePathLine(in: rc, createIfMissing: true),
                       "second call is a no-op")
        XCTAssertFalse(try Setup.ensurePathLine(in: rc, createIfMissing: true),
                       "third call is a no-op")

        let text = try String(contentsOf: rc, encoding: .utf8)
        let occurrences = text.components(separatedBy: Setup.pathLine).count - 1
        XCTAssertEqual(occurrences, 1, "the PATH line must appear exactly once")
    }

    func testSkipsWhenLineAlreadyPresentEvenWithSurroundingContent() throws {
        // Grep-for-literal: a pre-existing identical line means we never append.
        let rc = tempFile(contents: "# top\n\(Setup.pathLine)\n# bottom\n")
        defer { try? FileManager.default.removeItem(at: rc) }

        XCTAssertFalse(try Setup.ensurePathLine(in: rc, createIfMissing: true),
                       "must detect the existing literal line and skip")
        let text = try String(contentsOf: rc, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: Setup.pathLine).count - 1, 1)
    }

    func testDoesNotCreateMissingFileWhenCreateIsFalse() throws {
        let rc = tempFile() // nothing written → file absent
        XCTAssertFalse(FileManager.default.fileExists(atPath: rc.path), "precondition: absent")

        let appended = try Setup.ensurePathLine(in: rc, createIfMissing: false)
        XCTAssertFalse(appended, "absent file with createIfMissing=false is left alone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: rc.path),
                       "the file must NOT be created")
    }

    func testCreatesMissingFileWhenCreateIsTrue() throws {
        let rc = tempFile()
        defer { try? FileManager.default.removeItem(at: rc) }

        XCTAssertTrue(try Setup.ensurePathLine(in: rc, createIfMissing: true))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rc.path), "file should be created")
        let text = try String(contentsOf: rc, encoding: .utf8)
        XCTAssertTrue(text.contains(Setup.pathLine))
    }
}

// MARK: - `sesame init` writes the manifest (and never installs shims)

final class InitCommandTests: XCTestCase {
    func testWritesAManifestThatParsesToEmpty() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("sesame-init-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let saved = fm.currentDirectoryPath
        defer { fm.changeCurrentDirectoryPath(saved) }
        XCTAssertTrue(fm.changeCurrentDirectoryPath(dir.path), "should cd into the temp dir")

        var cmd = try Init.parse([])
        try cmd.run()

        let manifest = dir.appendingPathComponent(".sesame")
        XCTAssertTrue(fm.fileExists(atPath: manifest.path), "init should write .sesame")

        // The scaffold parses to a valid, empty manifest (names commented out).
        let parsed = try Manifest.load(startingAt: dir)
        XCTAssertTrue(parsed.secrets.isEmpty, "template declares no active secrets")
        XCTAssertTrue(parsed.rules.isEmpty, "template maps no commands")

        // It must NOT have created any shims (init never installs shims).
        let text = try String(contentsOf: manifest, encoding: .utf8)
        XCTAssertTrue(text.contains("[commands]"), "template shows a commented [commands] example")
    }
}

// MARK: - `sesame agents` instruction wiring

final class AgentsInstructionTests: XCTestCase {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sesame-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testBlockContainsRequiredAgentRulesAndProviderNames() {
        let block = Agents.block()
        XCTAssertTrue(block.contains(Agents.startMarker))
        XCTAssertTrue(block.contains(Agents.endMarker))
        XCTAssertTrue(block.contains("Check the environment first"))
        XCTAssertTrue(block.contains("run `sesame ls`"))
        XCTAssertTrue(block.contains("`sesame get NAME`"))
        XCTAssertTrue(block.contains("`sesame run NAME -- <cmd>`"))
        XCTAssertTrue(block.contains("doctl: DIGITALOCEAN_ACCESS_TOKEN"))
        XCTAssertTrue(block.contains("supabase: SUPABASE_ACCESS_TOKEN"))
        XCTAssertTrue(block.contains("Never print secret values unless the user explicitly asks"))
        XCTAssertTrue(block.contains("Distinguish \"env unset\" from \"vault missing\""))
    }

    func testInstallCreatesAndIsIdempotent() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("AGENTS.md")

        let first = try Agents.install(in: file)
        XCTAssertEqual(first.action, "created")

        let second = try Agents.install(in: file)
        XCTAssertEqual(second.action, "noop")

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: Agents.startMarker).count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: Agents.endMarker).count - 1, 1)
    }

    func testInstallUpdatesOneManagedBlockWithoutDuplicating() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("AGENTS.md")
        try """
        # Existing

        \(Agents.startMarker)
        stale
        \(Agents.endMarker)

        keep me
        """.write(to: file, atomically: true, encoding: .utf8)

        let result = try Agents.install(in: file)
        XCTAssertEqual(result.action, "updated")

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("stale"))
        XCTAssertTrue(text.contains("keep me"))
        XCTAssertEqual(text.components(separatedBy: Agents.startMarker).count - 1, 1)
    }

    func testInstallCollapsesDuplicateManagedBlocks() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("AGENTS.md")
        try """
        top
        \(Agents.startMarker)
        stale one
        \(Agents.endMarker)
        middle
        \(Agents.startMarker)
        stale two
        \(Agents.endMarker)
        bottom
        """.write(to: file, atomically: true, encoding: .utf8)

        let result = try Agents.install(in: file)
        XCTAssertEqual(result.action, "updated")

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("top"))
        XCTAssertTrue(text.contains("middle"))
        XCTAssertTrue(text.contains("bottom"))
        XCTAssertFalse(text.contains("stale one"))
        XCTAssertFalse(text.contains("stale two"))
        XCTAssertEqual(text.components(separatedBy: Agents.startMarker).count - 1, 1)
    }

    func testUninstallRemovesOnlyManagedBlock() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("CLAUDE.md")
        try """
        before

        \(Agents.block())

        after
        """.write(to: file, atomically: true, encoding: .utf8)

        let result = try Agents.uninstall(from: file)
        XCTAssertEqual(result.action, "uninstalled")

        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("before"))
        XCTAssertTrue(text.contains("after"))
        XCTAssertFalse(text.contains(Agents.startMarker))
    }

    func testTargetsUseGlobalProjectAndAll() throws {
        let home = URL(fileURLWithPath: "/tmp/sesame-home")
        let cwd = URL(fileURLWithPath: "/tmp/sesame-project")

        XCTAssertEqual(Agents.targets(scope: .global, home: home, cwd: cwd).map(\.path),
                       ["/tmp/sesame-home/.codex/AGENTS.md",
                        "/tmp/sesame-home/.claude/CLAUDE.md"])
        XCTAssertEqual(Agents.targets(scope: .project, home: home, cwd: cwd).map(\.path),
                       ["/tmp/sesame-project/AGENTS.md"])
        XCTAssertEqual(Agents.targets(scope: .all, home: home, cwd: cwd).map(\.path),
                       ["/tmp/sesame-home/.codex/AGENTS.md",
                        "/tmp/sesame-home/.claude/CLAUDE.md",
                        "/tmp/sesame-project/AGENTS.md"])
    }
}
