import Foundation
import SwiftUI
import SesameCore

/// Drives the app's one-click "Tap-only injection" onboarding — the SAME setup a
/// user would otherwise do in a terminal with `sesame open` + `sesame setup`.
///
/// It reuses the shared `SesameCore.TapOnlySetup` orchestrator for the three
/// effects (install shims, set open mode, wire PATH) and their reversal. The only
/// app-side concern here is the ENVIRONMENT: a GUI app inherits a minimal PATH
/// (roughly `/usr/bin:/bin`), so before calling Core we (a) find the real `sesame`
/// CLI the shims must exec and (b) augment the PATH so each tool's real binary
/// resolves. If the CLI can't be found we refuse to enable (baking in a bad path
/// would produce dead shims) and tell the user to install it.
@MainActor
final class TapOnlyController: ObservableObject {
    @Published private(set) var status: TapOnlySetup.Status =
        TapOnlySetup.Status(enabled: false, shimCount: 0, pathWired: false, shimsDir: Shims.dir())
    /// A one-line summary of the last change (what was installed / reverted).
    @Published private(set) var noticeMessage: String?
    /// A blocking problem (e.g. the CLI isn't installed).
    @Published private(set) var errorMessage: String?
    /// True while an enable/disable is running, to disable the buttons.
    @Published private(set) var busy = false

    init() { refresh() }

    /// Pull the on-disk state into the published status.
    func refresh() {
        status = TapOnlySetup.status()
    }

    /// Turn tap-only injection on: install the known-tool shims, flip to open mode,
    /// and add the shims dir to PATH. Refuses (with guidance) if the `sesame` CLI
    /// isn't installed, since the shims exec it.
    func enable() {
        guard !busy else { return }
        errorMessage = nil
        noticeMessage = nil

        guard let cli = SesameCLI.locate() else {
            errorMessage = "Can’t find the ‘sesame’ command-line tool — install it first "
                + "(brew install sesame), then try again."
            return
        }
        let path = EnvPath.augmented()

        busy = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try TapOnlySetup.enable(sesamePath: cli, path: path) }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let r):
                    var parts: [String] = ["Installed \(r.installed.count) shim(s)"]
                    if !r.shellUpdated.isEmpty {
                        parts.append("added the shims dir to PATH in \(r.shellUpdated.joined(separator: ", "))")
                    } else {
                        parts.append("PATH already wired")
                    }
                    self.noticeMessage = parts.joined(separator: " · ")
                        + ". Open a NEW terminal for the PATH change to take effect."
                case .failure(let error):
                    self.errorMessage = "Couldn’t enable tap-only injection: \(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }

    /// Turn tap-only injection off, reverting all three effects (open mode →
    /// allowlist, remove the generated shims, strip the PATH line).
    func disable() {
        guard !busy else { return }
        errorMessage = nil
        noticeMessage = nil

        busy = true
        Task.detached(priority: .userInitiated) {
            let result = Result { try TapOnlySetup.disable() }
            await MainActor.run {
                self.busy = false
                switch result {
                case .success(let r):
                    self.noticeMessage = "Disabled — removed \(r.removedShims.count) shim(s), "
                        + "back to the default allowlist. Open a NEW terminal to drop the PATH entry."
                case .failure(let error):
                    self.errorMessage = "Couldn’t disable tap-only injection: \(error.localizedDescription)"
                }
                self.refresh()
            }
        }
    }
}

// MARK: - Settings section

/// The Settings "Tap-only injection" row: current state + one-click Enable/Disable,
/// plus a plain-language note of what it changed. This is the no-terminal path to
/// what the README calls the headline flow.
struct TapOnlySection: View {
    @StateObject private var controller = TapOnlyController()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: controller.status.enabled ? "checkmark.seal.fill" : "seal")
                    .foregroundStyle(controller.status.enabled ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(controller.status.enabled ? "Tap-only injection is ON" : "Tap-only injection is off")
                        .font(.subheadline).bold()
                    Text(controller.status.enabled
                         ? "Any shimmed command gets its secret on one Touch ID tap — no allowlist."
                         : "Enable to inject secrets into any known tool with a single tap.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if controller.busy { ProgressView().controlSize(.small) }
            }

            // What's installed right now, so the state is legible without a terminal.
            HStack(spacing: 12) {
                stateChip(on: controller.status.enabled, label: "Open mode")
                stateChip(on: controller.status.shimCount > 0,
                          label: "\(controller.status.shimCount) shim\(controller.status.shimCount == 1 ? "" : "s")")
                stateChip(on: controller.status.pathWired, label: "On PATH")
            }
            .font(.caption)

            HStack {
                if controller.status.enabled {
                    Button(role: .destructive) { controller.disable() } label: {
                        Label("Turn off", systemImage: "xmark.circle")
                    }
                    .disabled(controller.busy)
                } else {
                    Button { controller.enable() } label: {
                        Label("Enable", systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.busy)
                }
            }

            if let error = controller.errorMessage {
                Text(error).font(.caption2).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let notice = controller.noticeMessage {
                Text(notice).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { controller.refresh() }
    }

    private func stateChip(on: Bool, label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(on ? Color.green : Color.secondary)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Environment glue (app-only; kept out of SesameCore on purpose)

/// Locate the real `sesame` CLI binary the generated shims must exec. A GUI app's
/// PATH is minimal, so we search an AUGMENTED PATH plus the well-known install
/// prefixes (Homebrew on Apple silicon + Intel, and the curl one-liner's
/// `~/.local/bin`). Returns nil if it truly isn't installed.
enum SesameCLI {
    static func locate() -> String? {
        let shims = Shims.dir().path
        if let onPath = Shims.resolveRealBinary("sesame", path: EnvPath.augmented(), excluding: shims) {
            return onPath
        }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/sesame",
            "/usr/local/bin/sesame",
            "\(home)/.local/bin/sesame",
        ]
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}

/// Builds a PATH string a GUI app can hand to shim resolution. Starts from the
/// process PATH and appends the standard tool dirs that actually exist, de-duped
/// with order preserved — so Homebrew/local tools resolve even though the app was
/// launched from Finder with a bare PATH.
enum EnvPath {
    static func augmented() -> String {
        let home = NSHomeDirectory()
        let base = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let standard = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [String] = []
        for entry in base.components(separatedBy: ":") + standard {
            if entry.isEmpty || seen.contains(entry) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry, isDirectory: &isDir), isDir.boolValue else { continue }
            seen.insert(entry)
            result.append(entry)
        }
        return result.joined(separator: ":")
    }
}
