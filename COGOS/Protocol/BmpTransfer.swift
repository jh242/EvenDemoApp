import Foundation

/// Transfers BMP images to the glasses via the 0x15 upload protocol, then
/// finalizes with 0x20 and a 0x16 CRC32 check. Ports `bmp_update_manager.dart`.
final class BmpTransfer {
    private let queue: BleRequestQueue
    private let bluetooth: BluetoothManager

    init(queue: BleRequestQueue, bluetooth: BluetoothManager) {
        self.queue = queue
        self.bluetooth = bluetooth
    }

    func updateBmp(lr: String, image: Data, startSeq: Int = 0) async -> Bool {
        let packLen = 194
        var multiPacks: [Data] = []
        var i = 0
        while i < image.count {
            let end = min(i + packLen, image.count)
            multiPacks.append(image.subdata(in: i..<end))
            i += packLen
        }

        for (index, pack) in multiPacks.enumerated() {
            if index < startSeq { continue }
            var data = Data()
            if index == 0 {
                data.append(contentsOf: [0x15, UInt8(index & 0xff), 0x00, 0x1c, 0x00, 0x00])
            } else {
                data.append(contentsOf: [0x15, UInt8(index & 0xff)])
            }
            data.append(pack)
            bluetooth.send(data, lr: lr)
            try? await Task.sleep(nanoseconds: 8_000_000) // 8 ms
        }

        // finish update
        var retries = 0
        let maxRetries = 10
        while true {
            if retries >= maxRetries { return false }
            let ret = await queue.request(Data([0x20, 0x0d, 0x0e]), lr: lr, timeoutMs: 3000)
            if let ret = ret {
                if ret.data.count >= 2, ret.data[1] == 0xc9 { break }
                return false
            }
            retries += 1
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }

        // CRC32 with prepended address bytes
        var withAddress = Data([0x00, 0x1c, 0x00, 0x00])
        withAddress.append(image)
        let crc = CRC32XZ.compute(withAddress)
        let crcBytes = Data([
            UInt8((crc >> 24) & 0xff),
            UInt8((crc >> 16) & 0xff),
            UInt8((crc >> 8) & 0xff),
            UInt8(crc & 0xff),
        ])
        var req = Data([0x16])
        req.append(crcBytes)
        guard let ret = await queue.request(req, lr: lr, timeoutMs: 2000) else { return false }
        if ret.data.count > 5, ret.data[5] != 0xc9 { return false }
        return true
    }

    /// Send to both arms concurrently.
    func sendToBoth(_ image: Data) async -> Bool {
        async let l = updateBmp(lr: "L", image: image)
        async let r = updateBmp(lr: "R", image: image)
        let (okL, okR) = await (l, r)
        return okL && okR
    }
}
