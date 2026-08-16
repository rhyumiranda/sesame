import SwiftUI
import AppKit

/// Sesame's Milestone 2 windowed app.
///
/// It is a NORMAL windowed macOS app (`LSUIElement=false`, activation policy
/// `.regular`): a Dock icon, a standard menu bar, and a main window that opens on
/// launch. This replaces the earlier menu-bar-only (agent) shape — a status-bar
/// icon can hide behind the notch on notched MacBooks, leaving the UI
/// unreachable, whereas a window + Dock icon is always visible.
///
/// Built as a SwiftPM executable and packaged into `Sesame.app` by
/// `scripts/build-app.sh` (a proper `.app` bundle with an `Info.plist` is
/// required for `SMAppService` login-item discovery).
///
/// A secondary `NSStatusItem` remains as a quick-access affordance: clicking it
/// re-focuses/opens the main window. The window is the primary UI.
@main
struct SesameApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Sesame") {
            MainWindowView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.agent)
        }
        .windowResizability(.contentMinSize)
        .commands {
            // No New-Window item — Sesame is single-window.
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Owns app-wide state and the secondary status item for the app's lifetime.
///
/// The agent + view model are created here (retained) and shared with the
/// `WindowGroup` so the window never drifts from what the agent serves. A
/// released `NSStatusItem` disappears from the menu bar, so it too is retained.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Resolve the config-selected store ONCE and share it between the agent
    // (which serves the CLI) and the window (which lists/adds/removes/reveals),
    // so the UI never drifts from what the agent hands out. Retained here.
    let agent = AgentService()
    lazy var model = SecretsViewModel(store: agent.store)

    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A windowed app, not a background agent: Dock icon + normal menu bar +
        // windows. Required because this executable began life as an
        // `LSUIElement` agent; without `.regular` the WindowGroup window never
        // shows and there is no Dock icon.
        NSApp.setActivationPolicy(.regular)

        agent.start()

        // Bring the window to the front so the user immediately SEES it.
        NSApp.activate(ignoringOtherApps: true)

        setUpStatusItem()
    }

    /// Re-show/focus the main window when the Dock icon is clicked while no
    /// window is open (e.g. after the user closed it).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        focusMainWindow()
        return true
    }

    // MARK: - Secondary status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "lock.shield",
                                   accessibilityDescription: "Sesame")
            button.image?.isTemplate = true
            button.action = #selector(statusItemClicked(_:))
            button.target = self
            button.toolTip = "Show the Sesame window"
        }
        statusItem = item
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        focusMainWindow()
    }

    /// Activate the app and bring its main window forward (creating nothing new —
    /// the WindowGroup owns the single window).
    private func focusMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
