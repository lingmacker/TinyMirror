import Foundation
import CMirrorBridge

enum ReceiverEvent {
    case connected
    case disconnected
    case connReset(reason: Int)
    case videoPause
    case videoResume
    case videoFlush
    case clientInfo(deviceID: String, model: String, name: String)
    case sourceSize(width: Int, height: Int)
    case mirrorRunning(Bool)
}

/// Swift wrapper around the C AirPlay receiver core (single instance).
final class AirPlayReceiver {
    static let shared = AirPlayReceiver()

    /// Receiver-thread callbacks: copy packet bytes before returning. Timestamps are local Unix nanoseconds.
    var onVideo: ((UnsafePointer<UInt8>, Int, Bool, UInt64) -> Void)?
    var onAudio: ((UnsafePointer<UInt8>, Int, UInt8, UInt64, UInt32?) -> Void)?
    var onAudioFormat: ((UInt8, Int, Bool) -> Void)?
    var onAudioVolume: ((Float) -> Void)?
    var onAudioFlush: (() -> Void)?
    var onMediaReset: (() -> Void)?
    /// Called on the main thread.
    var onEvent: ((ReceiverEvent) -> Void)?
    var onLog: ((Int, String) -> Void)?

    private(set) var isRunning = false
    private let eventLock = NSLock()
    private var eventGeneration = 0
    private var audioUsesScreen = true
    private var audioRTPPosition: UInt32?
    private init() {}

    @discardableResult
    func start(name: String, resolution: MirrorResolution = .quadHD, frameRate: MirrorFrameRate = .standard, debug: Bool = false) -> Bool {
        guard !isRunning else { return true }
        var cbs = mb_callbacks_t()
        cbs.ctx = Unmanaged.passUnretained(self).toOpaque()
        cbs.on_video = { ctx, data, len, timestamp, _, isH265 in
            guard let ctx, let data else { return }
            let receiver = Unmanaged<AirPlayReceiver>.fromOpaque(ctx).takeUnretainedValue()
            receiver.onVideo?(data, Int(len), isH265 != 0, timestamp)
        }
        cbs.on_audio = { ctx, data, len, compressionType, timestamp in
            guard let ctx, let data else { return }
            let receiver = Unmanaged<AirPlayReceiver>.fromOpaque(ctx).takeUnretainedValue()
            let position = receiver.audioRTPPosition
            receiver.audioRTPPosition = nil
            receiver.onAudio?(data, Int(len), compressionType, timestamp, position)
        }
        cbs.on_event = { ctx, event, value, info in
            guard let ctx else { return }
            let receiver = Unmanaged<AirPlayReceiver>.fromOpaque(ctx).takeUnretainedValue()
            let infoString = info.map { String(cString: $0) }
            // Preserve native callback order for format/flush before subsequent audio packets.
            switch mb_event_t(rawValue: UInt32(bitPattern: event)) {
            case MB_EVENT_AUDIO_MODE:
                receiver.audioUsesScreen = value != 0
            case MB_EVENT_AUDIO_POSITION:
                receiver.audioRTPPosition = UInt32(bitPattern: value)
            case MB_EVENT_AUDIO_FORMAT:
                receiver.audioRTPPosition = nil
                guard let ct = UInt8(exactly: value) else { return }
                receiver.onAudioFormat?(ct, infoString.flatMap(Int.init) ?? 0, receiver.audioUsesScreen)
            case MB_EVENT_AUDIO_VOLUME:
                receiver.onAudioVolume?(Float(value) / 1000)
            case MB_EVENT_AUDIO_FLUSH:
                receiver.onAudioFlush?()
            case MB_EVENT_CONN_DESTROY, MB_EVENT_CONN_RESET:
                receiver.audioRTPPosition = nil
                receiver.onMediaReset?()
                receiver.handleEvent(event, value: Int(value), info: infoString)
            default:
                receiver.handleEvent(event, value: Int(value), info: infoString)
            }
        }
        cbs.on_log = { ctx, level, msg in
            guard let ctx, let msg else { return }
            let receiver = Unmanaged<AirPlayReceiver>.fromOpaque(ctx).takeUnretainedValue()
            receiver.onLog?(Int(level), String(cString: msg))
        }
        let result = mb_start_video_with_fps(name, &cbs, debug ? 1 : 0,
                                             Int32(resolution.width), Int32(resolution.rawValue),
                                             resolution.usesHEVC ? 1 : 0, Int32(frameRate.rawValue))
        isRunning = result == 0
        if !isRunning { eventLock.withLock { eventGeneration += 1 } }
        return isRunning
    }

    func stop() {
        guard isRunning else { return }
        mb_stop()
        // Stop joins native callbacks; invalidate their queued UI events before restarting.
        eventLock.withLock { eventGeneration += 1 }
        isRunning = false
        audioUsesScreen = true
        audioRTPPosition = nil
    }

    private func handleEvent(_ event: Int32, value: Int, info: String?) {
        let mapped: ReceiverEvent?
        switch mb_event_t(rawValue: UInt32(event)) {
        case MB_EVENT_CONN_INIT: mapped = .connected
        case MB_EVENT_CONN_DESTROY: mapped = .disconnected
        case MB_EVENT_CONN_RESET: mapped = .connReset(reason: value)
        case MB_EVENT_VIDEO_PAUSE: mapped = .videoPause
        case MB_EVENT_VIDEO_RESUME: mapped = .videoResume
        case MB_EVENT_VIDEO_FLUSH: mapped = .videoFlush
        case MB_EVENT_CLIENT_INFO:
            let parts = (info ?? "").components(separatedBy: "\t")
            mapped = .clientInfo(
                deviceID: parts.count > 0 ? parts[0] : "",
                model: parts.count > 1 ? parts[1] : "",
                name: parts.count > 2 ? parts[2] : "")
        case MB_EVENT_SOURCE_SIZE:
            let dims = (info ?? "").components(separatedBy: "x").compactMap { Int($0) }
            mapped = dims.count == 2 ? .sourceSize(width: dims[0], height: dims[1]) : nil
        case MB_EVENT_MIRROR_RUNNING: mapped = .mirrorRunning(value != 0)
        default: mapped = nil
        }
        if let mapped {
            let generation = eventLock.withLock { eventGeneration }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.eventLock.withLock({ self.eventGeneration }) == generation else { return }
                self.onEvent?(mapped)
            }
        }
    }
}
