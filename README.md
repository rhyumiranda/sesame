```
    .--.
   /    \    S E S A M E
  |------|
  | (  ) |   Open sesame — one key, one touch
  |______|
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
- **Free, local, no account.** The gate is a courtesy gate today; a hardware-locked (Secure-Enclave) tier and a menu-bar app are optional extras you can build from source.
- **Already-running or GUI-launched?** The shims won't be on its PATH, so use the fallback: `sesame exec -- <cmd>`.

---

Full design and details: [`docs/PRD.md`](docs/PRD.md) (local).
