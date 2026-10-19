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
        precondition(receiver.start(name: "No-network RTP position check"))
        var position: UInt32?
        var audioCount = 0
        receiver.onAudio = { _, _, _, _, value in position = value; audioCount += 1 }
        let positionEvent = Int32(MB_EVENT_AUDIO_POSITION.rawValue)
        let bytes: [UInt8] = [0]
        func audio() { bytes.withUnsafeBufferPointer { mb_test_audio($0.baseAddress!, 1, 2, 0) } }
        for value: UInt32 in [0, .max, 0x80000000, 352] {
            mb_test_event(positionEvent, Int32(bitPattern: value), nil)
            audio()
            precondition(position == value)
            audio()
            precondition(position == nil, "Legacy packet reused previous RTP position")
        }
        mb_test_event(positionEvent, 123, nil)
        "352".withCString { mb_test_event(event, 2, $0) }
        audio()
        precondition(position == nil)
        mb_test_event(positionEvent, 123, nil)
        receiver.stop()
        precondition(receiver.start(name: "No-network RTP position restart"))
        audio()
        precondition(position == nil && audioCount == 10)
        receiver.stop()
        print("PASS native-to-Swift format/mode, paired/wrapped RTP positions, legacy core and cleanup; no network opened")
    }
}
