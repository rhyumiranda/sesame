import SwiftUI
import AppKit

/// Sesame's Milestone 2 menu-bar (status-bar) app.
///
/// It is an agent app (`LSUIElement=true` in Info.plist): no Dock icon, no
/// main window — just a status-bar item whose click opens the popover. Built
/// as a SwiftPM executable and packaged into `Sesame.app` by
/// `scripts/build-app.sh` (a proper `.app` bundle with an `Info.plist` is
/// required for `SMAppService` login-item discovery).
///
/// The status item is driven by AppKit (`NSStatusItem` + `NSPopover`), not
/// SwiftUI's `MenuBarExtra`: on notched MacBooks a `MenuBarExtra` icon can be
/// hidden behind the notch, leaving the whole popover UI unreachable. An
/// `NSStatusItem` placed via `NSStatusBar.system` is laid out reliably.
@main
struct SesameStatusBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // A SwiftUI `App` requires at least one `Scene`, but the visible UI is
        // now entirely AppKit-driven (status item + popover). An empty Settings
        // scene satisfies the requirement without adding a window.
        Settings { EmptyView() }
    }
}

/// Owns the AppKit status item and popover for the app's lifetime.
///
/// Every long-lived object is retained here on purpose: a released
/// `NSStatusItem` is removed from the menu bar (its icon disappears), so the
/// delegate must hold the status item, popover, agent, and view model for as
/// long as the app runs.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    // Resolve the config-selected store ONCE and share it between the agent
    // (which serves the CLI) and the popover (which lists/adds/removes), so the
    // UI never drifts from what the agent hands out. Retained here.
    private let agent = AgentService()
    private lazy var model = SecretsViewModel(store: agent.store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        agent.start()

        popover.behavior = .transient
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environmentObject(model)
                .environmentObject(agent)
        )

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "lock.open",
                                   accessibilityDescription: "Sesame")
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }
        statusItem = item
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
