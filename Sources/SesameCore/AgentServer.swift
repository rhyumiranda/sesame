import Foundation
import Security
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Peer identity

/// The connecting peer, as the agent derives it from the socket. `signature` is
/// what the Touch ID prompt shows and the log records: a real code-signing
/// identifier for a signed peer, or `unsigned:<path>:<pid>` for an unsigned one.
public struct PeerIdentity: Sendable {
    public var pid: pid_t
    public var signature: String
    public var isSigned: Bool

    public init(pid: pid_t, signature: String, isSigned: Bool) {
        self.pid = pid
        self.signature = signature
        self.isSigned = isSigned
    }
}

/// Derives the peer identity for a connected socket fd. Behind a protocol so the
/// agent's request handling is unit-testable with a fake peer (no real process
/// to sign).
public protocol PeerVerifier: Sendable {
    func identify(fd: Int32) throws -> PeerIdentity
}

/// The real verifier (pinned decision #7, OPEN policy): read the peer PID
/// (`LOCAL_PEERPID`), then derive its VERIFIED code signature
/// (`SecCodeCopyGuestWithAttributes` by pid → `SecCodeCopySigningInformation`).
/// Signed → the verified identifier; unsigned → flagged `unsigned:<path>:<pid>`
/// (ALLOWED but clearly flagged, never silently trusted, never auto-approved).
/// Only meaningful on a signed agent build; compiles everywhere.
public struct SecCodePeerVerifier: PeerVerifier {
    public init() {}

    public func identify(fd: Int32) throws -> PeerIdentity {
        var pid: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let rc = getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len)
        guard rc == 0, pid > 0 else {
            throw SesameError.io("could not read peer pid")
        }

        // Executable path — reliable regardless of signing.
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLen > 0 ? String(cString: pathBuffer) : "?"

        let attrs: [CFString: Any] = [kSecGuestAttributePid: NSNumber(value: pid)]
        var code: SecCode?
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attrs as CFDictionary, [], &code)
        if guestStatus == errSecSuccess, let code = code {
            var staticCode: SecStaticCode?
            SecCodeCopyStaticCode(code, [], &staticCode)
            if let staticCode = staticCode {
                var info: CFDictionary?
                let infoStatus = SecCodeCopySigningInformation(
                    staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                if infoStatus == errSecSuccess,
                   let dict = info as? [String: Any],
                   let identifier = dict[kSecCodeInfoIdentifier as String] as? String,
                   !identifier.isEmpty {
                    return PeerIdentity(pid: pid, signature: identifier, isSigned: true)
                }
            }
        }
        return PeerIdentity(pid: pid, signature: "unsigned:\(path):\(pid)", isSigned: false)
    }
}

// MARK: - Agent server

/// The signed menu-bar app's agent. Listens on a Unix-domain socket, verifies
/// each peer, SERIALIZES Touch ID (one prompt at a time; concurrent `get`s queue
/// with a per-request timeout — pinned decision #6), and serves requests against
/// the owned `StorageBackend`.
public final class AgentServer {
    private let socketPath: String
    private let store: StorageBackend
    private let log: AccessLog
    private let verifier: PeerVerifier
    /// Max time a queued request waits for its turn at the (serialized) Touch ID
    /// gate before returning `timeout`. 60 s in production; tiny in tests.
    private let authTimeout: TimeInterval

    /// Binary semaphore = "one Touch ID prompt at a time". A queued request that
    /// can't acquire it within `authTimeout` returns `{ok:false,error:"timeout"}`.
    private let gate = DispatchSemaphore(value: 1)

