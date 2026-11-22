import AppKit
import Foundation

@main
private enum BluetoothHIDChecks {
    static func main() {
        checkReportMapsAndPayloads()
        checkControlLayoutAndKeyboard()
        checkConnectionState()
        checkReconnectTracker()
        print("PASS Bluetooth HID reports, coordinate layout, keyboard map, connection state, and reconnect tracker")
    }

    private static func checkReportMapsAndPayloads() {
        precondition(HIDReportMap.primaryReports == [.keyboard, .relativeMouse, .consumer])
        precondition(HIDReportMap.absoluteReports == [.absolutePointer])
        precondition(
            HIDReportMap.descriptor(for: HIDReportMap.primaryReports)
                == HIDReportMap.keyboard + HIDReportMap.relativeMouse + HIDReportMap.consumer)
        precondition(HIDReportMap.descriptor(for: HIDReportMap.absoluteReports) == HIDReportMap.absolutePointer)
        precondition(HIDReportID.keyboard.rawValue == 1 && HIDReportID.keyboard.reportLength == 8)
        precondition(HIDReportID.absolutePointer.rawValue == 2 && HIDReportID.absolutePointer.reportLength == 5)
        precondition(HIDReportID.relativeMouse.rawValue == 3 && HIDReportID.relativeMouse.reportLength == 4)
        precondition(HIDReportID.consumer.rawValue == 4 && HIDReportID.consumer.reportLength == 2)

        precondition(HIDReportPayload.relativeMouse(buttons: 1, dx: -300, dy: 300, wheel: -200) == [1, 129, 127, 129])
        precondition(HIDReportPayload.relativeMouse(buttons: 0, dx: -2, dy: 3, wheel: 1) == [0, 254, 3, 1])
        precondition(HIDReportPayload.absolutePointer(buttons: 1, normalizedX: 0, normalizedY: 1) == [1, 0, 0, 0xFF, 0x7F])
        precondition(HIDReportPayload.absolutePointer(buttons: 0, normalizedX: 1, normalizedY: 0) == [0, 0xFF, 0x7F, 0, 0])
        precondition(HIDReportPayload.keyboard(modifiers: 0x08, code: 0x19) == [0x08, 0, 0x19, 0, 0, 0, 0, 0])
        precondition(HIDReportPayload.consumer(HIDReportPayload.consumerHome) == [0x23, 0x02])
    }

    private static func checkControlLayoutAndKeyboard() {
        let layout = MirrorControlLayout(
            videoSize: CGSize(width: 900, height: 1800),
            bounds: CGRect(x: 0, y: 0, width: 600, height: 600))!
        precondition(abs(layout.imageRect.origin.x - 150) < 0.01 && abs(layout.imageRect.width - 300) < 0.01)
        precondition(layout.normalizedPoint(CGPoint(x: 50, y: 300), clamp: false) == nil)
        let clamped = layout.normalizedPoint(CGPoint(x: 50, y: 600), clamp: true)!
        precondition(abs(clamped.x - 0) < 0.001 && abs(clamped.y - 0) < 0.001)
        let bottomRight = layout.normalizedPoint(CGPoint(x: 450, y: 0), clamp: true)!
        precondition(abs(bottomRight.x - 1) < 0.001 && abs(bottomRight.y - 1) < 0.001)

        precondition(HIDKeyboardMap.stroke(for: "a") == .init(code: 0x04, modifiers: 0))
        precondition(HIDKeyboardMap.stroke(for: "A") == .init(code: 0x04, modifiers: HIDKeyboardMap.shift))
        precondition(HIDKeyboardMap.stroke(for: "!") == .init(code: 0x1E, modifiers: HIDKeyboardMap.shift))
        precondition(HIDKeyboardMap.code(for: "enter") == 0x28)
        precondition(HIDKeyboardMap.modifierMask(for: ["cmd", "shift"]) == 0x0A)

        let paste = MirrorKeyboardEvent(
            keyCode: 0x09, modifierFlags: [.command, .shift], characters: "V", charactersIgnoringModifiers: "v")
        precondition(paste.command == .key("v", modifiers: ["cmd"]))
        let enter = MirrorKeyboardEvent(keyCode: 0x24)
        precondition(enter.command == .key("enter", modifiers: []))
        let typed = MirrorKeyboardEvent(keyCode: 0x00, modifierFlags: [.shift], characters: "A", charactersIgnoringModifiers: "a")
        precondition(typed.command == .text("A", modifiers: []))
    }

