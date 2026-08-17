```
 #####  #######  #####     #    #     # #######
#     # #       #     #   # #   ##   ## #
#       #       #        #   #  # # # # #
 #####  #####    #####  #     # #  #  # #####
      # #             # ####### #     # #
#     # #       #     # #     # #     # #
 #####  #######  #####  #     # #     # #######

        Open sesame — one key, one touch
```

# 🔓 Sesame

**Open sesame — one key, one touch.**

Sesame keeps your API keys in one place and hands them to your tools and AI agents only after a fingerprint tap. Keys are never pasted, never left in plaintext, never in your shell history.

## Install

```sh
brew install rhyumiranda/tap/sesame
```

macOS on Apple Silicon.

## Use it in 3 steps

```sh
sesame add OPENAI_API_KEY   # 1. store a secret (paste the value; it's read from stdin)
sesame open                 # 2. turn on tap-only mode + shims for the tools it knows
sesame setup                # 3. put the shims on your PATH (once)
```

That's the whole setup — **no allowlist file to write.** Now run your agent or
commands **normally** (no wrapping, no prefixes). When something needs a secret,
Sesame shows you exactly what it's about to release and takes **one Touch ID
tap** — then injects it. Your thumb is the only gate.

**No terminal?** The desktop app does steps 2 + 3 for you: open **Settings →
Tap-only injection → Enable** and it installs the shims, turns on tap-only mode,
and adds the shims dir to your PATH (open a new terminal for the PATH change to
land). The same panel shows the current state and a **Turn off** button that
reverses all three. It needs the `sesame` CLI installed (the shims call it).

## Example

```sh
cd your-project
npm publish          # → "releasing 1 secret: NPM_TOKEN" → one Touch ID tap → it works
gh pr create         # → GH_TOKEN released on a tap → it works
```

Launch your agent the same way (just `claude`, or `canopy start`) — you don't
wrap or prefix anything. Any tool Sesame shims picks up the key it needs on a tap.

**No setup at all? Name the key inline.** `sesame run` reaches any stored secret
behind a tap with zero config — no `sesame open`, no `.sesame`:

```sh
sesame run OPENAI_API_KEY -- python train.py   # tap → OPENAI_API_KEY injected → runs
sesame get OPENAI_API_KEY                       # tap → prints the bare value on stdout
```

## Wire agent secret lookup rules

`sesame agents` adds a managed instruction block to Codex/Claude files so agents
know how to ask Sesame for secrets without leaking values.

```sh
sesame agents install          # installed global agent dirs only
sesame agents install --project # git repo root AGENTS.md
sesame agents install --all     # installed globals + repo root AGENTS.md
sesame agents doctor --json
sesame agents uninstall
```

The block is bounded by `<!-- sesame-agents:start -->` and
`<!-- sesame-agents:end -->`. Re-running updates that one block, never duplicates
it; uninstall removes only that block. By default, global commands touch only
known installed agent locations (`~/.codex/AGENTS.md` or `~/.claude/CLAUDE.md`
when that file or parent agent dir exists), so Sesame does not create both global
files on a fresh machine. JSON output reports paths and actions, never secret
values.

## How a key reaches a command

**The tap is the only action.** After `sesame open`, a shimmed command needs no
`.sesame` and no per-command map. When it runs, Sesame figures out which
secret(s) it needs, shows them in the Allow prompt, and one Touch ID tap releases
and injects them:

- **Known tools** use a built-in provider map — `doctl → DIGITALOCEAN_ACCESS_TOKEN`,
  `aws → AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY`, `gh → GH_TOKEN`,
  `heroku → HEROKU_API_KEY`, `stripe → STRIPE_API_KEY`, `vercel → VERCEL_TOKEN`,
  `netlify → NETLIFY_AUTH_TOKEN`, `npm → NPM_TOKEN`,
  `gcloud → GOOGLE_APPLICATION_CREDENTIALS`, and more. Only names you've actually
  stored are released — an absent one is skipped, never an error.
