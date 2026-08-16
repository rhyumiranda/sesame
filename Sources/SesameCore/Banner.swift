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
// there are NO ANSI colors/escapes here. Solid `#` block typography (figlet
// `banner`), ≤ 47 columns wide so it never wraps.

public enum Banner {
    /// The multiline banner, WITHOUT a trailing newline (callers add their own).
    /// A solid figlet-style SESAME wordmark above the tagline.
    public static let text = """
         #####  #######  #####     #    #     # #######
        #     # #       #     #   # #   ##   ## #
        #       #       #        #   #  # # # # #
         #####  #####    #####  #     # #  #  # #####
              # #             # ####### #     # #
        #     # #       #     # #     # #     # #
         #####  #######  #####  #     # #     # #######

                Open sesame — one key, one touch
        """
}
