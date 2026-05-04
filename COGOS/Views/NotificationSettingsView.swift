import SwiftUI

struct NotificationSettingsView: View {
    @EnvironmentObject var whitelist: NotificationWhitelist
    @EnvironmentObject var appState: AppState
    @State private var newAppId: String = ""

    var body: some View {
        Form {
            Section {
                if whitelist.appIds.isEmpty {
                    ContentUnavailableView {
                        Label("All Apps Allowed", systemImage: "bell")
                    } description: {
                        Text("Add app bundle identifiers if you only want notifications from specific apps forwarded to your glasses.")
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(whitelist.appIds, id: \.self) { id in
                        HStack(spacing: 12) {
                            Image(systemName: "app.badge")
                                .foregroundStyle(.tint)
                            Text(id)
                                .font(.body.monospaced())
                            Spacer()
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                remove(id)
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
            } header: {
                Text("Forwarded Apps")
            } footer: {
                Text("Leave the list empty to forward notifications from all apps.")
            }

            Section {
                TextField("com.example.app", text: $newAppId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button {
                    add()
                } label: {
                    Label("Add App", systemImage: "plus.circle.fill")
                }
                .disabled(trimmedNewAppId.isEmpty || whitelist.appIds.contains(trimmedNewAppId))
            } header: {
                Text("Add App")
            } footer: {
                Text("Use the app’s bundle identifier, for example `com.apple.MobileSMS`.")
            }

            Section {
                Button {
                    Task { await whitelist.pushToGlasses(proto: appState.proto) }
                } label: {
                    Label("Sync Notification Settings", systemImage: "arrow.triangle.2.circlepath")
                }
            } footer: {
                Text("COGOS also syncs this list when your glasses connect.")
            }
        }
        .navigationTitle("Notifications")
    }

    private var trimmedNewAppId: String {
        newAppId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        let id = trimmedNewAppId
        guard !id.isEmpty, !whitelist.appIds.contains(id) else { return }
        whitelist.set(whitelist.appIds + [id])
        newAppId = ""
    }

    private func remove(_ id: String) {
        whitelist.set(whitelist.appIds.filter { $0 != id })
    }
}
