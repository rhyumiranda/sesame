import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One access-log record. Serialized as a single JSON line (JSONL).
/// NEVER contains the secret value.
public struct LogEntry {
    public var ts: String
    public var op: String        // add | get | run | rm
    public var name: String
    public var requester: String? // best-effort parent process name (NOT verified)
    public var result: String    // ok | denied | ratelimited | notfound | error

    public init(ts: String, op: String, name: String, requester: String?, result: String) {
        self.ts = ts
        self.op = op
        self.name = name
        self.requester = requester
        self.result = result
    }

    /// Ordered dictionary form for JSON (exact field set per the plan).
    public func asDictionary() -> [String: Any] {
        [
            "ts": ts,
            "op": op,
            "name": name,
            "requester": requester as Any? ?? NSNull(),
            "result": result
        ]
    }
}

/// Append-only JSONL access log.
///
/// Default location: `~/Library/Application Support/Sesame/access.log`.
/// Tests inject a temp URL so they never touch the user's real log.
public struct AccessLog {
    public let url: URL

    public init(url: URL = AccessLog.defaultURL()) {
        self.url = url
    }

    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Sesame/access.log")
    }

    /// Append one entry. Best-effort: logging failure must never break a command.
    public func append(_ entry: LogEntry) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let object = entry.asDictionary()
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return
        }
        var line = data
        line.append(0x0A) // newline

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Read entries newest-first, up to `limit`. Returns raw dictionaries so the
    /// output layer can render TOON or JSON identically.
    public func read(limit: Int? = nil) -> [[String: Any]] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries: [[String: Any]] = []
        for rawLine in text.split(separator: "\n") {
            guard let data = rawLine.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            entries.append(obj)
        }
        entries.reverse() // newest-first
        if let limit = limit, entries.count > limit {
            return Array(entries.prefix(limit))
        }
        return entries
    }
}

/// Best-effort parent-process name via sysctl (KERN_PROC_PID → p_comm).
///
/// This is the `requester` in the access log. It is a COURTESY label only —
/// NOT a verified code signature. A caller can trivially spoof it by renaming
/// its binary. Verified caller signatures are Milestone 2.
public enum Requester {
    public static func parentName() -> String? {
        #if canImport(Darwin)
        let ppid = getppid()
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, ppid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let rc = mib.withUnsafeMutableBufferPointer { buf in
            sysctl(buf.baseAddress, UInt32(buf.count), &info, &size, nil, 0)
        }
        guard rc == 0, size > 0 else { return nil }
        let name = withUnsafePointer(to: &info.kp_proc.p_comm) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cstr in
                String(cString: cstr)
            }
        }
        return name.isEmpty ? nil : name
        #else
        return nil
        #endif
    }
}
