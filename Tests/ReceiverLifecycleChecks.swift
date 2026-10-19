import AVFoundation
import Foundation
import CMirrorBridge

extension Bundle { static let module = Bundle.main }

private final class RecordingAudioRenderer: AVSampleBufferAudioRenderer {
    private let lock = NSLock()
    private var ready = true
    private var times: [CMTime] = []
    private var request: (DispatchQueue, @Sendable () -> Void)?
    override var isReadyForMoreMediaData: Bool { lock.withLock { ready } }
    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock { times.append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) }
    }
    override func flush() {}
    override func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        lock.withLock { request = (queue, block) }
    }
    override func stopRequestingMediaData() { lock.withLock { request = nil } }
    func setReady(_ value: Bool) { lock.withLock { ready = value } }
    var pendingRequest: (DispatchQueue, @Sendable () -> Void)? { lock.withLock { request } }
    var received: Int { lock.withLock { times.count } }
    var lastTime: CMTime? { lock.withLock { times.last } }
}

@main
private enum ReceiverLifecycleChecks {
    static func main() {
        let receiver = AirPlayReceiver.shared
        let layer = AVSampleBufferDisplayLayer()
        let renderer = RecordingAudioRenderer()
        renderer.isMuted = true
        let player = MediaPlayback(displayLayer: layer, audioRenderer: renderer)
        var resets = 0
        var uiEvents = 0
        receiver.onAudioFormat = { player.configureAudio(compressionType: $0, samplesPerFrame: $1, screenMirroring: $2) }
        receiver.onAudio = { player.handleAudio($0, $1, compressionType: $2, timestamp: $3, rtpTimestamp: $4) }
        receiver.onAudioFlush = { player.flushAudio() }
        // Match AppDelegate's media binding without creating its UI or discovery service.
        receiver.onMediaReset = { player.reset(); resets += 1 }
        receiver.onEvent = { _ in uiEvents += 1 }
        precondition(receiver.start(name: "No-network lifecycle check"))
        defer { receiver.stop(); player.reset() }
        let native = DispatchQueue(label: "test.native.receiver")
        let silent = try! Data(contentsOf: URL(fileURLWithPath: ".build/audio-tests/transported-alac-silence.bin"))
        func event(_ event: mb_event_t, _ value: Int32 = 0) { mb_test_event(Int32(event.rawValue), value, nil) }
        var audioPosition = UInt32.max - 700
        func audio(_ timestamp: UInt64) {
            event(MB_EVENT_AUDIO_POSITION, Int32(bitPattern: audioPosition))
            audioPosition &+= 352
            silent.withUnsafeBytes { mb_test_audio($0.bindMemory(to: UInt8.self).baseAddress!, Int32(silent.count), 2, timestamp) }
        }
        func connect(_ timestamp: UInt64, screen: Bool = false) {
            event(MB_EVENT_CONN_INIT)
            event(MB_EVENT_AUDIO_MODE, screen ? 1 : 0)
            "352".withCString { mb_test_event(Int32(MB_EVENT_AUDIO_FORMAT.rawValue), 2, $0) }
            audio(timestamp)
        }
        func waitWithoutMain(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(2)
            while !condition(), Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            precondition(condition(), "Receiver/playback did not progress while the UI was busy")
        }
        func timestamp() -> UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000_000_000) + 1_750_000_000 }
        native.sync { connect(timestamp()) }
        waitWithoutMain { renderer.received == 1 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        for iteration in 0..<32 {
            let next = timestamp()
            let uiBefore = uiEvents
            native.sync {
                event(iteration % 2 == 0 ? MB_EVENT_CONN_DESTROY : MB_EVENT_CONN_RESET)
                connect(next, screen: iteration % 3 == 1)
            }
            precondition(resets == iteration + 1 && uiEvents == uiBefore, "Media reset must run before delayed UI delivery")
            waitWithoutMain { renderer.received == iteration + 2 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            let current = CMTimebaseGetTime(layer.sampleBufferRenderer.timebase).seconds
            precondition(abs(current - Double(next) / 1e9) < 0.3,
                         "Old route disconnect erased the reconnected audio clock: current=\(current)")
        }
        print("PASS 32 rapid reconnects/reset events preserve the new audio clock, including mirroring mode transitions")

        // A saved old readiness callback must not bring back audio discarded at disconnect.
        renderer.setReady(false)
        native.sync { audio(timestamp()) }
        waitWithoutMain { renderer.pendingRequest != nil }
        let staleRequest = renderer.pendingRequest!
        let count = renderer.received
        let next = timestamp()
        native.sync { event(MB_EVENT_CONN_DESTROY); connect(next) }
        waitWithoutMain { renderer.pendingRequest != nil }
        renderer.setReady(true)
        staleRequest.0.async(execute: staleRequest.1)
        waitWithoutMain { renderer.received == count + 1 }
        precondition(abs(renderer.lastTime!.seconds - Double(next) / 1e9) < 0.000001,
                     "Old readiness callback replayed a pre-disconnect packet")
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(renderer.received == count + 1)
        print("PASS late renderer readiness cannot replay old-route audio after reconnect")

        native.sync { event(MB_EVENT_CONN_DESTROY) }
        let eventsBeforeStop = uiEvents
        receiver.stop()
        precondition(receiver.start(name: "No-network lifecycle restart"))
        let restarted = timestamp()
        native.sync { connect(restarted) }
        waitWithoutMain { renderer.received == count + 2 }
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        precondition(uiEvents == eventsBeforeStop + 1, "Stopped receiver delivered an old queued UI event")
        precondition(abs(CMTimebaseGetTime(layer.sampleBufferRenderer.timebase).seconds - Double(restarted) / 1e9) < 0.3)
        print("PASS receiver stop/start discards queued old UI notifications; no discovery or network opened")
    }
}
