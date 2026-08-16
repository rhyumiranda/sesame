# Homebrew formula for the Sesame CLI (build-from-source, Swift).
#
# CANONICAL COPY, versioned + reviewed here. The PUBLISHED tap lives at
# rhyumiranda/homebrew-tap as Formula/sesame.rb — mirror every change there.
# The url/sha256/version bump on each release is documented in
# packaging/homebrew/README.md (the sha256 can only be computed after the tag
# exists, so it is a PLACEHOLDER here and the publisher fills it in).
class Sesame < Formula
  desc "Fingerprint-gated vault for your AI agent's env secrets"
  homepage "https://github.com/rhyumiranda/sesame"
  url "https://github.com/rhyumiranda/sesame/archive/refs/tags/v0.4.0.tar.gz"
  sha256 "PLACEHOLDER_SHA256"
  license "MIT"

  # Builds with the Swift toolchain shipped in the Command Line Tools — NO full
  # Xcode (verified: `swift build -c release` succeeds under CLT alone). Adding
  # `depends_on xcode: :build` would force the ~11GB IDE for no benefit.
  depends_on :macos

  def install
    # --disable-sandbox: SwiftPM's own sandbox fails inside Homebrew's build sandbox
    system "swift", "build", "--disable-sandbox", "-c", "release"
    # Arch-safe: the product lives at .build/<triple>/release/sesame, never a
    # bare .build/release/sesame.
    bin.install Dir.glob(".build/*/release/sesame").first
  end

  def caveats
    <<~EOS
       #####  #######  #####     #    #     # #######
      #     # #       #     #   # #   ##   ## #
      #       #       #        #   #  # # # # #
       #####  #####    #####  #     # #  #  # #####
            # #             # ####### #     # #
      #     # #       #     # #     # #     # #
       #####  #######  #####  #     # #     # #######

              Open sesame — one key, one touch

      Sesame guards your agent's env secrets behind Touch ID. Two steps to go:
        1. sesame add OPENAI_API_KEY          # store a secret (value read from stdin)
        2. cd your-project && sesame init     # declare the secret NAMES this project needs
      then launch your agent with them present:
        sesame exec -- claude

      Shims (optional): sesame setup          # put ~/.sesame/shims on PATH for on-demand shims

      brew installs the CLI only. The menu-bar app + the Secure-Enclave tier are
      optional extras built from source (bash scripts/build-app.sh).
    EOS
  end

  test do
    assert_match "sesame #{version}", shell_output("#{bin}/sesame --version")
  end
end
