import AppKit
import Foundation

/// Bridges a background socket `get` to a user-visible Touch ID approval.
///
/// The agent's socket handler runs on a background thread; a `get` arriving
/// while Sesame is NOT the frontmost app is instant-denied because macOS refuses
/// to present Touch ID for a decrypt raised off the main thread of an inactive
/// app. This type is injected into `AgentServer.authorizeRelease` and, for each
/// request, hops to the MAIN thread, brings Sesame frontmost, asks the user
/// Allow / Deny, and — on Allow — performs the Touch ID-gated `release` right
/// there on the main thread with the app active. That exactly mirrors the
/// known-good in-app "reveal" path (main thread + frontmost), which is why the
/// biometric prompt now presents for external/headless requests.
///
/// Lives in SesameApp (AppKit) so SesameCore stays AppKit-free.
enum ReleaseApproval {
    /// Called on the AgentServer socket (background) thread. Returns the released
    /// bytes on Allow, or `nil` on Deny (so `handleGet` returns the `denied` wire
    /// error and never releases). Rethrows `release`'s error (e.g. a real Touch
    /// ID denial or notfound) so the normal wire mapping still applies.
    static func confirmAndRelease(name: String, requester: String,
                                  release: () throws -> Data) throws -> Data? {
        try runOnMain {
            // Bring Sesame frontmost so biometrics can present. The modal alert
            // below also forces activation and pumps the run loop, so by the time
            // the user chooses, the app is definitively active for the decrypt.
            NSApp.activate(ignoringOtherApps: true)

            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Release “\(name)”?"
            alert.informativeText =
                "\(requester) is requesting the secret “\(name)”. "
                + "Approve to unlock it with Touch ID."
            alert.addButton(withTitle: "Allow") // .alertFirstButtonReturn
            alert.addButton(withTitle: "Deny")

            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil // user denied — never release
            }
            // On the main thread with the app frontmost: the Enclave decrypt now
            // presents Touch ID. Throws propagate to the caller unchanged.
            return try release()
        }
    }

    /// Run a main-thread body synchronously from any thread and return its value,
    /// propagating thrown errors. AppKit (`NSApp`, `NSAlert`) must be touched on
    /// the main thread; the socket handler that calls us is on a background queue.
    private static func runOnMain<T>(_ body: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try body() }
        return try DispatchQueue.main.sync(execute: body)
    }
}
