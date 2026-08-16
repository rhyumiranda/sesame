import SwiftUI

/// Sesame's Milestone 2 menu-bar (status-bar) app.
///
/// It is an agent app (`LSUIElement=true` in Info.plist): no Dock icon, no
/// main window — just a status-bar item whose click opens the popover. Built
/// as a SwiftPM executable and packaged into `Sesame.app` by
/// `scripts/build-app.sh` (a proper `.app` bundle with an `Info.plist` is
/// required for `MenuBarExtra` and for `SMAppService` login-item discovery).
@main
struct SesameStatusBarApp: App {
    @StateObject private var agent: AgentService
    @StateObject private var model: SecretsViewModel

    init() {
        // Resolve the config-selected store ONCE and share it between the agent
        // (which serves the CLI) and the popover (which lists/adds/removes), so
        // the UI never drifts from what the agent hands out.
        let agent = AgentService()
        _agent = StateObject(wrappedValue: agent)
        _model = StateObject(wrappedValue: SecretsViewModel(store: agent.store))
        agent.start()
    }

    var body: some Scene {
        // `.window` style hosts arbitrary SwiftUI (text fields, toggles) in the
        // popover; the default `.menu` style only renders menu items.
        MenuBarExtra("Sesame", systemImage: "lock.open") {
            PopoverView()
                .environmentObject(model)
                .environmentObject(agent)
        }
        .menuBarExtraStyle(.window)
    }
}
