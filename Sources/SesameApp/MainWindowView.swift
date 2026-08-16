import SwiftUI
import AppKit
import SesameCore

/// Sesame's main window (Milestone 2, windowed app). Replaces the old status-bar
/// popover as the PRIMARY, always-visible UI: a Dock-icon app with a real window,
/// notch-proof (a `MenuBarExtra`/status item can hide behind the notch). Mirrors
/// the plan's §6d "Vault — Secrets" mock-up:
///   • Secrets — search + per-secret rows (key icon, name, "used X ago · who",
///     reveal/copy behind Touch ID, remove behind Touch ID) + an Add sheet.
///   • Access log — time · secret · requester · result, newest first.
///   • Settings — the auto-start toggle + the active storage backend + running.
/// The status item stays as a secondary quick-access that re-focuses this window.
struct MainWindowView: View {
    @EnvironmentObject var model: SecretsViewModel
    @EnvironmentObject var agent: AgentService

    /// Which pane the segmented control shows.
    private enum Pane: String, CaseIterable, Identifiable {
        case secrets = "Secrets"
        case log = "Access Log"
        case settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .secrets: return "key.fill"
            case .log: return "list.bullet.rectangle"
            case .settings: return "gearshape"
            }
        }
    }

    @State private var pane: Pane = .secrets
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { p in
                    Label(p.rawValue, systemImage: p.symbol).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                switch pane {
                case .secrets: SecretsPane(showAdd: $showAdd)
                case .log: AccessLogPane()
                case .settings: SettingsPane()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            statusBar
        }
        .frame(minWidth: 560, minHeight: 480)
        .onAppear { model.refresh() }
        .sheet(isPresented: $showAdd) {
            AddSecretSheet(isPresented: $showAdd)
                .environmentObject(model)
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sesame").font(.headline)
                Text("Fingerprint-gated vault for your agents’ secrets")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            runningBadge
        }
        .padding(16)
    }

    private var runningBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(.green).frame(width: 8, height: 8)
            Text("Running").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }

    private var statusBar: some View {
        HStack(spacing: 6) {
            if let error = model.errorMessage {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(error).foregroundStyle(.red)
            } else if let status = model.statusMessage {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(status).foregroundStyle(.secondary)
            } else {
                Text(agent.statusText).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .font(.caption)
        .lineLimit(1).truncationMode(.middle)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.bar)
    }
}

// MARK: - Secrets pane

private struct SecretsPane: View {
    @EnvironmentObject var model: SecretsViewModel
    @Binding var showAdd: Bool
    @State private var search = ""
    @State private var pendingRemoval: String?

