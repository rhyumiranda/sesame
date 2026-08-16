# Homebrew packaging

`sesame.rb` here is the **canonical, reviewed** Homebrew formula. Users install
via a tap:

```sh
brew install rhyumiranda/tap/sesame
```

That resolves to the repo `rhyumiranda/homebrew-tap`, file `Formula/sesame.rb`.
This directory's copy is the source of truth; the tap copy is a mirror.

## Why a formula (not a cask)

The formula installs the **`sesame` CLI only** — the whole onboarding
(`sesame add` -> `sesame init` -> `sesame exec`) works CLI-only. The menu-bar
app is a separate `.app` bundle (that would be a cask, out of scope) and is
built from source with `bash scripts/build-app.sh`.

## Build model

Build-from-source with the Swift toolchain from the **Command Line Tools** — no
full Xcode. `install` runs `swift build --disable-sandbox -c release` and
installs the arch-specific product via
`Dir.glob(".build/*/release/sesame").first` (the release binary lives at
`.build/<triple>/release/sesame`, never a bare `.build/release/sesame`).

The formula **must keep `--disable-sandbox`**: SwiftPM runs its own sandbox
nested inside Homebrew's build sandbox, and that nesting fails with
`sandbox-exec: sandbox_apply: Operation not permitted` — `brew install` breaks
without the flag.

## Publishing a release (manual, run by the maintainer)

The `sha256` cannot be known until the tag's tarball exists, so it is a
`PLACEHOLDER_SHA256` here until publish. After `release-please` tags `vX.Y.Z`:

1. Download the release tarball and hash it:
   ```sh
   VERSION=X.Y.Z
   curl -sL "https://github.com/rhyumiranda/sesame/archive/refs/tags/v${VERSION}.tar.gz" -o sesame.tar.gz
   shasum -a 256 sesame.tar.gz
   ```
2. In `packaging/homebrew/sesame.rb`, update:
   - `url` -> the `v${VERSION}` tarball,
   - `sha256` -> the hash from step 1.
   (Homebrew derives `version` from the `url` tag, so there is no separate
   `version` line to bump.)
3. Mirror the updated `sesame.rb` to `rhyumiranda/homebrew-tap` as
   `Formula/sesame.rb`, commit, and push. `brew install rhyumiranda/tap/sesame`
   now builds the new version.
4. Verify: `brew install --build-from-source rhyumiranda/tap/sesame` then
   `sesame --version` should print `sesame ${VERSION}`.

## Future nice-to-have

Automate steps 1-3 with a GitHub Action triggered on the release tag (compute
the sha256, patch `sesame.rb`, and open a PR / push to the tap repo) so releases
stay installable without a manual bump. Not wired up yet — the process above is
the current source of truth.
