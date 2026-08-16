import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - Wire messages
//
// Framing (pinned decision #6): a uint32 BIG-ENDIAN length prefix, then a JSON
// object. One request, one response, per connection.

/// A client → agent request. `requester` is the client's SELF-REPORTED label
/// (advisory, for the log); the agent independently derives the peer's VERIFIED
/// code signature from the socket and never trusts this field for identity.
public struct AgentRequest: Codable, Sendable {
    public var op: String            // "get" | "list" | "add" | "delete"
    public var name: String?
    public var value: String?        // for "add"
    public var requester: String?

    public init(op: String, name: String? = nil, value: String? = nil, requester: String? = nil) {
        self.op = op
        self.name = name
        self.value = value
        self.requester = requester
    }
}

/// Metadata form carried in a `list` response (never a value).
public struct AgentSecretInfo: Codable, Sendable {
    public var name: String
    public var createdAt: String
    public var lastUsedAt: String?
    public var lastUsedBy: String?

    public init(name: String, createdAt: String, lastUsedAt: String?, lastUsedBy: String?) {
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastUsedBy = lastUsedBy
    }
}

/// An agent → client response.
public struct AgentResponse: Codable, Sendable {
    public var ok: Bool
    public var value: String?
    public var error: String?
    public var secrets: [AgentSecretInfo]?
    /// The peer signature the agent VERIFIED and showed in the Touch ID prompt
    /// (a real identifier, or `unsigned:<path>:<pid>`). Echoed for the log/UX.
    public var requesterSignature: String?

    public init(ok: Bool, value: String? = nil, error: String? = nil,
                secrets: [AgentSecretInfo]? = nil, requesterSignature: String? = nil) {
        self.ok = ok
        self.value = value
        self.error = error
        self.secrets = secrets
        self.requesterSignature = requesterSignature
    }

    public static func failure(_ message: String) -> AgentResponse {
        AgentResponse(ok: false, error: message)
    }
}

// MARK: - Framed IO over a raw fd

/// Length-prefixed framing + AF_UNIX plumbing shared by the client and server.
public enum UnixSocket {
    /// Maximum accepted frame body — a guard against a hostile/oversized length
    /// prefix. Secrets are small; 1 MiB is generous.
    public static let maxFrame = 1 << 20

    /// Read exactly `count` bytes, looping over partial reads. `nil` on EOF/error.
    public static func readN(_ fd: Int32, _ count: Int) -> Data? {
        var buffer = Data()
        buffer.reserveCapacity(count)
        var remaining = count
        var chunk = [UInt8](repeating: 0, count: min(count, 65536))
        while remaining > 0 {
            let want = min(remaining, chunk.count)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, want) }
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
            remaining -= n
        }
        return buffer
    }

    /// Write all of `data`, looping over partial writes. False on error.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while offset < data.count {
                let n = write(fd, base + offset, data.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }

    /// Read one framed message: uint32 BE length, then that many body bytes.
    public static func readFrame(_ fd: Int32) -> Data? {
        guard let header = readN(fd, 4) else { return nil }
        let length = header.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        let len = Int(length)
        guard len > 0, len <= maxFrame else { return nil }
        return readN(fd, len)
    }

    /// Write one framed message.
    @discardableResult
    public static func writeFrame(_ fd: Int32, _ body: Data) -> Bool {
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(body)
        return writeAll(fd, frame)
    }

    /// Fill a `sockaddr_un` for `path`. Throws if the path exceeds `sun_path`
    /// (104 bytes on macOS) — a real gotcha for temp-dir socket paths.
    public static func makeAddr(path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        let bytes = Array(path.utf8)
        guard bytes.count < capacity else {
            throw SesameError.io("socket path too long (\(bytes.count) ≥ \(capacity)): \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: capacity) { dst in
                for (i, b) in bytes.enumerated() { dst[i] = CChar(bitPattern: b) }
                dst[bytes.count] = 0
            }
        }
        return addr
    }
}

// MARK: - Client