- **A tool Sesame doesn't know** gets the vault secret whose name mentions it
  (e.g. `mytool → MYTOOL_TOKEN`); if nothing matches, the whole vault is a
  candidate for that command — the Allow prompt lists **every** name so you can Deny.
- **Custom tool?** `sesame shim install --commands <tool>` adds a shim; tap-only
  mode resolves it at run time.

Sesame **never dumps secrets silently**: before each tap it prints the count and
names it's about to release, every release is logged, and denying releases
nothing. Tap-only mode is a global, one-time choice (stored in the HOME config);
`sesame open --off` returns to the stricter allowlist model below.

### Prefer to pre-approve? Use the `.sesame` allowlist (opt-in)

If you'd rather decide up front exactly which keys each tool can touch, skip
`sesame open` and use an **allowlist** — the built-in default. Scaffold one with
`sesame init`, then list the secret NAMES the project uses (and, optionally, map
a command to just the secrets it needs):

```
# .sesame — names only, safe to commit
NPM_TOKEN
GH_TOKEN

[commands]
npm publish: NPM_TOKEN
gh: GH_TOKEN
```

In allowlist mode a shimmed command gets **only** the secrets its `[commands]`
rule maps; a command with no rule runs unchanged (no prompt). To launch a whole
agent/shell with every declared secret preloaded in one step, use
`sesame exec -- <cmd>`.

## Good to know

- **Your agent never sees Sesame.** The secret goes into the program's environment, not the chat.
- **One fingerprint per secret, only when it's actually used.** Every request is logged.
- **Background & headless agents work too.** A request from a tool that isn't the front app brings Sesame forward, shows an **Allow / Deny** prompt naming who's asking and for which key, then takes your tap. Deny releases nothing.
- **Free, local, no account.** The gate is a courtesy gate today; a hardware-locked (Secure-Enclave) tier and a menu-bar app are optional extras you can build from source.
- **Shims not on a program's PATH** (already-running or GUI-launched)? Use the config-free fallback: `sesame run <NAME> -- <cmd>`.

## Enable Touch ID (Developer ID build)

Out of the box Sesame runs on the **advisory** tier (a login-password courtesy
gate). The hardware-locked **Secure-Enclave** tier — a real Touch ID tap per
secret — needs a build signed with a paid **Developer ID Application**
certificate. macOS only honors the biometric/keychain entitlement under a
Developer-ID (or provisioned) signature that authorizes a **team-prefixed**
keychain access group; an ad-hoc or bare Apple-Development build fails with
`-34018` on add / error `163` on launch. Developer ID needs **no provisioning
profile and never expires**.

Once the company Developer ID Application cert is installed in your keychain:

```sh
# 1. Build + install a signed app. The team id is DERIVED from the identity and
#    substituted into the entitlement — nothing is hardcoded.
SESAME_SIGN_ID="Developer ID Application: <Company> (TEAMID)" scripts/build-app.sh

# 2. Confirm the entitlement landed (expect keychain-access-groups
#    = TEAMID.dev.sesame.app, sandbox=false, runtime flag set):
codesign -d --entitlements - ~/Applications/Sesame.app

# 3. Launch it, then switch the backend to the Secure Enclave:
open ~/Applications/Sesame.app
#    in ~/Library/Application Support/Sesame/config.json set:
#        "storage_backend": "secure-enclave"     (data_source stays "agent")
#    relaunch the app so the agent owns the SE key.

# 4. Re-wrap your existing advisory secrets into the Enclave (Touch ID per secret).
#    The advisory copies are LEFT INTACT until you verify:
sesame migrate
sesame run SOME_SECRET -- printenv SOME_SECRET   # → Allow/Deny → Touch ID → value
sesame rm SOME_SECRET --advisory --confirm       # drop the old copy once verified
```

The shipped default stays advisory — no cert, no change. The steps above are the
opt-in upgrade to the cryptographic tier.

---

Full design and details: [`docs/PRD.md`](docs/PRD.md) (local).
