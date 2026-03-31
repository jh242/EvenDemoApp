# BLE Auto-Reconnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically reconnect to the last-used G1 glasses on app launch, eliminating the manual scan+tap flow on every `flutter run`.

**Architecture:** Save the L/R peripheral UUIDs and device name to `UserDefaults` after a successful connection. On app launch, attempt `retrievePeripherals(withIdentifiers:)` to get the `CBPeripheral` objects back instantly. If they're available and connectable, connect automatically. If not (glasses off, out of range, reset), fall back to the existing manual scan flow. The Flutter side adds a `tryReconnect` method channel call that `home_page.dart` invokes on init.

**Tech Stack:** CoreBluetooth (`retrievePeripherals`), `UserDefaults`, Flutter `MethodChannel`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `ios/Runner/BluetoothManager.swift` | Modify | Add `saveLastConnected()`, `tryReconnectLastDevice()`, `UserDefaults` read/write |
| `ios/Runner/AppDelegate.swift` | Modify | Add `tryReconnect` case to method channel handler |
| `lib/ble_manager.dart` | Modify | Add `tryReconnect()` Dart method |
| `lib/views/home_page.dart` | Modify | Call `tryReconnect()` on init before showing scan UI |

---

### Task 1: Save peripheral UUIDs on successful connection (Swift)

**Files:**
- Modify: `ios/Runner/BluetoothManager.swift:114-153` (`centralManager(_:didConnect:)`)

The `didConnect` callback already detects when both L and R are connected and fires `glassesConnected` to Flutter. Right after that point, persist the UUIDs.

- [ ] **Step 1: Add a method to save connection info to UserDefaults**

Add this method to `BluetoothManager`:

```swift
private func saveLastConnected(deviceName: String, leftUUID: String, rightUUID: String) {
    let defaults = UserDefaults.standard
    defaults.set(deviceName, forKey: "lastDeviceName")
    defaults.set(leftUUID, forKey: "lastLeftUUID")
    defaults.set(rightUUID, forKey: "lastRightUUID")
}
```

- [ ] **Step 2: Call it from didConnect after both peripherals are connected**

In `centralManager(_:didConnect:)`, right after the `channel.invokeMethod("glassesConnected", ...)` call at ~line 150, add:

```swift
saveLastConnected(
    deviceName: deviceName,
    leftUUID: leftPeripheral.identifier.uuidString,
    rightUUID: rightPeripheral.identifier.uuidString
)
```

- [ ] **Step 3: Verify by building**

Run: `cd /Users/jackhu/Workspace/EvenDemoApp && flutter build ios --no-codesign --dart-define=ANTHROPIC_API_KEY=test 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/Runner/BluetoothManager.swift
git commit -m "feat(ble): save last-connected peripheral UUIDs to UserDefaults"
```

---

### Task 2: Add reconnect method to BluetoothManager (Swift)

**Files:**
- Modify: `ios/Runner/BluetoothManager.swift`

This method reads the saved UUIDs, calls `retrievePeripherals(withIdentifiers:)` to get `CBPeripheral` objects from CoreBluetooth's cache, and connects to them. If the peripherals aren't available (glasses off, out of range), it reports failure so Flutter can fall back to manual scan.

- [ ] **Step 1: Add tryReconnectLastDevice method**

Add this method to `BluetoothManager`:

```swift
func tryReconnectLastDevice(result: @escaping FlutterResult) {
    let defaults = UserDefaults.standard
    guard let deviceName = defaults.string(forKey: "lastDeviceName"),
          let leftUUIDStr = defaults.string(forKey: "lastLeftUUID"),
          let rightUUIDStr = defaults.string(forKey: "lastRightUUID"),
          let leftUUID = UUID(uuidString: leftUUIDStr),
          let rightUUID = UUID(uuidString: rightUUIDStr) else {
        result(false)
        return
    }

    let peripherals = centralManager.retrievePeripherals(withIdentifiers: [leftUUID, rightUUID])

    var foundLeft: CBPeripheral?
    var foundRight: CBPeripheral?
    for p in peripherals {
        if p.identifier.uuidString == leftUUIDStr { foundLeft = p }
        if p.identifier.uuidString == rightUUIDStr { foundRight = p }
    }

    guard let left = foundLeft, let right = foundRight else {
        result(false)
        return
    }

    // Store in pairedDevices so didConnect can find them
    pairedDevices[deviceName] = (left, right)
    currentConnectingDeviceName = deviceName

    centralManager.connect(left, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    centralManager.connect(right, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])

    result(true)
}
```

- [ ] **Step 2: Verify by building**

Run: `cd /Users/jackhu/Workspace/EvenDemoApp && flutter build ios --no-codesign --dart-define=ANTHROPIC_API_KEY=test 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
git add ios/Runner/BluetoothManager.swift
git commit -m "feat(ble): add tryReconnectLastDevice using retrievePeripherals"
```

---

### Task 3: Wire up the method channel (Swift + Dart)

**Files:**
- Modify: `ios/Runner/AppDelegate.swift:33-58` (switch statement)
- Modify: `lib/ble_manager.dart`

- [ ] **Step 1: Add `tryReconnect` case to AppDelegate**

In the `switch call.method` block in `AppDelegate.swift`, add a new case before `default`:

```swift
case "tryReconnect":
    self.blueInstance.tryReconnectLastDevice(result: result)
```

- [ ] **Step 2: Add `tryReconnect()` to Dart BleManager**

In `lib/ble_manager.dart`, add this method to the `BleManager` class:

