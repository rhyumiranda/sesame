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
sesame exec -- ./deploy.sh                                  # inject the project's .sesame secrets, then run
sesame ls                                                   # list names + metadata (never values)
sesame rm OPENAI_API_KEY --confirm                          # delete (permanent, needs --confirm)
sesame log --limit 20                                       # show the access log, newest-first
```

### Windowed app

```sh
open ~/Applications/Sesame.app
```

## Agent env integration

Let an AI agent (Claude Code, etc.) source env secrets from Sesame **without knowing Sesame exists** — you declare once per project which secrets are needed; each is injected into a command's environment behind a Touch ID prompt for that specific secret. Values go into the process env only (never disk, argv, the access log, or the agent's transcript).

### The `.sesame` manifest

A `.sesame` file at your project root lists secret **names** (safe to commit — names only, never values). The loader uses the **nearest** `.sesame` walking up from the current directory.

```sh
# .sesame — names only; safe to commit
NPM_TOKEN
OPENAI_API_KEY

# Optional: map a command prefix to only the secrets it needs.
# Longest (most-specific) match wins; a command with no mapping runs unchanged.
[commands]
npm publish: NPM_TOKEN
gh: GH_TOKEN
```

- One secret **name** per line; `#` starts a comment (whole-line or trailing).
- `[commands]` section: `COMMAND: SECRET [SECRET…]`. `COMMAND` matches the first N whitespace-separated words of the invoked command (extra flags are ignored); the **most-specific** rule wins (`npm publish: …` beats `npm: …`).
- Edge cases fail safe with a clear message: no manifest → suggests `sesame init`; duplicate name → line numbers; a name not in the vault → names it + lists stored names; malformed line → the line + why.

`sesame init` scaffolds one.

### Two ways to inject

**`sesame exec` (quiet, batch pre-load)** — resolve ALL the manifest's declared secrets in one launch-time step and run a command with them present. Anything that command spawns inherits them:

```sh
sesame exec -- claude       # launch the agent with the project's secrets already in its env
sesame exec -- ./deploy.sh
```

**Shims (on-demand, per-secret)** — install PATH-directory wrapper scripts so a specific command pulls only the secret(s) it needs, exactly when it runs:

```sh
sesame shim install                 # shim the commands mapped in .sesame
sesame shim install --commands npm,gh
export PATH="$HOME/.sesame/shims:$PATH"   # prepend — INCLUDING in your agent's environment
```

Now when the agent runs `npm publish`, the shim sees `NPM_TOKEN` is absent → one Touch ID for `NPM_TOKEN` → injected → the real `npm` runs. The agent is never asked; the value never enters the transcript. `sesame shim uninstall` removes them.

**How the shims stay safe and correct**

- **PATH-directory executable scripts, not shell functions.** Agents run commands in non-interactive/non-login shells that never source `~/.zshrc`/`~/.bashrc`, so a shell-function shim would silently never fire. A PATH-dir shim always intercepts.
- **Env-check first.** A shim only prompts when its mapped secret is *absent or empty* in the environment. If it's already present (e.g. you pre-loaded via `sesame exec`), the shim just runs the real binary — no prompt.
- **No recursion.** At install time each command's real absolute path is resolved with `~/.sesame/shims` excluded, then baked into the shim; the shim `exec`s that absolute path, so it never re-hits itself. If the real binary moves, re-run `sesame shim install`.
- **Unmapped commands run unchanged** (no prompt); a missing or malformed `.sesame` falls back to a plain passthrough.

### Wire up an agent (Claude Code, etc.)

```sh
cd your-project
sesame init                                   # scaffold .sesame
# edit .sesame: list NPM_TOKEN etc. + optional [commands] mappings
printf '%s' "$NPM_TOKEN" | sesame add NPM_TOKEN   # store the value once (Touch ID gates reads)
sesame shim install                           # generate shims for the mapped commands
export PATH="$HOME/.sesame/shims:$PATH"        # ensure the AGENT's env has this on PATH too
```

Then just let the agent work: a shimmed command that needs a secret raises one Touch ID prompt for that secret when it runs.

**Prompt frequency (honest):** with on-demand shims, an agent that spawns a fresh shell per command re-prompts once per such command for a not-yet-loaded secret (the rate limiter is per-process; there is no cross-process cache in the advisory tier). To avoid the prompt storm, launch the agent (or a shell) once via `sesame exec -- <agent>` so every shimmed command inherits the secret and skips prompting. A short-TTL cross-process grant cache is a future enhancement of the signed agent path — Sesame deliberately does **not** write a plaintext on-disk cache.

## Security

Sesame's default gate is **advisory**: it prompts for Touch ID before releasing a secret, but the gate is not itself cryptographic. A **Secure-Enclave** tier wraps each secret so the value is unrecoverable without a successful biometric unlock — it is cryptographic but requires a signed build, and is **dormant by default**.

## Platform

macOS on Apple Silicon.

---

The full design doc / PRD lives in `docs/PRD.md` (local-only, gitignored).
