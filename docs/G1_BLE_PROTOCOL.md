# Even Realities G1 — BLE Protocol Reference

Compiled from the official EvenDemoApp, MentraOS `G1.swift`, `G1.java`, and `Enums.swift`.

---

## Transport

| Property | Value |
|----------|-------|
| UART Service UUID | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| TX Characteristic (write) | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| RX Characteristic (notify) | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |
| Negotiated MTU | 251 bytes |
| Max practical chunk | ~194 bytes (BMP) / ~180 bytes (JSON) |
| ACK byte | `0xC9` |

The G1 has **two independent BLE connections**, one per arm (L/R). Most commands go to both arms. Exceptions are noted below. Always send L first; wait for ACK before sending R. `BleManager.sendBoth()` / `BleManager.requestList()` handle this.

---

## Outbound Commands (App → Glasses)

### Connection init sequence
Sent immediately after both arms connect, in this order:

```
[0x6E, 0x74]            → both  — firmware version request
[0x4D, 0xFB]            → L only — init (Android)
[0x4D, 0x01]            → both  — init (iOS)
[0x27, 0x00]            → both  — disable wear detection
[0x03, 0x0A]            → both  — silent mode off
whitelist (0x04)         → both  — push app whitelist (see below)
brightness (0x01)        → both  — restore brightness setting
head-up angle (0x0B)     → both  — restore look-up angle setting
```

350ms delay after connect before sending init sequence (firmware needs time to be ready).

---

### Heartbeat — `0x25`
Keep-alive, sent every ~8 seconds.

```
[0x25, 0x06, seq, 0x00, 0x04, seq]
```

`seq` is a rolling `uint8` counter. Send to both arms. Also piggybacks a battery query on Android:
```
[0x2C, 0x01]   → Android
[0x2C, 0x02]   → iOS
```

---

### Microphone — `0x0E`
```
[0x0E, 0x01]   mic on  → R arm
[0x0E, 0x00]   mic off → R arm
```

On Android, MentraOS also sends a **"micbeat"** — repeating `[0x0E, 0x01]` every few seconds while mic is active, to prevent firmware timeout.

---

### Text / EvenAI Display — `0x4E`
Multi-packet. See `EvenaiProto.evenaiMultiPackListV2()` in the existing codebase for the full packet builder. Key header bytes:

```
[0x4E, seq, totalPkts, currentPkt, newScreen, charPos0, charPos1, pageNum, maxPages, ...utf8text]
```

`newScreen` byte:
- Upper nibble: `0x30` displaying (auto), `0x40` last page (auto), `0x50` manual, `0x60` error, `0x70` text show
- Lower nibble: `0x01` new content

---

### Brightness — `0x01`
```
[0x01, level, autoMode]
```
- `level`: 0–41 (maps from 0–100%). 0x00–0x29.
- `autoMode`: `0x01` = auto brightness on, `0x00` = manual

ACK: `[0x01, 0xC9]`

---

### Head-Up Angle — `0x0B`
Configures how far the user must tilt their head before `0xF5 0x02` fires.

```
[0x0B, angle, 0x01]
```
- `angle`: 0–60 (degrees). Clamped by firmware.

ACK: `[0x0B, 0xC9]`

---

### Dashboard Position — `0x26`
Sets the Y position (height) and Z depth of the dashboard overlay.

```
[0x26, 0x08, 0x00, counter, 0x02, 0x01, height, depth]
```
- `counter`: rolling `uint8`, must increment on each call.
- `height`: 0–8
- `depth`: 1–9
- **Left arm only.**

ACK: `[0x26, 0x06]` (the 0x06 is hardcoded in firmware; MentraOS notes "seems arbitrary").

---

### Silent Mode — `0x03`
```
[0x03, 0x0C, 0x00]   silent on
[0x03, 0x0A, 0x00]   silent off
```

ACK: `[0x03, 0xC9]`

---

### Exit / Home — `0x18`
Returns glasses to dashboard. **Left arm only**, with ~100ms post-send delay.

```
[0x18]
```

ACK: `[0x18, 0xC9]`

---

### Notification Whitelist — `0x04`
Chunked JSON. Max 176 bytes payload per chunk.

```
Header per chunk: [0x04, totalChunks, chunkIndex, 0x00] + jsonPayload
```

JSON body (see `NotifyWhitelistModel.toJson()`):
```json
{
  "calendar_enable": false,
  "call_enable": false,
  "msg_enable": false,
  "ios_mail_enable": false,
  "app": {
    "list": [{"id": "com.example.app", "name": "App Name"}],
    "enable": true
  }
}
```

ACK sequence: glasses first send `[0x04, 0xCB]` per chunk ("continue"), then `[0x04, 0xC9]` at the end.

---

### Notification Send — `0x4B`
Push a notification to the display. Chunked JSON, max 176 bytes payload per chunk.

```
Header per chunk: [0x4B, notifyId, totalChunks, chunkIndex] + jsonPayload
```

JSON body:
```json
{
  "msg_id": 1234567890,
  "app_identifier": "com.example.app",
  "title": "Title",
  "subtitle": "Subtitle",
  "message": "Body text",
  "time_s": 1711234567,
  "display_name": "App Name"
}
```

`notifyId` is a rolling 0–255 counter.

---

### Quick Note — `0x1E`

