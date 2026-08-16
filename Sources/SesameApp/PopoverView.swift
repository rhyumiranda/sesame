import SwiftUI
import SesameCore

/// The status-bar popover. Shows the running indicator, the stored secret
/// NAMES (never values), Add, Remove (Touch ID), a link to the access log,
/// and Quit. The auto-start toggle lives in `LoginItemSection`.
struct PopoverView: View {
    @EnvironmentObject var model: SecretsViewModel
    @State private var newName = ""
    @State private var newValue = ""
    @State private var showAdd = false
    @State private var pendingRemoval: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            secretsList
            Divider()
            addSection
            Divider()
            LoginItemSection()
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.open.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sesame").font(.headline)
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Sesame is running").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private var secretsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Secrets").font(.subheadline).bold()
            if model.secrets.isEmpty {
                Text("No secrets yet — add one below.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.secrets, id: \.name) { info in
                            secretRow(info)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
    }

    private func secretRow(_ info: SecretInfo) -> some View {
        HStack {
            Image(systemName: "key.fill").font(.caption2).foregroundStyle(.secondary)
            Text(info.name).font(.system(.body, design: .monospaced))
            Spacer()
            if pendingRemoval == info.name {
                Button("Confirm") { model.remove(name: info.name); pendingRemoval = nil }
                    .buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
                Button("Cancel") { pendingRemoval = nil }
                    .controlSize(.small)
            } else {
                Button {
                    pendingRemoval = info.name
                } label: {
                    Image(systemName: "trash").font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Remove (raises Touch ID)")
            }
        }
        .padding(.vertical, 2)
    }

    private var addSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            DisclosureGroup(isExpanded: $showAdd) {
                VStack(spacing: 6) {
                    TextField("NAME (env-var shaped)", text: $newName)
                        .textFieldStyle(.roundedBorder)
                    SecureField("value", text: $newValue)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Spacer()
                        Button("Add") {
                            model.add(name: newName, value: newValue)
                            if model.errorMessage == nil {
                                newName = ""; newValue = ""; showAdd = false
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newName.isEmpty || newValue.isEmpty)
                    }
                }
                .padding(.top, 4)
            } label: {
                Label("Add a secret", systemImage: "plus.circle")
                    .font(.subheadline)
            }

            if let error = model.errorMessage {
                Text(error).font(.caption).foregroundStyle(.red)
            } else if let status = model.statusMessage {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([AccessLog.defaultURL()])
            } label: {
                Label("Access log", systemImage: "list.bullet.rectangle")
            }
            .buttonStyle(.borderless)
            .font(.caption)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        }
    }
}
