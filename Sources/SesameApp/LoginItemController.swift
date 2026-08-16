import Foundation
import ServiceManagement
import SwiftUI

/// Wraps `SMAppService.mainApp` — the macOS 13+ login-item API — so the popover
/// can toggle "launch at login" and reflect the REAL registration state.
///
/// Caveats honored + surfaced to the user (see README):
/// - `register()` succeeding means *registered*: the app actually launches at
///   login only after the NEXT login/reboot, not the instant you toggle it.
/// - The FIRST registration may raise a macOS "Allow in Login Items" approval
///   the user must click (state `.requiresApproval`); it cannot be automated.
/// - It only works because the `.app` lives in `~/Applications` (SMAppService
///   discovers `mainApp` login items reliably only there or in `/Applications`).
@MainActor
final class LoginItemController: ObservableObject {
    /// Bound to the toggle. Setting it (re)registers/unregisters, then syncs
    /// back to the real `SMAppService` status so the UI can't drift from truth.
    @Published var isEnabled: Bool = false
    @Published private(set) var statusText: String = ""
    @Published var noticeMessage: String?

    private var syncing = false

    init() {
        refresh()
    }

    /// Pull the real registration status into the published state.
    func refresh() {
        let status = SMAppService.mainApp.status
        syncing = true
        isEnabled = (status == .enabled)
        syncing = false
        statusText = Self.describe(status)
    }

    /// Called by the toggle's binding when the user flips it.
    func setEnabled(_ on: Bool) {
        // Ignore programmatic writes from `refresh()`.
        guard !syncing else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
                noticeMessage = "Registered. Launches at login after the next "
                    + "login/reboot; if macOS shows an approval prompt, click Allow."
            } else {
                try SMAppService.mainApp.unregister()
                noticeMessage = nil
            }
        } catch {
            noticeMessage = "Could not \(on ? "enable" : "disable") auto-start: "
                + error.localizedDescription
        }
        // Reflect the real status regardless of what the user tapped.
        refresh()
    }

    static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: return "Auto-start: enabled"
        case .notRegistered: return "Auto-start: off"
        case .requiresApproval: return "Auto-start: needs approval in Login Items"
        case .notFound: return "Auto-start: unavailable (run scripts/build-app.sh, open from ~/Applications)"
        @unknown default: return "Auto-start: unknown"
        }
    }
}

/// The popover's auto-start row: a toggle wired to `LoginItemController`, plus
/// the live status text and any approval/error notice.
struct LoginItemSection: View {
    @StateObject private var controller = LoginItemController()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { controller.isEnabled },
                set: { controller.setEnabled($0) }
            )) {
                Label("Start at login", systemImage: "power")
                    .font(.subheadline)
            }
            .toggleStyle(.switch)

            Text(controller.statusText)
                .font(.caption).foregroundStyle(.secondary)

            if let notice = controller.noticeMessage {
                Text(notice)
                    .font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { controller.refresh() }
    }
}
