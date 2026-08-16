import Foundation

// MARK: - Branded banner
//
// ONE source of truth for the Sesame wordmark, reused by:
//   • the CLI no-args dashboard header (main.swift),
//   • `sesame setup`,
//   • the Homebrew formula `caveats` (copied VERBATIM — keep them in sync).
//
// Deliberately plain ASCII (plus one em-dash in the tagline, already used
// repo-wide): it must render cleanly in `brew` caveats and in non-TTY pipes, so
// there are NO ANSI colors/escapes here.

public enum Banner {
    /// The multiline banner, WITHOUT a trailing newline (callers add their own).
    /// A small padlock beside the "SESAME" wordmark + the tagline.
    public static let text = """
        .--.
       /    \\    S E S A M E
      |------|
      | (  ) |   Open sesame — one key, one touch
      |______|
    """
}
