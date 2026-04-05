import SwiftUI

struct TextEntryView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bluetooth: BluetoothManager
    @State private var text: String = """
Welcome to G1.

You're holding the first eyewear ever designed to blend stunning aesthetics, amazing wearability and useful functionality.

At Even Realities we continuously explore the human relationship with technology.
"""

    var body: some View {
        VStack(spacing: 16) {
            TextEditor(text: $text)
                .frame(height: 300)
                .padding(8)
                .background(Color.white.cornerRadius(5))
            Button(action: sendToGlasses) {
                Text("Send to Glasses")
                    .foregroundColor(bluetooth.isConnected && !text.isEmpty ? .black : .gray)
                    .frame(maxWidth: .infinity).frame(height: 60)
                    .background(Color.white.cornerRadius(5))
            }
            .buttonStyle(.plain)
            .disabled(!bluetooth.isConnected || text.isEmpty)
            Spacer()
        }
        .padding()
        .navigationTitle("Text Transfer")
    }

    private func sendToGlasses() {
        let snapshot = text
        Task {
            // Use the session's HUD/text send path through proto.
            let lines = await MainActor.run { TextPaginator.measureStringList(snapshot) }
            let first5 = Array(lines.prefix(5))
            let pad = Array(repeating: " \n", count: max(0, 5 - first5.count))
            let content = first5.map { $0 + "\n" }
            let screen = (pad + content).joined()
            _ = await appState.proto.sendEvenAIData(screen, newScreen: 0x01 | 0x70,
                                                    pos: 0, currentPageNum: 1, maxPageNum: 1)
        }
    }
}
