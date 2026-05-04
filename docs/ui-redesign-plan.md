# App UI Redesign Plan — Swift/Apple Design Language

## Context

COGOS is currently a functional developer/demo app for controlling Even Realities G1 glasses. The SwiftUI surface is small and useful, but it still reads as an engineering tool:

- `HomeView` uses plain rounded rectangles and the title "Even AI Demo".
- `FeaturesView` exposes dev-only routes (`BLE Probe`, `Text Send`) alongside user-facing settings.
- `BleProbeView` and `TextEntryView` are raw protocol/debug tools.
- Settings expose backend/configuration details directly and use local-development defaults.
- The app targets iOS 26+, so the redesign can lean on current Apple/SwiftUI patterns rather than custom chrome.

Intended outcome: make the app feel like a polished iOS companion app for G1 glasses while removing dev-only features from the primary user experience.

## Approach

Recommended direction: a native SwiftUI `TabView` companion-app shell with three user-centered areas:

1. **Home** — the operational dashboard: glasses connection state, scan/connect action, paired glasses discovery, battery, current assistant/session state, and short usage guidance. This is the panel users open when they want to know “are my glasses ready?” or “what is COGOS doing right now?”
2. **History** — a recall surface for completed voice interactions. `HistoryStore` already saves each query as `title`, response as `content`, and `createdTime`; the redesigned panel should show recent questions/responses so users can revisit answers that were previously only streamed to the glasses.
3. **Settings** — grouped configuration for LLM endpoint, voice, display, head-up, and notifications. Keep endpoint/API fields visible because this remains a configurable power-user app.

Design decisions:

- Replace `NavigationView`/hamburger-style `FeaturesView` with a modern `NavigationStack` inside each `TabView` tab (`Home`, `History`, `Settings`).
- Use system materials/colors (`.background`, `.secondarySystemGroupedBackground`, grouped `List`/`Form`, `Label`, SF Symbols) and larger semantic type styles instead of fixed-size rectangle buttons.
- Product-facing copy should use `COGOS` and avoid “Claude” branding. Implementation names such as `ClaudeSession` can stay for now; this plan is about user-visible UI language.
- Represent connection as a prominent status card with actions: scan/connect/disconnect, paired device rows, and battery chips once connected.
- Remove `BLE Probe` and `Text Transfer` from user navigation rather than gating them.
- Remove demo/protocol copy from the main UI: e.g. replace "Even AI Demo", "BLE Probe", raw pair/device labels, and raw command language with user-centered language.

## Files to modify

Likely implementation files:

- `COGOS/App/ContentView.swift` — app shell/navigation redesign.
- `COGOS/Views/HomeView.swift` — rebuild home as user-facing status/dashboard.
- `COGOS/Views/FeaturesView.swift` — remove from primary navigation; likely obsolete after introducing `TabView`.
- `COGOS/Views/HistoryListView.swift` — polish list/detail presentation.
- `COGOS/Views/SettingsView.swift` — regroup/copy-edit settings while keeping LLM endpoint/API fields visible.
- `COGOS/Views/NotificationSettingsView.swift` — make whitelist management feel user-facing.
- `COGOS/Views/BleProbeView.swift` — leave source file if useful internally, but remove all user navigation to it.
- `COGOS/Views/TextEntryView.swift` — leave source file if useful internally, but remove all user navigation to it.
- `COGOS/Platform/Settings.swift` — keep LLM endpoint fields available in Settings; no developer-mode gate needed for this redesign.

## Reuse

Existing state/services to reuse rather than reimplement:

- `BluetoothManager.connectionState`, `status`, `pairedDevices`, `isConnected`, `battery`, `startScan()`, `connectToGlasses(...)`, `disconnect()` in `COGOS/BLE/BluetoothManager.swift`.
- `EvenAISession.dynamicText`, `isSyncing`, `isRunning` in `COGOS/Session/EvenAISession.swift` for live assistant status.
- `HistoryStore.items`, `selectedIndex`, `toggle(index:)` in `COGOS/Models/HistoryStore.swift` for activity/history.
- `Settings` published properties in `COGOS/Platform/Settings.swift` for endpoint, voice, head-up, and display controls.
- `NotificationWhitelist` and `pushToGlasses(proto:)` in `COGOS/Platform/NotificationWhitelist.swift` for notification settings.
- Existing `AppState` environment-object wiring in `COGOS/App/AppState.swift` and `COGOS/App/COGOSApp.swift`.

## Steps

- [x] Redesign `ContentView` as a `TabView` with `NavigationStack` tabs for Home, History, and Settings.
- [x] Rebuild `HomeView` as the COGOS dashboard: connection readiness, scan/connect/disconnect, paired glasses, battery, live assistant state, and quick usage guidance.
- [x] Remove `FeaturesView` from primary navigation; do not expose `BleProbeView` or `TextEntryView` in the user UI.
- [x] Polish `HistoryListView` as the History tab using `HistoryStore.items`: question title, response preview/detail, timestamp, empty state, and optional clear/delete affordance if desired.
- [x] Keep `SettingsView` as the Settings tab with visible LLM endpoint/API fields plus voice, head-up, display, and notifications access.
- [x] Refresh `NotificationSettingsView` copy/layout so it explains what forwarding/whitelisting means.
- [x] Do a final copy pass so user-visible text says `COGOS`/assistant/glasses and not `Claude`, demo, BLE-probe, or raw protocol wording.

## Verification

- Build in Xcode after regenerating if needed (`xcodegen generate`, then build `COGOS.xcodeproj`).
- Run on a physical iOS device.
- Verify disconnected state: launch, auto-reconnect attempt, scan button, paired-glasses list, empty history.
- Verify connection flow: scan, connect pair, status updates, battery/status display, disconnect if implemented.
- Verify user navigation: Home, History, Settings/Notifications are discoverable; `BLE Probe` and `Text Transfer` are not reachable from the user UI.
- Verify settings still persist through `UserDefaults` and hardware commands still fire for display/head-up changes.
- Verify Dynamic Type, dark mode, VoiceOver labels, and touch targets for the redesigned screens.

## Decisions captured

- Use a bottom `TabView`.
- Home is justified as live readiness/control for the glasses and current assistant session.
- History is justified as recall for completed interactions already captured by `HistoryStore`.
- Remove user navigation to `BLE Probe` and `Text Transfer`.
- Keep LLM endpoint/API settings visible in Settings.
- Use `COGOS` in product-facing UI; avoid user-visible “Claude” references, while leaving implementation identifiers alone for this redesign.
