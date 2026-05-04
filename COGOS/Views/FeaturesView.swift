import SwiftUI

/// Retained for compatibility with older navigation paths. The primary app
/// shell now uses tabs in `ContentView` and does not present this screen.
struct FeaturesView: View {
    var body: some View {
        List {
            NavigationLink {
                SettingsView()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            NavigationLink {
                NotificationSettingsView()
            } label: {
                Label("Notifications", systemImage: "bell.badge")
            }
        }
        .navigationTitle("More")
    }
}