    /// App-injected release authorizer, called INSIDE the serialized gate BEFORE
    /// the value is released. The app (SesameApp) sets this to bring Sesame
    /// frontmost, confirm Allow/Deny with the user, and — on Allow — run the
    /// supplied `release` (the Touch ID-gated decrypt) on the MAIN THREAD while
    /// the app is active. This matters because a background socket `get` arriving
    /// while Sesame is not frontmost is INSTANT-denied: macOS won't present Touch
    /// ID for a decrypt raised off the main thread of a non-frontmost app. The
    /// known-good in-app reveal path is "main thread + app active", so the app
    /// replicates exactly that here.
    ///
    /// Contract: return the released bytes to proceed; return `nil` to deny (the
    /// user pressed Deny) → `handleGet` logs `denied` and never releases; rethrow
    /// `release`'s error to surface the normal wire error (notfound/denied/…).
    ///
    /// Default `nil` keeps headless/core behavior: `release` runs inline on the
    /// socket thread with no prompt, so every existing SesameCore test and the
    /// CLI-only advisory path are unchanged. SesameCore stays AppKit-free — the
    /// UI lives entirely in the app-provided closure.
    public var authorizeRelease: ((_ name: String, _ requester: String,
                                   _ release: () throws -> Data) throws -> Data?)?

    private var listenFD: Int32 = -1
    private var running = false
    private let acceptQueue = DispatchQueue(label: "dev.sesame.agent.accept")
    private let connQueue = DispatchQueue(label: "dev.sesame.agent.conn", attributes: .concurrent)

    public init(socketPath: String = Paths.agentSocket().path,
                store: StorageBackend,
                log: AccessLog = AccessLog(),
                verifier: PeerVerifier = SecCodePeerVerifier(),
                authTimeout: TimeInterval = 60) {
        self.socketPath = socketPath
        self.store = store
        self.log = log
        self.verifier = verifier
        self.authTimeout = authTimeout
    }

    // MARK: Lifecycle