    private static func checkConnectionState() {
        let phone = UUID()
        let watch = UUID()
        var state = BluetoothHIDConnectionState()

        state.subscribe(.report(.keyboard), host: watch)
        state.subscribe(.report(.keyboard), host: phone)
        state.subscribe(.report(.absolutePointer), host: phone)
        precondition(state.preferredInputHost() == phone, "Host with AssistiveTouch absolute pointer must be preferred")

        let session = state.sessions[phone]!
        precondition(state.isReady(report: .absolutePointer, host: phone, session: session))
        precondition(!state.isReady(report: .relativeMouse, host: phone, session: session))

        // Idle hover coalesces; button press and held drags do not.
        state.enqueue(.report(.absolutePointer), data: Data([0, 1, 0, 1, 0]), host: phone, session: session)
        state.enqueue(.report(.absolutePointer), data: Data([0, 2, 0, 2, 0]), host: phone, session: session)
        state.enqueue(.report(.absolutePointer), data: Data([1, 2, 0, 2, 0]), host: phone, session: session)
        state.enqueue(.report(.absolutePointer), data: Data([1, 3, 0, 3, 0]), host: phone, session: session)
        precondition(state.pending.map(\.data) == [
            Data([0, 2, 0, 2, 0]),
            Data([1, 2, 0, 2, 0]),
            Data([1, 3, 0, 3, 0]),
        ])

        // Excluding a backpressured host must still drain another subscribed host.
        let watchSession = state.sessions[watch]!
        state.enqueue(.report(.keyboard), data: Data([0, 0, 4, 0, 0, 0, 0, 0]), host: watch, session: watchSession)
        let nextWatch = state.nextPendingReportIndex(excludingHosts: [phone])!
        precondition(nextWatch.report.host == watch)
        state.removePending(at: nextWatch.index)

        // Drain phone reports and verify absolute release reuses last accepted BLE position.
        while let next = state.nextPendingReportIndex() {
            state.removePending(at: next.index)
        }
        state.enqueue(
            .report(.absolutePointer),
            data: Data([0, 99, 0, 99, 0]),
            host: phone,
            session: session,
            absoluteRelease: true)
        let release = state.nextPendingReportIndex()!
        precondition(release.report.data == Data([0, 3, 0, 3, 0]))
        state.removePending(at: release.index)

        // Disconnect invalidates old session token.
        state.unsubscribe(.report(.keyboard), host: phone)
        precondition(state.sessions[phone] == session)
        state.unsubscribe(.report(.absolutePointer), host: phone)
        precondition(state.sessions[phone] == nil)
        state.subscribe(.report(.absolutePointer), host: phone)
        let newSession = state.sessions[phone]!
        precondition(newSession != session)
        state.enqueue(.report(.absolutePointer), data: Data([0, 5, 0, 5, 0]), host: phone, session: session)
        precondition(state.pending.isEmpty, "Stale session reports must be ignored")
    }

    private static func checkReconnectTracker() {
        let host = UUID()
        var tracker = BluetoothHIDReconnectTracker()
        precondition(tracker.updateTargets([host], activeSessions: [], resetExhausted: true).isEmpty)
        precondition(tracker.connectableHosts(activeSessions: []) == [host])

        let attempt1 = tracker.beginConnecting(host)
        precondition(tracker.markTimedOut(host: host, attempt: attempt1, hasActiveSession: false))
        precondition(tracker.updateTargets([host], activeSessions: [], resetExhausted: true).isEmpty)
        precondition(tracker.connectableHosts(activeSessions: []).isEmpty)
        precondition(tracker.handleTermination(host: host, hasActiveSession: false) == .retryNow)

        let attempt2 = tracker.beginConnecting(host)
        precondition(attempt2 != attempt1)
        tracker.noteSessionEstablished(host)
        precondition(tracker.attemptsUsed[host] == 0)
        precondition(tracker.reconnectingHosts(activeSessions: [host]).isEmpty)

        // Mid-session disconnect cancels stale central link and retries cleanly.
        precondition(tracker.updateTargets([host], activeSessions: [], resetExhausted: false) == [host])
        precondition(tracker.handleTermination(host: host, hasActiveSession: false) == .retryNow)
    }
}