```dart
Future<bool> tryReconnect() async {
  try {
    final result = await _channel.invokeMethod<bool>('tryReconnect');
    return result == true;
  } catch (e) {
    print('tryReconnect failed: $e');
    return false;
  }
}
```

- [ ] **Step 3: Verify by building**

Run: `cd /Users/jackhu/Workspace/EvenDemoApp && flutter build ios --no-codesign --dart-define=ANTHROPIC_API_KEY=test 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/Runner/AppDelegate.swift lib/ble_manager.dart
git commit -m "feat(ble): wire tryReconnect through method channel"
```

---

### Task 4: Call tryReconnect on app launch (Flutter)

**Files:**
- Modify: `lib/views/home_page.dart:23-29` (`initState`)

- [ ] **Step 1: Add auto-reconnect call in initState**

Replace the current `initState` in `home_page.dart`:

```dart
@override
void initState() {
  super.initState();
  BleManager.get().setMethodCallHandler();
  BleManager.get().startListening();
  BleManager.get().onStatusChanged = _refreshPage;
  _tryAutoReconnect();
}

Future<void> _tryAutoReconnect() async {
  final success = await BleManager.get().tryReconnect();
  if (!success) {
    // No saved device or glasses unavailable — user can scan manually
    print('Auto-reconnect failed, manual scan available');
  }
}
```

- [ ] **Step 2: Verify by building**

Run: `cd /Users/jackhu/Workspace/EvenDemoApp && flutter build ios --no-codesign --dart-define=ANTHROPIC_API_KEY=test 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 3: Test on device**

1. `flutter run` with glasses on — scan and connect manually (this saves UUIDs)
2. Stop the app (`Ctrl+C`)
3. `flutter run` again — should auto-connect without scanning

If it fails to reconnect (glasses were power-cycled between runs), the home page should show "Not connected" and the scan button works as before.

- [ ] **Step 4: Commit**

```bash
git add lib/views/home_page.dart
git commit -m "feat(ble): auto-reconnect to last glasses on app launch"
```

---

### Task 5: Handle edge case — CBCentralManager not ready at launch

**Files:**
- Modify: `ios/Runner/BluetoothManager.swift`

`retrievePeripherals` requires `centralManager.state == .poweredOn`. On a cold start, the manager might still be in `.unknown` state when `tryReconnect` is called. We need to queue the reconnect and execute it once Bluetooth is ready.

- [ ] **Step 1: Add pending reconnect support**

Add a property and modify `centralManagerDidUpdateState` in `BluetoothManager.swift`:

```swift
private var pendingReconnectResult: FlutterResult?
```

Then modify `tryReconnectLastDevice` — wrap the body after the `guard let` for UserDefaults in a state check:

```swift
func tryReconnectLastDevice(result: @escaping FlutterResult) {
    let defaults = UserDefaults.standard
    guard let deviceName = defaults.string(forKey: "lastDeviceName"),
          let leftUUIDStr = defaults.string(forKey: "lastLeftUUID"),
          let rightUUIDStr = defaults.string(forKey: "lastRightUUID"),
          let leftUUID = UUID(uuidString: leftUUIDStr),
          let rightUUID = UUID(uuidString: rightUUIDStr) else {
        result(false)
        return
    }

    if centralManager.state != .poweredOn {
        pendingReconnectResult = result
        return
    }

    performReconnect(deviceName: deviceName, leftUUID: leftUUID, rightUUID: rightUUID, leftUUIDStr: leftUUIDStr, rightUUIDStr: rightUUIDStr, result: result)
}

private func performReconnect(deviceName: String, leftUUID: UUID, rightUUID: UUID, leftUUIDStr: String, rightUUIDStr: String, result: @escaping FlutterResult) {
    let peripherals = centralManager.retrievePeripherals(withIdentifiers: [leftUUID, rightUUID])

    var foundLeft: CBPeripheral?
    var foundRight: CBPeripheral?
    for p in peripherals {
        if p.identifier.uuidString == leftUUIDStr { foundLeft = p }
        if p.identifier.uuidString == rightUUIDStr { foundRight = p }
    }

    guard let left = foundLeft, let right = foundRight else {
        result(false)
        return
    }

    pairedDevices[deviceName] = (left, right)
    currentConnectingDeviceName = deviceName

    centralManager.connect(left, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])
    centralManager.connect(right, options: [CBConnectPeripheralOptionNotifyOnDisconnectionKey: true])

    result(true)
}
```

- [ ] **Step 2: Fire pending reconnect when Bluetooth powers on**

Modify `centralManagerDidUpdateState` in `BluetoothManager.swift`:

```swift
func centralManagerDidUpdateState(_ central: CBCentralManager) {
    switch central.state {
    case .poweredOn:
        print("Bluetooth is powered on.")
        if let pendingResult = pendingReconnectResult {
            pendingReconnectResult = nil
            tryReconnectLastDevice(result: pendingResult)
        }
    case .poweredOff:
        print("Bluetooth is powered off.")
    default:
        print("Bluetooth state is unknown or unsupported.")
    }
}
```

- [ ] **Step 3: Verify by building**

Run: `cd /Users/jackhu/Workspace/EvenDemoApp && flutter build ios --no-codesign --dart-define=ANTHROPIC_API_KEY=test 2>&1 | tail -5`
Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
git add ios/Runner/BluetoothManager.swift
git commit -m "feat(ble): queue reconnect if Bluetooth not yet powered on at launch"
```
