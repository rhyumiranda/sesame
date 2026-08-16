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

    public var storageBackend: Backend
    public var dataSource: Source
    /// Agent listen/connect socket path. Absolute; `~` is expanded on load.
    public var agentSocket: String

    public init(storageBackend: Backend = .advisory,
                dataSource: Source = .agent,
                agentSocket: String = Paths.agentSocket().path) {
        self.storageBackend = storageBackend
        self.dataSource = dataSource
        self.agentSocket = agentSocket
    }

    private enum CodingKeys: String, CodingKey {
        case storageBackend = "storage_backend"
        case dataSource = "data_source"
        case agentSocket = "agent_socket"
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
