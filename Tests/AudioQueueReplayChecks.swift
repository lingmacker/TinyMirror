import AudioToolbox
import AVFoundation
import Foundation

private struct ArrivalFixture: Decodable {
    let arrivalsNs: [UInt64]
    let ntpUnavailableForNs: UInt64
    let ntpCorrectionAtPacket: Int
    let ntpCorrectionNs: UInt64
}

private func packets(_ path: String, count: Int) -> [Data] {
    var file: AudioFileID?
    precondition(AudioFileOpenURL(URL(fileURLWithPath: path) as CFURL, .readPermission, 0, &file) == noErr)
    defer { AudioFileClose(file!) }
    var maximum: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    precondition(AudioFileGetProperty(file!, kAudioFilePropertyPacketSizeUpperBound, &size, &maximum) == noErr)
    return (0..<count).map { index in
        var data = Data(count: Int(maximum))
        var length = maximum
        var one: UInt32 = 1
        var description = AudioStreamPacketDescription()
        precondition(data.withUnsafeMutableBytes {
            AudioFileReadPacketData(file!, false, &length, &description, Int64(index), &one, $0.baseAddress!)
        } == noErr && one == 1)
        return Data(data.prefix(Int(length)))
    }
}

private final class ReplayAudioRenderer: AVSampleBufferAudioRenderer {
    private let lock = NSLock()
    private var count = 0
    private var previous: CMTime?
    private var discontinuities = 0
    private var finishedFlushes = 0
    private let clock: CMTimebase
    private var minimumLead = Double.infinity
    private var lateCount = 0
    init(clock: CMTimebase) { self.clock = clock; super.init() }
    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let lead = (pts - CMTimebaseGetTime(clock)).seconds
        lock.withLock {
            if let previous, abs((pts - previous).seconds - 352.0 / 44100) > 0.000001 { discontinuities += 1 }
            previous = pts
            count += 1
            minimumLead = min(minimumLead, lead)
            if lead < 0 { lateCount += 1 }
        }
        super.enqueue(sampleBuffer)
    }
    override func flush() { super.flush(); lock.withLock { finishedFlushes += 1 } }
    var received: Int { lock.withLock { count } }
    var badInputTimes: Int { lock.withLock { discontinuities } }
    var flushCount: Int { lock.withLock { finishedFlushes } }
    var leastLead: Double { lock.withLock { minimumLead } }
    var latePackets: Int { lock.withLock { lateCount } }
}

@main
private enum AudioQueueReplayChecks {
    static func main() throws {
        precondition(CommandLine.arguments.count == 4, "usage: replay arrival.json tone.caf default|varispeed")
        let fixture = try JSONDecoder().decode(ArrivalFixture.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let data = packets(CommandLine.arguments[2], count: fixture.arrivalsNs.count)
        let layer = AVSampleBufferDisplayLayer()
        let renderer = ReplayAudioRenderer(clock: layer.sampleBufferRenderer.timebase)
        renderer.isMuted = true
        if CommandLine.arguments[3] == "varispeed" { renderer.audioTimePitchAlgorithm = .varispeed }
        let player = MediaPlayback(displayLayer: layer, audioRenderer: renderer)
        player.configureAudio(compressionType: 2, samplesPerFrame: 352, screenMirroring: false)
        player.flushAudio()
        let ready = Date().addingTimeInterval(3)
        while renderer.flushCount < 2, Date() < ready { Thread.sleep(forTimeInterval: 0.001) }
        precondition(renderer.flushCount == 2)
        let start = DispatchTime.now().uptimeNanoseconds
        let ntp = UInt64(Date().timeIntervalSince1970 * 1e9) + 1_750_000_000
        for index in fixture.arrivalsNs.indices {
            let target = start + fixture.arrivalsNs[index]
            while DispatchTime.now().uptimeNanoseconds < target {
                let remaining = target - min(target, DispatchTime.now().uptimeNanoseconds)
                Thread.sleep(forTimeInterval: Double(remaining) / 1e9)
            }
            let timestamp = fixture.arrivalsNs[index] < fixture.ntpUnavailableForNs ? 0
                : ntp + UInt64(index) * 352 * 1_000_000_000 / 44_100
                    + (index >= fixture.ntpCorrectionAtPacket ? fixture.ntpCorrectionNs : 0)
            data[index].withUnsafeBytes {
                player.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, data[index].count,
                                   compressionType: 2, timestamp: timestamp, rtpTimestamp: (UInt32.max - 500) &+ UInt32(index * 352))
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        precondition(renderer.received == data.count && renderer.badInputTimes == 0,
                     "Input was not complete/continuous; cannot attribute skips to the system output queue")
        precondition(renderer.status != .failed, "System decoder failed: \(String(describing: renderer.error))")
        precondition(CMTimebaseGetEffectiveRate(layer.sampleBufferRenderer.timebase) > 0.9, "A stopped clock is not a passing playback test")
        print("REPLAY pid=\(ProcessInfo.processInfo.processIdentifier) packets=\(renderer.received) inputGaps=\(renderer.badInputTimes) muted=\(renderer.isMuted) latePackets=\(renderer.latePackets) minLead=\(renderer.leastLead)")
        fflush(stdout)
        player.reset()
    }
}
