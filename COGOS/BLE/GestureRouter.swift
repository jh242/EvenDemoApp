import Foundation

/// Routes `0xF5 0xXX` gesture events from the glasses to the appropriate handlers.
/// Ports the `0xF5` switch in `BleManager._handleReceivedData`.
@MainActor
final class GestureRouter {
    private let session: EvenAISession
    private let glance: GlanceService

    init(session: EvenAISession, glance: GlanceService) {
        self.session = session
        self.glance = glance
    }

    func handle(lr: String, notifyIndex: UInt8) {
        switch notifyIndex {
        case 0x00:
            break // DISPLAY_READY
        case 0x01: // SINGLE_TAP / page change
            if glance.isShowing {
                glance.dismiss()
            } else if lr == "L" {
                session.lastPageByTouchpad()
            } else {
                session.nextPageByTouchpad()
            }
        case 0x02: // HEAD_UP
            if lr == "R" && !session.isReceivingAudio && !session.isRunning {
                Task { await glance.showGlance() }
            }
        case 0x03: // HEAD_DOWN
            if glance.isShowing {
                glance.dismiss()
            }
        case 0x04, 0x05:
            session.resetSession()
        case 0x17: // TRIGGER_FOR_AI — long-press
            Task { await session.toStartEvenAIByOS() }
        case 0x18:
            Task { await session.recordOverByOS() }
        case 0x20: // DOUBLE_TAP
            if session.isRunning {
                session.exitAll()
            } else {
                Task { await glance.forceRefreshAndShow() }
            }
        default:
            print("Unhandled 0xF5 event: 0x\(String(format: "%02x", notifyIndex))")
        }
    }
}
