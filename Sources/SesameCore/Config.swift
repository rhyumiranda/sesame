import Foundation

/// Persistent Sesame configuration (`~/Library/Application Support/Sesame/config.json`).
///
/// DEFAULTS DELIBERATELY PRESERVE STAGE-A BEHAVIOR: `storageBackend = .advisory`
/// and `dataSource = .agent`. Because `dataSource = .agent` FAILS SAFE to the
/// advisory local path when no agent socket is present (the common case until a
/// signed Secure-Enclave build is running), a fresh install behaves exactly like
/// Milestone 1 / Stage A. Flip `storageBackend` to `.secureEnclave` only after
/// the signed build is proven (see README §15).
public struct Config: Codable, Equatable, Sendable {
    /// Where the value lives: advisory login-Keychain (Stage A) or the
    /// cryptographic Secure-Enclave file vault (Stage B).
    public enum Backend: String, Codable, Sendable {
        case advisory
        case secureEnclave = "secure-enclave"
    }

    /// How the CLI reaches the store: through the signed agent over its socket,
    /// or directly on the local advisory path.
    public enum Source: String, Codable, Sendable {
        case agent
        case local
    }

    /// How a shimmed command decides WHICH secrets it may release.
    ///
    /// - `allowlist` (DEFAULT, unchanged for everyone): a command gets ONLY the
    ///   secrets its nearest `.sesame` `[commands]` rule maps; no rule → nothing
    ///   injected, the command runs bare. This is the safe, explicit model.
    /// - `open` (explicit opt-in, set once in the HOME config): drop the per-secret
    ///   allowlist. When no `[commands]` rule maps, Sesame resolves the likely
    ///   secret(s) itself (built-in provider map, else a vault fallback), shows
    ///   exactly what is about to be released in the Allow prompt, and one Touch ID
    ///   tap releases them. The user accepts the security tradeoff of no allowlist.
    public enum Access: String, Codable, Sendable {
        case allowlist
        case open
    }

    public var storageBackend: Backend
    public var dataSource: Source
    /// Agent listen/connect socket path. Absolute; `~` is expanded on load.
    public var agentSocket: String
    /// The secret-release model for shimmed commands. Defaults to `.allowlist`.
    public var access: Access

    public init(storageBackend: Backend = .advisory,
                dataSource: Source = .agent,
                agentSocket: String = Paths.agentSocket().path,
                access: Access = .allowlist) {
        self.storageBackend = storageBackend
        self.dataSource = dataSource
        self.agentSocket = agentSocket
        self.access = access
    }

    private enum CodingKeys: String, CodingKey {
        case storageBackend = "storage_backend"
        case dataSource = "data_source"
        case agentSocket = "agent_socket"
        case access = "access"
    }

    /// Decode leniently: any missing key falls back to its safe default, so an
    /// old/partial config file never breaks the CLI.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let def = Config()
        self.storageBackend = (try? c.decodeIfPresent(Backend.self, forKey: .storageBackend)) ?? def.storageBackend
        self.dataSource = (try? c.decodeIfPresent(Source.self, forKey: .dataSource)) ?? def.dataSource
        let sock = (try? c.decodeIfPresent(String.self, forKey: .agentSocket)) ?? def.agentSocket
        self.agentSocket = Config.expandTilde(sock)
        self.access = (try? c.decodeIfPresent(Access.self, forKey: .access)) ?? def.access
    }

    /// Load from `config.json`, or return defaults if it is absent/unreadable.
    /// Loading NEVER throws — a broken config must not brick the CLI.
    public static func load(url: URL = Paths.configFile()) -> Config {
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return config
    }

    /// Persist to `config.json` (pretty, stable key order). Creates the dir.
    public func save(url: URL = Paths.configFile()) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return (path as NSString).expandingTildeInPath
    }
}

/// Builds the LOCAL storage backend a config selects. Shared by the app (which
/// the agent serves from) and the CLI's local/fallback path, so both agree on
/// where secrets live. The advisory service name stays `dev.sesame` (the Stage-A
/// items the Milestone-1 CLI already uses).
public enum StoreFactory {
    public static func local(_ config: Config) -> StorageBackend {
        switch config.storageBackend {
        case .secureEnclave:
            return SecureEnclaveStore(provider: RealEnclaveProvider())
        case .advisory:
            return KeychainStore(service: "dev.sesame")
        }
    }
}
