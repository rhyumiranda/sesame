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
sesame init                 # 2. in your project, list the secret NAMES it needs
sesame setup                # 3. turn on auto-injection once (puts the shims on your PATH)
```

Then run your agent or commands **normally** — no wrapping, no prefixes. When something needs a secret, you get **one Touch ID tap** and it's injected. That's it.

## Example

```sh
cd your-project
sesame init          # add NPM_TOKEN to the .sesame file
npm publish          # → one Touch ID tap → NPM_TOKEN is injected → it works
```

Launch your agent the same way (just `claude`, or `canopy start`). You don't wrap or prefix anything.

## Good to know

- **Your agent never sees Sesame.** The secret goes into the program's environment, not the chat.
- **One fingerprint per secret, only when it's actually used.** Every request is logged.
- **Background & headless agents work too.** A request from a tool that isn't the front app brings Sesame forward, shows an **Allow / Deny** prompt naming who's asking and for which key, then takes your tap. Deny releases nothing.
- **Free, local, no account.** The gate is a courtesy gate today; a hardware-locked (Secure-Enclave) tier and a menu-bar app are optional extras you can build from source.
- **Already-running or GUI-launched?** The shims won't be on its PATH, so use the fallback: `sesame exec -- <cmd>`.

## Open mode — thumb is the only action

By default Sesame is **allowlist** mode: a command only gets the secrets its
`.sesame` `[commands]` rule maps, so you decide up front exactly what each tool
can touch. Open mode drops that list — **your only action is the tap.**

```sh
sesame open          # switch to open mode + install shims for the known tools
                     # ('sesame open --off' returns to the allowlist default)
```

In open mode a shimmed command needs **no `.sesame` and no per-command map**.
When it runs, Sesame picks the secret(s) it needs, shows them in the Allow
prompt, and **one Touch ID tap** releases and injects them:

- **Known tools** use a built-in provider map — `doctl → DIGITALOCEAN_ACCESS_TOKEN`,
  `aws → AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY`, `gh → GH_TOKEN`,
  `heroku → HEROKU_API_KEY`, `stripe → STRIPE_API_KEY`, `vercel → VERCEL_TOKEN`,
  `netlify → NETLIFY_AUTH_TOKEN`, `npm → NPM_TOKEN`,
  `gcloud → GOOGLE_APPLICATION_CREDENTIALS`, and more. Only names you've actually
  stored are released — an absent one is skipped, never an error.
- **A tool Sesame doesn't know** gets the vault secret whose name mentions it
  (e.g. `mytool → MYTOOL_TOKEN`); if nothing matches, open means the whole vault
  is a candidate for that command — the Allow prompt lists **every** name so you
  can Deny.
- **Custom tool?** `sesame shim install --commands <tool>` adds a shim; open mode
  resolves it at run time.

Open mode **never dumps secrets silently**: before each tap it prints the count
and names it's about to release, every release is logged, and denying releases
nothing. The tradeoff you accept: the tap alone gates release — there's no
pre-approved allowlist. It's a global, one-time choice (stored in the HOME
config); everyone who hasn't run `sesame open` keeps the strict default.

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