/// The CLI's thin client to the agent socket. Connects, sends one request, reads
/// one response, closes. `isAvailable()` lets the CLI fail SAFE to the local
/// advisory path when no agent is listening.
public struct AgentClient: Sendable {
    public let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    private func connectFD() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SesameError.agentUnavailable("socket() failed") }
        var addr = try UnixSocket.makeAddr(path: socketPath)
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
        }
        guard rc == 0 else {
            close(fd)
            throw SesameError.agentUnavailable("no agent listening at \(socketPath)")
        }
        return fd
    }

    /// True if an agent is currently accepting connections at the socket path.
    public func isAvailable() -> Bool {
        guard let fd = try? connectFD() else { return false }
        close(fd)
        return true
    }

    /// Send one request and await the response. Throws `agentUnavailable` if the
    /// connection can't be made — the caller uses that to fall back to local.
    public func send(_ request: AgentRequest) throws -> AgentResponse {
        let fd = try connectFD()
        defer { close(fd) }
        let body = try JSONEncoder().encode(request)
        guard UnixSocket.writeFrame(fd, body) else {
            throw SesameError.agentUnavailable("write to agent failed")
        }
        guard let reply = UnixSocket.readFrame(fd) else {
            throw SesameError.agentUnavailable("no reply from agent")
        }
        return try JSONDecoder().decode(AgentResponse.self, from: reply)
    }
}

// MARK: - Agent-backed store

/// A `StorageBackend` that routes every operation to the agent over the socket.
/// The agent owns the Secure-Enclave key and raises Touch ID; this store carries
/// no keys and never prompts locally. Used by the CLI when `data_source = agent`
/// and an agent is listening.
public struct AgentBackedStore: StorageBackend {
    private let client: AgentClient
    private let requester: String?

    public init(client: AgentClient, requester: String? = nil) {
        self.client = client
        self.requester = requester
    }

    public func exists(_ name: String) throws -> Bool {
        try list().contains { $0.name == name }
    }

    @discardableResult
    public func add(name: String, value: Data) throws -> Bool {
        let str = String(data: value, encoding: .utf8) ?? ""
        let resp = try client.send(AgentRequest(op: "add", name: name, value: str, requester: requester))
        if !resp.ok { throw AgentBackedStore.mapError(resp.error) }
        // The agent replies ok=true, value="added" for a new item, "already" if present.
        return resp.value != "already"
    }

    public func copyValue(name: String) throws -> Data {
        let resp = try client.send(AgentRequest(op: "get", name: name, requester: requester))
        guard resp.ok, let value = resp.value else {
            throw AgentBackedStore.mapError(resp.error)
        }
        return Data(value.utf8)
    }

    public func delete(name: String) throws {
        let resp = try client.send(AgentRequest(op: "delete", name: name, requester: requester))
        if !resp.ok { throw AgentBackedStore.mapError(resp.error) }
    }

    public func list() throws -> [SecretInfo] {
        let resp = try client.send(AgentRequest(op: "list", requester: requester))
        guard resp.ok else { throw AgentBackedStore.mapError(resp.error) }
        return (resp.secrets ?? []).map {
            SecretInfo(name: $0.name, createdAt: $0.createdAt,
                       lastUsedAt: $0.lastUsedAt, lastUsedBy: $0.lastUsedBy)
        }
    }

    /// The agent records use on its side of `get`; nothing to do here.
    public func recordUse(name: String, by requester: String?) {}

    private static func mapError(_ message: String?) -> SesameError {
        switch message {
        case "denied": return .denied("agent denied")
        case "timeout": return .timeout
        case .some(let m) where m.hasPrefix("notfound"):
            return .notFound(String(m.dropFirst("notfound:".count)))
        case .some(let m): return .io(m)
        case .none: return .io("agent error")
        }
    }
}

/// An `Authenticator` that always approves without prompting. Used on the
/// agent-routed CLI path where the AGENT'S Secure-Enclave decrypt is the real
/// Touch ID gate — the CLI must NOT raise a second, redundant prompt.
public struct NullAuthenticator: Authenticator, Sendable {
    public init() {}
    public func authenticate(reason: String) throws {}
}