**Add/update** (slot 0-based, up to a firmware-defined max):
```
[0x1E, payloadLen, 0x00, versionByte,
 0x03, 0x01, 0x00, 0x01, 0x00,   ← fixed bytes
 slotNumber,
 0x01,
 nameLen, ...name bytes,
 textLen, 0x00, ...text bytes]
```
`versionByte` = `(unix_timestamp % 256)` — used by firmware to detect staleness.

**Delete** (by slot number):
```
[0x1E, 0x10, 0x00, 0xE0,
 0x03, 0x01, 0x00, 0x01, 0x00,   ← fixed bytes
 noteNumber,
 0x00, 0x01, 0x00, 0x01, 0x00, 0x00]
```

ACK: `[0x1E, 0x10]` or `[0x1E, 0x43]`

---

### BMP Image — `0x15` / `0x20` / `0x16`
1-bit 576×136px BMP. Sent in 194-byte chunks.

**Chunk format:**
```
First chunk:  [0x15, seq, 0x00, 0x1C, 0x00, 0x00, ...194 bytes of BMP data]
Other chunks: [0x15, seq, ...194 bytes of BMP data]
```
`seq` is chunk index (0-based uint8).

**End command** (after all chunks):
```
[0x20, 0x0D, 0x0E]
```

**CRC check** — `0x16`:
CRC32-XZ (big-endian) of the full BMP data including the storage address prefix. See `Proto` crc methods.

Send all chunks to both arms simultaneously (not sequentially L→R like other commands).

> **Note:** MentraOS inverts BMP pixel bits before sending (`invertBmpPixels()`). The official EvenDemoApp does not — test both if images look wrong.

---

## Inbound Events (Glasses → App)

### Touch / gesture — `0xF5 0xNN`

| `data[1]` | Event | Notes |
|-----------|-------|-------|
| `0x00` | Double-tap | Exit or toggle recording |
| `0x01` | Single-tap | Page navigation |
| `0x02` | **Head up** | User tilted head up past configured angle |
| `0x03` | Head down | User tilted head back down |
| `0x04` | Triple-tap (L) | Mode cycle / session reset |
| `0x05` | Triple-tap (R) | Mode cycle / session reset |
| `0x06` | Case removed | Glasses taken out of case |
| `0x07` | Case removed (alt) | Glasses taken out of case |
| `0x08` | Case opened | Case lid opened |
| `0x0B` | Case closed | Case lid closed |
| `0x0E` | Case charging state | `data[2]`: `0x01` = charging |
| `0x0F` | Case battery level | `data[2]`: battery % |
| `0x17` | EvenAI start | Long-press L or "Hey Even" wake word |
| `0x18` | EvenAI stop | Release trigger / stop recording |

---

### Audio — `0xF1`
```
data[0] = 0xF1
data[1] = seq      ← sequence number
data[2..201]       ← 200 bytes of LC3-encoded audio
```

---

### Battery response — `0x2C 0x66`
```
data[0] = 0x2C
data[1] = 0x66
data[2..] ← battery info (format TBD, check raw logs)
```

---

### Heartbeat response — `0x25`
```
data[0] = 0x25
data[1] = counter  ← mirrors seq from request
```

---

### EvenAI display ack — `0x4E`
```
data[0] = 0x4E
data[1] = seq
```

---

## Unknown Commands

| Hex | Enum name | Notes |
|-----|-----------|-------|
| `0x39` | `UNK_2` | ACKed with `0xC9`; purpose unknown |
| `0x50` | `UNK_1` | ACKed with `0xC9`; purpose unknown |

Worth probing: send `[0x39]` and `[0x50]` while logging all responses to discover function.

---

## Full Command Enum (from `Enums.swift`)

| Name | Hex |
|------|-----|
| `BRIGHTNESS` | `0x01` |
| `SILENT_MODE` | `0x03` |
| `WHITELIST` | `0x04` |
| `DASHBOARD_SHOW` | `0x06` |
| `HEAD_UP_ANGLE` | `0x0B` |
| `BLE_REQ_MIC_ON` | `0x0E` |
| `BLE_REQ_TRANSFER_MIC_DATA` | `0xF1` |
| `QUICK_NOTE_ADD` | `0x1E` |
| `BMP_END` | `0x20` |
| `BLE_REQ_HEARTBEAT` | `0x25` |
| `DASHBOARD_LAYOUT_COMMAND` | `0x26` |
| `BLE_REQ_BATTERY` | `0x2C` |
| `UNK_2` | `0x39` |
| `BLE_REQ_INIT` | `0x4D` |
| `BLE_REQ_EVENAI` | `0x4E` |
| `NOTIFICATION` | `0x4B` |
| `UNK_1` | `0x50` |
| `CRC_CHECK` | `0x16` |
| `BLE_EXIT_ALL_FUNCTIONS` | `0x18` |
| `BLE_REQ_DEVICE_ORDER` | `0xF5` |

---

## Source references

- `MentraOS/mobile/modules/core/ios/Source/sgcs/G1.swift`
- `MentraOS/mobile/modules/core/android/src/main/java/com/mentra/core/sgcs/G1.java`
- `MentraOS/mobile/modules/core/ios/Source/utils/Enums.swift`
- `even-realities/EvenDemoApp` (official Flutter demo)
