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
    @StateObject private var model = SecretsViewModel()

    var body: some Scene {
        // `.window` style hosts arbitrary SwiftUI (text fields, toggles) in the
        // popover; the default `.menu` style only renders menu items.
        MenuBarExtra("Sesame", systemImage: "lock.open") {
            PopoverView()
                .environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
