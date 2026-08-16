# 🔓 Sesame

> Open sesame — one key, one touch.

**Sesame** is a local, fingerprint-gated vault for the environment secrets your AI coding agents need. When Claude Code (or any agent) needs an API key, it asks Sesame; you approve with **Touch ID**; the secret is handed to that run only — never pasted, never left in plaintext, never synced off your Mac.

## Why

- Secrets scattered across `.env` files, chats, and shell history is fragile and risky.
- Password managers are built for *logins* (email + password you type into a site), not for *handing an environment variable to a program*.
- 1Password `op run` is the closest existing tool, but it's paid, cloud-backed, and session-based. Sesame is **free, local, and per-request**.

## How it works

- **Storage** — secrets live as macOS **Keychain** items, encrypted at rest, with the key gated by the **Secure Enclave**. Local only, never synced.
- **Encrypt, not hash** — secrets are *encrypted* (reversible), so they come back byte-for-byte. Touch ID doesn't unscramble anything itself: the fingerprint **authorizes** the Secure Enclave to use its key, and the Enclave **decrypts**.
- **Architecture** — a code-signed **Swift daemon** owns the Keychain, the Secure-Enclave key, and the Touch ID prompt; an **unsigned CLI client** (what the agent calls) talks to it over a Unix-domain socket. (A lone CLI can't hold biometric-Keychain entitlements — this is the Secretive model.)
- **Access policy — OPEN** — any process may ask; your fingerprint is the only gate. The prompt shows the caller's **verified code signature** (an impostor can't fake being `claude-code`), repeat prompts are rate-limited, and every request is logged.
- **Blast radius — one key** — each secret is its own Keychain item, so one approval releases *only* the requested key. Least privilege by default.
- **Injection** — approved secrets are injected into the child process's environment (`execve` / FIFO) — never written to disk.

## Status

Early. The design is locked; building toward a **Free MVP** (unsigned CLI + `LAContext` Touch ID gate + login-Keychain storage — $0, no Apple Developer account). A Secure-Enclave-hardened tier (signed daemon, SE key-wrap) comes later.

## Platform

macOS (Apple Silicon) · Touch ID / Secure Enclave.

---

*Not affiliated with any other "Sesame." Trademark / domain check pending.*
