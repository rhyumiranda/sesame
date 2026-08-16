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
