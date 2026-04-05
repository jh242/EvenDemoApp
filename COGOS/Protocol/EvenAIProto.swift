import Foundation

/// Even AI packet builder (0x4E).
/// Ports `evenaiMultiPackListV2` from `lib/services/evenai_proto.dart`.
enum EvenAIProto {
    static func multiPackListV2(cmd: UInt8, len: Int = 191, data: Data, syncSeq: Int,
                                newScreen: Int, pos: Int, currentPageNum: Int, maxPageNum: Int) -> [Data] {
        var send: [Data] = []
        var maxSeq = data.count / len
        if data.count % len > 0 { maxSeq += 1 }
        if maxSeq == 0 { maxSeq = 1 }

        // pos is int16, big-endian
        let posHigh = UInt8((pos >> 8) & 0xff)
        let posLow = UInt8(pos & 0xff)

        for seq in 0..<maxSeq {
            let start = seq * len
            var end = start + len
            if end > data.count { end = data.count }
            let chunk = data.count == 0 ? Data() : data.subdata(in: start..<end)

            var pack = Data([
                cmd,
                UInt8(syncSeq & 0xff),
                UInt8(maxSeq & 0xff),
                UInt8(seq & 0xff),
                UInt8(newScreen & 0xff),
                posHigh,
                posLow,
                UInt8(currentPageNum & 0xff),
                UInt8(maxPageNum & 0xff)
            ])
            pack.append(chunk)
            send.append(pack)
        }
        return send
    }
}
