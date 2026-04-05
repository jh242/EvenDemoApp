import SwiftUI

struct BmpView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var bluetooth: BluetoothManager
    @State private var status: String = "Select a BMP from bundle to send."

    var body: some View {
        VStack(spacing: 16) {
            Text(status).padding()
            Button("Send bundled image.bmp") {
                Task { await sendBundled() }
            }.disabled(!bluetooth.isConnected)
            Spacer()
        }
        .padding()
        .navigationTitle("BMP Transfer")
    }

    private func sendBundled() async {
        guard let url = Bundle.main.url(forResource: "image", withExtension: "bmp"),
              let data = try? Data(contentsOf: url) else {
            status = "image.bmp not found in bundle"
            return
        }
        status = "Sending..."
        let transfer = BmpTransfer(queue: appState.requestQueue, bluetooth: bluetooth)
        let ok = await transfer.sendToBoth(data)
        status = ok ? "Sent OK" : "Failed"
    }
}
