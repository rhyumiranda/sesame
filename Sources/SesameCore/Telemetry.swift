import Foundation

public enum Telemetry {
    private static let defaultHost = "https://telemetry-umami.vercel.app"
    private static var cliStart = Date()
    private static var cliVersion = "dev"
    private static var cliCommand = "dashboard"

    public static func installCLIExitHook(version: String, arguments: [String] = CommandLine.arguments) {
        cliStart = Date()
        cliVersion = version
        cliCommand = sanitizedCommand(arguments)
        atexit {
            Telemetry.trackCLIExit()
        }
    }

    private static func trackCLIExit() {
        track(
            name: "command-run",
            tool: "sesame",
            version: cliVersion,
            path: "/commands/\(cliCommand)",
            data: [
                "tool": "sesame",
                "version": cliVersion,
                "command": cliCommand,
                "result": "completed",
                "duration_ms": Int(Date().timeIntervalSince(cliStart) * 1000)
            ]
        )
    }

    public static func trackAppLaunch(version: String) {
        track(
            name: "feature-used",
            tool: "sesame-app",
            version: version,
            path: "/app/launch",
            data: [
                "tool": "sesame-app",
                "version": version,
                "feature": "app-launch",
                "result": "success"
            ]
        )
    }

    private static func sanitizedCommand(_ arguments: [String]) -> String {
        guard arguments.count > 1 else { return "dashboard" }
        let first = arguments[1]
        if first.hasPrefix("-") { return "root" }
        return first
    }

    private static func track(name: String, tool: String, version: String, path: String, data: [String: Any]) {
        let env = ProcessInfo.processInfo.environment
        guard env["SESAME_TELEMETRY"] != "0", env["UMAMI_TELEMETRY"] != "0" else { return }
        guard let website = env["SESAME_UMAMI_WEBSITE_ID"] ?? env["UMAMI_WEBSITE_ID"], !website.isEmpty else { return }
        let host = env["SESAME_UMAMI_HOST"] ?? env["UMAMI_HOST"] ?? defaultHost
        guard let url = URL(string: "\(host)/api/send") else { return }

        let object: [String: Any] = [
            "type": "event",
            "payload": [
                "website": website,
                "hostname": "cli",
                "url": path,
                "title": tool,
                "name": name,
                "data": data
            ]
        ]
        guard JSONSerialization.isValidJSONObject(object),
              let body = try? JSONSerialization.data(withJSONObject: object) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 1
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("\(tool)/\(version)", forHTTPHeaderField: "User-Agent")

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 1)
    }
}
