import Foundation
import SesameCore

/// Owns the agent socket for the menu-bar app's lifetime.
///
/// The app is the SIGNED agent (Secretive model): it owns the store the config
/// selects (Secure-Enclave vault or advisory Keychain), raises Touch ID via the
/// Enclave, and serves the `sesame` CLI over a Unix-domain socket. Starting it
/// here (not in the CLI) is deliberate — Touch ID only works inside the login
/// GUI session the app runs in, and only a signed app can verify a peer's code
/// signature.
@MainActor
final class AgentService: ObservableObject {
    @Published private(set) var statusText: String = "agent: starting…"

    let config: Config
    let store: StorageBackend
    private let server: AgentServer

    init(config: Config = .load()) {
        self.config = config
        let store = StoreFactory.local(config)
        self.store = store
        self.server = AgentServer(socketPath: config.agentSocket,
                                  store: store,
                                  verifier: SecCodePeerVerifier(),
                                  authTimeout: 60)

        // Surface a Touch ID approval for background socket `get`s. Without this
        // the Enclave decrypt is raised on the socket thread while Sesame is not
        // frontmost and macOS instant-denies it; the hook brings the app forward,
        // confirms with the user, and decrypts on the main thread. Core stays
        // AppKit-free — the UI lives in ReleaseApproval (SesameApp only).
        self.server.authorizeRelease = { name, requester, release in
            try ReleaseApproval.confirmAndRelease(name: name, requester: requester,
                                                  release: release)
        }
    }

    /// Start listening. Failure is surfaced (not fatal) — the menu-bar UI still
    /// works; only the CLI-as-client path is unavailable until it's fixed.
    func start() {
        do {
            try server.start()
            statusText = "agent: listening at \(config.agentSocket)"
        } catch let error as SesameError {
            statusText = "agent: not listening — \(error.message)"
        } catch {
            statusText = "agent: not listening — \(error.localizedDescription)"
        }
    }

    func stop() {
        server.stop()
        statusText = "agent: stopped"
    }
}