    public func start() throws {
        let dir = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(socketPath) // clear a stale socket from a prior run

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SesameError.io("agent socket() failed") }
        var addr = try UnixSocket.makeAddr(path: socketPath)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindRC = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bindRC == 0 else {
            close(fd)
            throw SesameError.io("agent bind() failed at \(socketPath) (errno \(errno))")
        }
        chmod(socketPath, 0o600) // socket user-only
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw SesameError.io("agent listen() failed")
        }
        listenFD = fd
        running = true
        acceptQueue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        running = false
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    private func acceptLoop() {
        while running {
            let clientFD = accept(listenFD, nil, nil)
            if clientFD < 0 {
                if running { continue } else { break }
            }
            UnixSocket.suppressSIGPIPE(clientFD)
            connQueue.async { [weak self] in self?.serve(clientFD) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        guard let body = UnixSocket.readFrame(fd),
              let request = try? JSONDecoder().decode(AgentRequest.self, from: body) else {
            respond(fd, .failure("bad request"))
            return
        }
        let peer: PeerIdentity
        do {
            peer = try verifier.identify(fd: fd)
        } catch {
            peer = PeerIdentity(pid: 0, signature: "unknown", isSigned: false)
        }
        respond(fd, handle(request, peer: peer))
    }

    private func respond(_ fd: Int32, _ response: AgentResponse) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        UnixSocket.writeFrame(fd, data)
    }

    // MARK: Request handling (unit-testable without a socket)

    /// Handle one request against the store. `get` runs behind the serialized
    /// Touch ID gate; `list`/`add`/`delete` do not prompt.
    public func handle(_ request: AgentRequest, peer: PeerIdentity) -> AgentResponse {
        switch request.op {
        case "list":  return handleList(peer: peer)
        case "get":   return handleGet(request, peer: peer)
        case "add":   return handleAdd(request, peer: peer)
        case "delete": return handleDelete(request, peer: peer)
        default:      return AgentResponse.failure("unknown op '\(request.op)'")
        }
    }

    private func handleList(peer: PeerIdentity) -> AgentResponse {
        do {
            let infos = try store.list().map {
                AgentSecretInfo(name: $0.name, createdAt: $0.createdAt,
                                lastUsedAt: $0.lastUsedAt, lastUsedBy: $0.lastUsedBy)
            }
            return AgentResponse(ok: true, secrets: infos, requesterSignature: peer.signature)
        } catch let error as SesameError {
            return AgentResponse(ok: false, error: mapError(error), requesterSignature: peer.signature)
        } catch {
            return AgentResponse.failure(error.localizedDescription)
        }
    }

    private func handleGet(_ request: AgentRequest, peer: PeerIdentity) -> AgentResponse {
        guard let name = request.name else { return .failure("missing name") }

        // Serialize Touch ID: acquire the single-prompt gate within the timeout.
        if gate.wait(timeout: .now() + authTimeout) == .timedOut {
            logEntry(op: "get", name: name, peer: peer, result: "timeout")
            return AgentResponse(ok: false, error: "timeout", requesterSignature: peer.signature)
        }
        defer { gate.signal() }

        do {
            // The prompt names the VERIFIED peer — signed identifier or unsigned:… flag.
            let reason = "\(peer.signature) wants \(name)"
            let release = { try self.store.copyValue(name: name, reason: reason) }

            let value: Data
            if let authorize = authorizeRelease {
                // App-mediated: bring Sesame frontmost, confirm, decrypt on main.
                guard let approved = try authorize(name, peer.signature, release) else {
                    // User pressed Deny — short-circuit before any release.
                    logEntry(op: "get", name: name, peer: peer, result: "denied")
                    return AgentResponse(ok: false, error: "denied",
                                         requesterSignature: peer.signature)
                }
                value = approved
            } else {
                // Headless/core: no prompt, release inline on the socket thread.
                value = try release()
            }

            store.recordUse(name: name, by: peer.signature)
            logEntry(op: "get", name: name, peer: peer, result: "ok")
            return AgentResponse(ok: true,
                                 value: String(data: value, encoding: .utf8) ?? "",
                                 requesterSignature: peer.signature)
        } catch let error as SesameError {
            logEntry(op: "get", name: name, peer: peer, result: error.logResult)
            return AgentResponse(ok: false, error: mapError(error), requesterSignature: peer.signature)
        } catch {
            return AgentResponse.failure(error.localizedDescription)
        }
    }

    private func handleAdd(_ request: AgentRequest, peer: PeerIdentity) -> AgentResponse {
        guard let name = request.name, let value = request.value else {
            return .failure("missing name/value")
        }
        do {
            let added = try store.add(name: name, value: Data(value.utf8))
            logEntry(op: "add", name: name, peer: peer, result: "ok")
            return AgentResponse(ok: true, value: added ? "added" : "already",
                                 requesterSignature: peer.signature)
        } catch let error as SesameError {
            logEntry(op: "add", name: name, peer: peer, result: error.logResult)
            return AgentResponse(ok: false, error: mapError(error), requesterSignature: peer.signature)
        } catch {
            return AgentResponse.failure(error.localizedDescription)
        }
    }

    private func handleDelete(_ request: AgentRequest, peer: PeerIdentity) -> AgentResponse {
        guard let name = request.name else { return .failure("missing name") }
        do {
            try store.delete(name: name)
            logEntry(op: "rm", name: name, peer: peer, result: "ok")
            return AgentResponse(ok: true, requesterSignature: peer.signature)
        } catch let error as SesameError {
            logEntry(op: "rm", name: name, peer: peer, result: error.logResult)
            return AgentResponse(ok: false, error: mapError(error), requesterSignature: peer.signature)
        } catch {
            return AgentResponse.failure(error.localizedDescription)
        }
    }

    private func logEntry(op: String, name: String, peer: PeerIdentity, result: String) {
        log.append(LogEntry(ts: Time.iso(), op: op, name: name,
                            requester: peer.signature, result: result))
    }

    /// Map a `SesameError` to the wire `error` token the client's
    /// `AgentBackedStore` re-inflates.
    private func mapError(_ error: SesameError) -> String {
        switch error {
        case .denied: return "denied"
        case .timeout: return "timeout"
        case .notFound(let name): return "notfound:\(name)"
        default: return error.message
        }
    }
}
