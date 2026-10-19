import Foundation
import CMirrorBridge

extension Bundle { static let module = Bundle.main }

@main
private enum ReceiverFormatChecks {
    static func main() {
        let receiver = AirPlayReceiver.shared
        var received: (UInt8, Int, Bool)?
        receiver.onAudioFormat = { received = ($0, $1, $2) }
        let event = Int32(MB_EVENT_AUDIO_FORMAT.rawValue)
        let modeEvent = Int32(MB_EVENT_AUDIO_MODE.rawValue)
        let cases: [(Int32, String, Int, Bool, Int32?)] = [
            (2, "352", 352, false, 0), (8, "480", 480, true, 1),
            (2, "352", 352, true, 1), (8, "480", 480, true, nil),
            (2, "352", 352, false, 0), (2, "352", 352, true, nil),
            (8, "invalid", 0, true, nil)
        ]
        for (ct, info, frames, screen, mode) in cases {
            precondition(receiver.start(name: "No-network format check"))
            received = nil
            if let mode { mb_test_event(modeEvent, mode, nil) }
            info.withCString { mb_test_event(event, ct, $0) }
            precondition(received?.0 == UInt8(ct) && received?.1 == frames && received?.2 == screen)
            receiver.stop()
        }
        precondition(receiver.start(name: "No-network format check"))
        received = nil
        mb_test_event(event, 256, nil)
        precondition(received == nil)
        receiver.stop()
        print("PASS native-to-Swift format delivery, standalone/screen flags, legacy core and invalid format handling; no network opened")
    }
}
