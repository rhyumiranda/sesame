# AGENTS.md

Durable, project-intrinsic knowledge (curated by `/scribe`). Non-obvious facts that change future actions — not task notes.

## Maintaining this file

Keep only knowledge useful to almost every future agent session in this project.
Don't repeat what the code already shows — point to the file, function, or command instead.
Prefer rewriting or pruning an existing entry over adding a new one; skip trivial tasks that taught nothing durable.
Keep each entry to one line, action first.

- Write commit/PR messages as concrete action + purpose (conventional commits `type(scope): what changed and why`) — NEVER internal roadmap labels ("Phase 1", "Milestone 2", "Stage A", "task-2b"); they're inconsistent and unscannable, hiding what was done.
- Inside a ParsableCommand, call Foundation.exit(code) — bare exit() resolves to ArgumentParser's exit(withError:) and won't compile with an Int32.
- For 'NAME... -- cmd' parsing use one @Argument(parsing: .captureForPassthrough) and split on '--' yourself — .remaining eats the '--' terminator and .upToNextOption doesn't exist in swift-argument-parser.
- SMAppService.mainApp discovers a login item only when the .app lives in ~/Applications or /Applications — a bundle run from .build/ registers but never auto-launches; scripts/build-app.sh installs there for that reason.
- Ignore SIGPIPE process-wide (SIG_IGN) for any socket IO — on macOS SO_NOSIGPIPE set after accept does NOT stop a write to a peer that closed between accept and our write from killing the process (verified exit 141); UnixSocket.suppressSIGPIPE does both, a write to a dead peer then just returns EPIPE.
- Creating the Secure-Enclave key (SecKeyCreateRandomKey on kSecAttrTokenIDSecureEnclave) needs a REAL Developer-signed+entitled build — ad-hoc/unsigned fails errSecMissingEntitlement (-34018), so gate real-SE tests to XCTSkip on that error, never fail; all other SE logic runs headless via the fake EnclaveProvider seam.
- For the menu-bar status item use an AppKit NSStatusItem retained on the NSApplicationDelegate — SwiftUI MenuBarExtra icons hide behind the notch on notched Macs (unreachable UI), and a released NSStatusItem disappears.
- SesameApp is a windowed app: needs BOTH Info.plist LSUIElement=false (scripts/build-app.sh) AND NSApp.setActivationPolicy(.regular) in AppDelegate for the Dock icon + WindowGroup window — one without the other leaves no Dock icon/no visible window (it began as an LSUIElement agent).
- Agent command shims must be PATH-directory executable scripts (Sources/SesameCore/Shims.swift), never shell functions — agents run non-interactive shells that never source ~/.zshrc, so function shims silently never fire; each shim checks the env FIRST (skip fetch if the secret is already present) and execs the real binary by a baked-in ABSOLUTE path to avoid recursing into itself.
- Test home-dir writers via the URL/path-taking SesameCore seam (e.g. Setup.ensurePathLine(in:)), never by invoking `sesame setup`/`shim install` with a HOME= override — NSHomeDirectory() (used by Shims.dir() + the setup command) IGNORES $HOME on macOS and writes to the REAL ~/.zshrc / ~/.sesame.
