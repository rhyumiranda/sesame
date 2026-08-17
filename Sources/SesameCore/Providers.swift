import Foundation

// MARK: - Built-in provider map (OPEN mode)
//
// In ALLOWLIST mode (the default) a shimmed command gets ONLY the secrets its
// `.sesame` `[commands]` rule maps — this map is never consulted.
//
// In OPEN mode, when a shimmed command has NO `[commands]` rule, Sesame has no
// per-command allowlist to read, so it infers the likely secret(s) itself:
//   1. A KNOWN tool (in `map`) releases its mapped name(s) that ACTUALLY EXIST in
//      the vault — absent ones are skipped silently (never an error, never a
//      full-vault dump). A known tool with none of its names stored injects
//      nothing and the command runs bare.
//   2. An UNKNOWN tool is inferred by NAME: any vault secret whose name mentions
//      the tool (case-insensitive) is a candidate — e.g. `mytool` → `MYTOOL_TOKEN`.
//   3. If nothing can be inferred, OPEN means FULL-VAULT access for that command:
//      every stored name is a candidate. The Allow prompt lists exactly what is
//      about to be released so the tap is still a real, informed gate.
//
// `resolve` NEVER returns a name that is not in `vault`, so the caller can inject
// its result directly without a second existence check.

public enum Providers {
    /// Command name → the secret name(s) the tool conventionally reads from its
    /// environment. Keyed by the BARE command (the shim name), lowercased.
    public static let map: [String: [String]] = [
        "doctl":      ["DIGITALOCEAN_ACCESS_TOKEN"],
        "aws":        ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"],
        "gh":         ["GH_TOKEN"],
        "heroku":     ["HEROKU_API_KEY"],
        "stripe":     ["STRIPE_API_KEY"],
        "vercel":     ["VERCEL_TOKEN"],
        "netlify":    ["NETLIFY_AUTH_TOKEN"],
        "npm":        ["NPM_TOKEN"],
        "gcloud":     ["GOOGLE_APPLICATION_CREDENTIALS"],
        "fly":        ["FLY_API_TOKEN"],
        "flyctl":     ["FLY_API_TOKEN"],
        "railway":    ["RAILWAY_TOKEN"],
        "wrangler":   ["CLOUDFLARE_API_TOKEN"],
        "cloudflare": ["CLOUDFLARE_API_TOKEN"],
        "supabase":   ["SUPABASE_ACCESS_TOKEN"],
        "sentry-cli": ["SENTRY_AUTH_TOKEN"],
        "glab":       ["GITLAB_TOKEN"],
        "openai":     ["OPENAI_API_KEY"],
    ]

    /// The commands the built-in map knows about (for `shim install --known` and
    /// OPEN-mode auto-shimming during `sesame setup`). Sorted for stable output.
    public static var knownCommands: [String] { map.keys.sorted() }

    /// Resolve the secret name(s) an OPEN-mode shimmed command should release,
    /// given the full command token list (binary name first) and the names in the
    /// vault. Returns names in a STABLE order and ONLY names present in `vault`.
    ///
    /// See the file header for the three-step precedence (known map → name-infer →
    /// full vault). Returns `[]` only when the vault is empty or a known tool has
    /// none of its names stored — in both cases the command runs bare.
    public static func resolve(command: [String], vault: [String]) -> [String] {
        guard let raw = command.first, !raw.isEmpty else { return [] }
        let tool = raw.lowercased()
        let vaultSet = Set(vault)

        // 1. Known tool → its mapped names that are actually stored (order preserved).
        if let mapped = map[tool] {
            return mapped.filter { vaultSet.contains($0) }
        }

        // 2. Unknown tool → infer by name. NOTE (by design, do NOT tighten): this is
        //    case-insensitive SUBSTRING matching, so it may return MULTIPLE candidates
        //    — e.g. `git` matches GIT_TOKEN, GITHUB_TOKEN, GITLAB_TOKEN… Open mode is
        //    intentionally broad; every candidate is surfaced in the Allow prompt and
        //    each release is gated by an explicit tap, so breadth here never releases
        //    anything the user didn't see and approve. Multi-key tools (e.g. aws → 2
        //    keys) rely on this returning more than one name.
        let needle = tool.uppercased()
        let inferred = vault.filter { $0.uppercased().contains(needle) }
        if !inferred.isEmpty { return inferred }

        // 3. Uninferable → OPEN = full-vault access for this command. The Allow
        //    prompt lists every name so the user still sees and can Deny each.
        return vault
    }
}
