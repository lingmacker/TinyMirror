import AVFoundation
import Foundation

private final class SampleClockRenderer: AVSampleBufferAudioRenderer {
    private let lock = NSLock()
    private var samples: [CMSampleBuffer] = []
    private let clock: CMTimebase
    private var onset: Double?
    init(clock: CMTimebase) { self.clock = clock; super.init() }
    override var isReadyForMoreMediaData: Bool { true }
    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let lead = (CMSampleBufferGetPresentationTimeStamp(sampleBuffer) - CMTimebaseGetTime(clock)).seconds
        lock.withLock { if onset == nil { onset = lead }; samples.append(sampleBuffer) }
    }
    override func flush() {}
    override func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {}
    override func stopRequestingMediaData() {}
    var times: [CMTime] { lock.withLock { samples.map(CMSampleBufferGetPresentationTimeStamp) } }
    var onsetLead: Double? { lock.withLock { onset } }
}

@main
private enum ALACSampleClockChecks {
    static func main() {
        let silence = try! Data(contentsOf: URL(fileURLWithPath: ".build/audio-tests/transported-alac-silence.bin"))
        let layer = AVSampleBufferDisplayLayer()
        let renderer = SampleClockRenderer(clock: layer.sampleBufferRenderer.timebase)
        renderer.isMuted = true
        let player = MediaPlayback(displayLayer: layer, audioRenderer: renderer)
        player.configureAudio(compressionType: 2, samplesPerFrame: 352, screenMirroring: false)
        let base = UInt32.max - 500
        let ntp = UInt64(Date().timeIntervalSince1970 * 1_000_000_000) + 1_750_000_000
        func send(_ position: UInt32, _ timestamp: UInt64) {
            silence.withUnsafeBytes {
                player.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, silence.count,
                                   compressionType: 2, timestamp: timestamp, rtpTimestamp: position)
            }
        }
        func waitFor(_ count: Int) {
            let end = Date().addingTimeInterval(2)
            while renderer.times.count < count, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
            precondition(renderer.times.count == count)
        }
        // Captured pattern: continuous RTP, initially zero NTP, burst delivery and a 43.50025 ms NTP correction.
        for index in 0..<16 {
            if index == 8 { Thread.sleep(forTimeInterval: 0.035) }
            let timestamp = index < 10 ? 0 : ntp + UInt64(index) * 352 * 1_000_000_000 / 44_100
                + (index >= 12 ? 43_500_250 : 0)
            send(base &+ UInt32(index * 352), timestamp)
        }
        waitFor(16)
        let times = renderer.times
        precondition(renderer.onsetLead! > 0.095 && renderer.onsetLead! < 0.14,
                     "Standalone ALAC needs the measured 120 ms budget, not seconds of delay")
        for index in 1..<times.count {
            let delta = (times[index] - times[index - 1]).seconds
            precondition(abs(delta - 352.0 / 44_100) < 0.000001,
                         "Continuous RTP was scheduled using arrival/NTP jitter: delta=\(delta), packet=\(index)")
        }
        let missing = base &+ UInt32(19 * 352)
        send(missing, ntp + 2_000_000_000)
        waitFor(17)
        precondition(abs((renderer.times[16] - times[15]).seconds - 4 * 352.0 / 44_100) < 0.000001,
                     "Real missing RTP samples must retain their duration")
        send(missing, ntp)
        send(missing &- 352, ntp)
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        precondition(renderer.times.count == 17, "Duplicate/backward RTP must not overlap audio")
        Thread.sleep(forTimeInterval: 1.1)
        send(missing &+ 352, UInt64(Date().timeIntervalSince1970 * 1_000_000_000) + 1_750_000_000)
        waitFor(18)
        let resumedLead = (renderer.times[17] - CMTimebaseGetTime(layer.sampleBufferRenderer.timebase)).seconds
        precondition(resumedLead > 0.03 && resumedLead < 0.2, "Paused RTP clock resumed in the past: lead=\(resumedLead)")
        player.flushAudio()
        send(42, 0)
        waitFor(19)
        let lead = (renderer.times[18] - CMTimebaseGetTime(layer.sampleBufferRenderer.timebase)).seconds
        precondition(lead > 0.03 && lead < 0.2, "Fresh RTP after flush must keep the short startup schedule")
        player.reset()
        let mirrorLayer = AVSampleBufferDisplayLayer()
        let mirrorRenderer = SampleClockRenderer(clock: mirrorLayer.sampleBufferRenderer.timebase)
        mirrorRenderer.isMuted = true
        let mirrorPlayer = MediaPlayback(displayLayer: mirrorLayer, audioRenderer: mirrorRenderer)
        mirrorPlayer.configureAudio(compressionType: 2, samplesPerFrame: 352, screenMirroring: true)
        silence.withUnsafeBytes {
            mirrorPlayer.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, silence.count,
                                     compressionType: 2, timestamp: ntp, rtpTimestamp: 0)
        }
        let end = Date().addingTimeInterval(2)
        while mirrorRenderer.onsetLead == nil, Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.002)) }
        precondition(mirrorRenderer.onsetLead != nil && mirrorRenderer.onsetLead! > 0.055 && mirrorRenderer.onsetLead! < 0.095,
                     "Mirroring must keep its original 80 ms budget")
        mirrorPlayer.reset()
        print("PASS ALAC sample clock: zero NTP, burst arrivals, NTP calibration/43.5 ms correction, RTP wrap/loss/duplicates and flush")
    }
}
