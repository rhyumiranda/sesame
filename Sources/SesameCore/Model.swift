import Foundation

// MARK: - Errors + exit codes
//
// Exit-code contract (see the plan / README):
//   0  success
//   1  runtime failure  (Touch ID denied, I/O, rate-limited, Keychain locked)
//   2  usage error      (secret not found, bad name, missing --confirm)

public enum SesameError: Error {
    case notFound(String)                 // exit 2
    case badName(String)                  // exit 2
    case missingConfirm                   // exit 2
    case denied(String)                   // exit 1
    case rateLimited(name: String, secondsLeft: Int) // exit 1
    case keychainLocked                   // exit 1
    case keychain(OSStatus)               // exit 1
    case io(String)                       // exit 1
    case authUnavailable(String)          // exit 1

    public var exitCode: Int32 {
        switch self {
        case .notFound, .badName, .missingConfirm:
            return 2
        default:
            return 1
        }
    }

    /// Structured, actionable message — names the problem and the remedy command.
    public var message: String {
        switch self {
        case .notFound(let name):
            return "\(name) not found — 'sesame add \(name)' to create it"
        case .badName(let name):
            return "invalid name '\(name)' — use letters, digits, and underscores (must not start with a digit)"
        case .missingConfirm:
            return "refusing deletion without --confirm"
        case .denied:
            return "approval denied — secret not released"
        case .rateLimited(let name, let secondsLeft):
            return "rate-limited for \(name) — try again in \(secondsLeft)s"
        case .keychainLocked:
            return "Keychain locked or no login session"
        case .keychain(let status):
            return "keychain error \(status)"
        case .io(let detail):
            return "io error — \(detail)"
        case .authUnavailable(let detail):
            return "Touch ID unavailable — \(detail)"
        }
    }

    /// The `result` token recorded in the access log for this failure.
    public var logResult: String {
        switch self {
        case .notFound: return "notfound"
        case .denied: return "denied"
        case .rateLimited: return "ratelimited"
        default: return "error"
        }
    }
}

// MARK: - Name validation

public enum Name {
    /// Env-var-shaped: leading letter/underscore, then letters/digits/underscores.
    public static func validate(_ name: String) throws {
        let pattern = "^[A-Za-z_][A-Za-z0-9_]*$"
        guard name.range(of: pattern, options: .regularExpression) != nil else {
            throw SesameError.badName(name)
        }
    }
}

// MARK: - Time

public enum Time {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func iso(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }
}

// MARK: - Output helpers
//
// TOON is the default, token-efficient shape for agents; `--json` is available
// on every command. Secret VALUES never appear in either — only metadata.

public enum Out {
    public static func line(_ s: String) {
        FileHandle.standardOutput.write(Data((s + "\n").utf8))
    }

    public static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }

    /// Bare value with NO trailing newline — so `$(sesame get X)` captures it exactly.
    public static func bareValue(_ s: String) {
        FileHandle.standardOutput.write(Data(s.utf8))
    }

    public static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    /// Print a structured error to stderr in the requested shape, then exit.
    public static func failAndExit(_ error: SesameError, json: Bool) -> Never {
        if json {
            err(Out.json(["ok": false, "error": error.message, "code": Int(error.exitCode)]))
        } else {
            err("error: \(error.message)")
        }
        exit(error.exitCode)
    }
}
