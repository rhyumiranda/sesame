# AGENTS.md

Durable, project-intrinsic knowledge (curated by `/scribe`). Non-obvious facts that change future actions — not task notes.

## Maintaining this file

Keep only knowledge useful to almost every future agent session in this project.
Don't repeat what the code already shows — point to the file, function, or command instead.
Prefer rewriting or pruning an existing entry over adding a new one; skip trivial tasks that taught nothing durable.
Keep each entry to one line, action first.

- Inside a ParsableCommand, call Foundation.exit(code) — bare exit() resolves to ArgumentParser's exit(withError:) and won't compile with an Int32.
- For 'NAME... -- cmd' parsing use one @Argument(parsing: .captureForPassthrough) and split on '--' yourself — .remaining eats the '--' terminator and .upToNextOption doesn't exist in swift-argument-parser.
- SMAppService.mainApp discovers a login item only when the .app lives in ~/Applications or /Applications — a bundle run from .build/ registers but never auto-launches; scripts/build-app.sh installs there for that reason.
- Ignore SIGPIPE process-wide (SIG_IGN) for any socket IO — on macOS SO_NOSIGPIPE set after accept does NOT stop a write to a peer that closed between accept and our write from killing the process (verified exit 141); UnixSocket.suppressSIGPIPE does both, a write to a dead peer then just returns EPIPE.
- Creating the Secure-Enclave key (SecKeyCreateRandomKey on kSecAttrTokenIDSecureEnclave) needs a REAL Developer-signed+entitled build — ad-hoc/unsigned fails errSecMissingEntitlement (-34018), so gate real-SE tests to XCTSkip on that error, never fail; all other SE logic runs headless via the fake EnclaveProvider seam.
