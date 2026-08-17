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
/// FAIL-CLOSED throughout: anything short of an explicit Allow click — Esc, the
/// close box, a self-timeout, or no GUI session at all — releases NOTHING and
/// returns `nil` (deny). A secret must never leak from a stray keystroke or an
/// unattended prompt.
///
/// Lives in SesameApp (AppKit) so SesameCore stays AppKit-free.
enum ReleaseApproval {
    /// Auto-deny a prompt the user never answers, so a forgotten dialog can't
    /// pin the agent's single-prompt gate forever (every other request would
    /// block). Matches `AgentServer`'s 60 s `authTimeout` — the request has
    /// already timed out at that point anyway.
    static let modalTimeout: TimeInterval = 60

    /// Called on the AgentServer socket (background) thread. Returns the released
    /// bytes ONLY on an explicit Allow click, or `nil` on any deny path (so
    /// `handleGet` returns the `denied` wire error and never releases). Rethrows
    /// `release`'s error (e.g. a real Touch ID denial or notfound) so the normal
    /// wire mapping still applies.
    static func confirmAndRelease(name: String, requester: String,
                                  release: () throws -> Data) throws -> Data? {
        try runOnMain {
            // Fail-closed when there's no GUI to present in (SSH, a launchd agent
            // with no Aqua session, or a headless box with no window server): the
            // window server publishes no screens there, so `runModal` would hang
            // or misbehave and no human is present to tap anyway. Deny.
            guard !NSScreen.screens.isEmpty else { return nil }

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
            let allowBtn = alert.addButton(withTitle: "Allow")
            let denyBtn = alert.addButton(withTitle: "Deny")
            // Release requires an EXPLICIT Allow click. Clear Allow's default
            // key so Return can't auto-approve; make Deny the Esc/cancel button.
            allowBtn.keyEquivalent = ""
            denyBtn.keyEquivalent = "\u{1B}" // Esc → Deny

            // Auto-dismiss to deny if the prompt is ignored, freeing the gate.
            // The timer must fire during the modal's own run-loop mode, so add it
            // to `.modalPanel` (and `.default` as a belt-and-braces fallback) —
            // a plain DispatchQueue.main block may not drain inside runModal.
            let timeoutTimer = Timer(timeInterval: modalTimeout, repeats: false) { _ in
                NSApp.abortModal()
            }
            RunLoop.current.add(timeoutTimer, forMode: .modalPanel)
            RunLoop.current.add(timeoutTimer, forMode: .default)
            defer { timeoutTimer.invalidate() }

            // ONLY an explicit Allow click releases. Esc/close → second button or
            // an abort/stop response; the self-timeout → `.abort`. All fail closed.
            guard alert.runModal() == .alertFirstButtonReturn else {
                return nil
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