    private var filtered: [SecretInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.secrets }
        return model.secrets.filter { $0.name.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search secrets", text: $search)
                    .textFieldStyle(.plain)
                Spacer()
                Button {
                    showAdd = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .help("Add a secret")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            if model.secrets.isEmpty {
                emptyState
            } else if filtered.isEmpty {
                ContentUnavailableCompat(
                    title: "No matches",
                    systemImage: "magnifyingglass",
                    message: "No secret matches “\(search)”."
                )
            } else {
                List {
                    ForEach(filtered, id: \.name) { info in
                        SecretRow(info: info,
                                  isConfirmingRemoval: pendingRemoval == info.name,
                                  onReveal: { model.revealAndCopy(name: info.name) },
                                  onRemoveTap: { pendingRemoval = info.name },
                                  onConfirmRemove: {
                                      model.remove(name: info.name)
                                      pendingRemoval = nil
                                  },
                                  onCancelRemove: { pendingRemoval = nil })
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "key.slash").font(.largeTitle).foregroundStyle(.secondary)
            Text("No secrets yet").font(.headline)
            Text("Add one to keep it behind your fingerprint.")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                showAdd = true
            } label: {
                Label("Add a secret", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One secret row: key icon, name, a friendly "used X ago · who" chip, and the
/// two gated actions (reveal/copy, remove). NAMES + metadata only — never a value.
private struct SecretRow: View {
    let info: SecretInfo
    let isConfirmingRemoval: Bool
    let onReveal: () -> Void
    let onRemoveTap: () -> Void
    let onConfirmRemove: () -> Void
    let onCancelRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name).font(.system(.body, design: .monospaced))
                Text(usageLine).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("••••••••").font(.system(.body, design: .monospaced))
                .foregroundStyle(.tertiary)

            if isConfirmingRemoval {
                Button("Remove", role: .destructive, action: onConfirmRemove)
                    .controlSize(.small)
                Button("Cancel", action: onCancelRemove).controlSize(.small)
            } else {
                Button(action: onReveal) {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.borderless)
                .help("Reveal & copy value (Touch ID)")

                Button(action: onRemoveTap) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove (Touch ID)")
            }
        }
        .padding(.vertical, 4)
    }

    /// "used 2m ago · claude-code" / "used 2m ago" / "never used".
    private var usageLine: String {
        let rel = RelativeTime.lastUsed(info.lastUsedAt)
        if let by = info.lastUsedBy, !by.isEmpty, info.lastUsedAt != nil {
            return "\(rel) · \(by)"
        }
        return rel
    }
}

// MARK: - Add sheet

private struct AddSecretSheet: View {
    @EnvironmentObject var model: SecretsViewModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a secret").font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Name").font(.caption).foregroundStyle(.secondary)
                TextField("OPENAI_API_KEY", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Value").font(.caption).foregroundStyle(.secondary)
                SecureField("secret value", text: $value)
                    .textFieldStyle(.roundedBorder)
            }

            Label("Stored in your Keychain · Touch ID to read · stays on this Mac",
                  systemImage: "lock.fill")
                .font(.caption).foregroundStyle(.secondary)

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.add(name: name, value: value)
                    if model.errorMessage == nil { isPresented = false }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || value.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

// MARK: - Access log pane

private struct AccessLogPane: View {
    @State private var rows: [LogRow] = []

    var body: some View {
        Group {
            if rows.isEmpty {
                ContentUnavailableCompat(
                    title: "No access yet",
                    systemImage: "list.bullet.rectangle",
                    message: "Requests to release a secret — approved or denied — show up here."
                )
            } else {
                Table(rows) {
                    TableColumn("Time") { Text($0.time).monospacedDigit() }
                        .width(min: 64, ideal: 72)
                    TableColumn("Secret") { Text($0.name).font(.system(.body, design: .monospaced)) }
                    TableColumn("Requester") { Text($0.requester).font(.system(.body, design: .monospaced)) }
                    TableColumn("Result") { LogResultChip(result: $0.result) }
                        .width(min: 90, ideal: 110)
                }
            }
        }
        .onAppear(perform: reload)
    }

    private func reload() {
        rows = AccessLog().read().enumerated().map { LogRow(index: $0.offset, dict: $0.element) }
    }
}

/// A parsed, Identifiable access-log line for the `Table`.
private struct LogRow: Identifiable {
    let id: Int
    let time: String
    let name: String
    let requester: String
    let result: String

    init(index: Int, dict: [String: Any]) {
        self.id = index
        self.name = (dict["name"] as? String) ?? "—"
        self.requester = (dict["requester"] as? String) ?? "unknown"
        self.result = (dict["result"] as? String) ?? "—"
        self.time = LogRow.shortTime(dict["ts"] as? String)
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    private static let hm: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    static func shortTime(_ isoString: String?) -> String {
        guard let s = isoString, let d = iso.date(from: s) else { return "—" }
        return hm.string(from: d)
    }
}

/// Approved/denied pill, matching the §6d access-log chips.
private struct LogResultChip: View {
    let result: String
    var body: some View {
        let approved = (result == "ok")
        Text(approved ? "approved" : result)
            .font(.caption).bold()
            .padding(.horizontal, 8).padding(.vertical, 2)
            .background((approved ? Color.green : Color.red).opacity(0.18), in: Capsule())
            .foregroundStyle(approved ? Color.green : Color.red)
    }
}

// MARK: - Settings pane

private struct SettingsPane: View {
    @EnvironmentObject var agent: AgentService

    private var backendLabel: String {
        switch agent.config.storageBackend {
        case .advisory: return "Advisory (login Keychain, Touch ID gate at the app)"
        case .secureEnclave: return "Secure Enclave (hardware-wrapped, Touch ID to decrypt)"
        }
    }

    var body: some View {
        Form {
            Section("Startup") {
                LoginItemSection()
            }
            Section("Storage") {
                LabeledContent("Backend", value: backendLabel)
                LabeledContent("Agent") {
                    Text(agent.statusText)
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Section {
                Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                    Label("Quit Sesame", systemImage: "power")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Compat

/// `ContentUnavailableView` is macOS 14+; Sesame targets macOS 13. This is a
/// tiny stand-in so the empty states build on the deployment target.
private struct ContentUnavailableCompat: View {
    let title: String
    let systemImage: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage).font(.largeTitle).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(message).font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
