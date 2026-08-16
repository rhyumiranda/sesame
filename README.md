# Sesame

**Open sesame — one key, one touch.**

Sesame is a fingerprint-gated vault for the environment secrets your AI agents (and everything else on your Mac) need at runtime. Store an API key once, and every read is gated behind Touch ID — the bare value goes straight to stdout or into a child process's environment, never onto disk in plaintext or into your shell history. It ships as both a `sesame` CLI and a windowed macOS app.

## Features

- **Fingerprint-gated env-secret vault** — secrets are read behind a Touch ID prompt and injected into a command's environment, so keys never live in dotfiles or shell history.
- **CLI *and* a windowed macOS app** — script it from the terminal, or use the native app (Dock icon + window) for reveal/copy.
- **Advisory gate today, cryptographic tier available** — an advisory Touch ID gate by default, with a Secure-Enclave–backed cryptographic tier that unlocks behind a signed build (dormant by default).

## Install

```sh
swift build                 # build the sesame CLI
bash scripts/build-app.sh   # build + install the windowed app to ~/Applications/Sesame.app
```

## Usage

### CLI

```sh
printf '%s' "$OPENAI_API_KEY" | sesame add OPENAI_API_KEY   # store (value via stdin, never argv)
export OPENAI_API_KEY="$(sesame get OPENAI_API_KEY)"        # Touch ID -> bare value on stdout
sesame run OPENAI_API_KEY -- ./deploy.sh                    # inject into a child's env, then run
sesame ls                                                   # list names + metadata (never values)
sesame rm OPENAI_API_KEY --confirm                          # delete (permanent, needs --confirm)
sesame log --limit 20                                       # show the access log, newest-first
```

### Windowed app

```sh
open ~/Applications/Sesame.app
```

## Security

Sesame's default gate is **advisory**: it prompts for Touch ID before releasing a secret, but the gate is not itself cryptographic. A **Secure-Enclave** tier wraps each secret so the value is unrecoverable without a successful biometric unlock — it is cryptographic but requires a signed build, and is **dormant by default**.

## Platform

macOS on Apple Silicon.

---

The full design doc / PRD lives in `docs/PRD.md` (local-only, gitignored).
