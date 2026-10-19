import AudioToolbox
import AVFoundation
import CoreMedia
import Foundation

private func check(_ status: OSStatus, _ operation: String) {
    precondition(status == noErr, "\(operation): OSStatus \(status)")
}

private func waitFor(_ condition: () -> Bool) {
    let end = Date().addingTimeInterval(2)
    while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    precondition(condition(), "Timed out waiting for media renderer")
}

private func packets(_ filename: String) -> [Data] {
    var file: AudioFileID?
    check(AudioFileOpenURL(URL(fileURLWithPath: ".build/audio-tests/\(filename).caf") as CFURL,
                          .readPermission, 0, &file), "open fixture")
    defer { AudioFileClose(file!) }
    var maximum: UInt32 = 0
    var count: UInt64 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    check(AudioFileGetProperty(file!, kAudioFilePropertyPacketSizeUpperBound, &size, &maximum), "packet size")
    size = UInt32(MemoryLayout<UInt64>.size)
    check(AudioFileGetProperty(file!, kAudioFilePropertyAudioDataPacketCount, &size, &count), "packet count")
    return (0..<count).map { index in
        var bytes = Data(count: Int(maximum))
        var length = maximum
        var one: UInt32 = 1
        var description = AudioStreamPacketDescription()
        check(bytes.withUnsafeMutableBytes {
            AudioFileReadPacketData(file!, false, &length, &description, Int64(index), &one, $0.baseAddress!)
        }, "read packet")
        precondition(one == 1)
        return Data(bytes.prefix(Int(length)))
    }
}

private final class PacketFeed {
    let packets: [Data]
    var index = 0
    var current: NSData?
    let description = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
    init(_ packets: [Data]) {
        self.packets = packets
        description.initialize(to: AudioStreamPacketDescription())
    }
    deinit { description.deinitialize(count: 1); description.deallocate() }
}

/// Decode using only the production format description/cookie, not the fixture's metadata.
private func decode(_ packets: [Data], format: AirPlayAudioFormat, expectSilence: Bool = false) {
    var input = CMAudioFormatDescriptionGetStreamBasicDescription(format.description)!.pointee
    var output = AudioStreamBasicDescription(
        mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
        mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
    var converter: AudioConverterRef?
    check(AudioConverterNew(&input, &output, &converter), "create decoder")
    defer { AudioConverterDispose(converter!) }
    var cookieSize = 0
    if let cookie = CMAudioFormatDescriptionGetMagicCookie(format.description, sizeOut: &cookieSize), cookieSize > 0 {
        check(AudioConverterSetProperty(converter!, kAudioConverterDecompressionMagicCookie,
                                        UInt32(cookieSize), cookie), "decoder cookie")
    }
    let feed = PacketFeed(packets)
    var energy: Double = 0
    var samples = 0
    var decoded: [Float] = []
    for _ in 0..<100 {
        var pcm = [Float](repeating: 0, count: 4096 * 2)
        var frames: UInt32 = 4096
        let status = pcm.withUnsafeMutableBytes { bytes -> OSStatus in
            var buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(
                mNumberChannels: 2, mDataByteSize: UInt32(bytes.count), mData: bytes.baseAddress))
            return AudioConverterFillComplexBuffer(converter!, { _, count, data, descriptions, context in
                let feed = Unmanaged<PacketFeed>.fromOpaque(context!).takeUnretainedValue()
                guard feed.index < feed.packets.count else { count.pointee = 0; return noErr }
                feed.current = feed.packets[feed.index] as NSData
                feed.index += 1
                let packet = feed.current!
                feed.description.pointee = AudioStreamPacketDescription(
                    mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(packet.length))
                data.pointee.mNumberBuffers = 1
                data.pointee.mBuffers = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(packet.length),
                                                    mData: UnsafeMutableRawPointer(mutating: packet.bytes))
                descriptions?.pointee = feed.description
                count.pointee = 1
                return noErr
            }, Unmanaged.passUnretained(feed).toOpaque(), &frames, &buffers, nil)
        }
        check(status, "decode")
        if frames == 0 { break }
        for sample in pcm.prefix(Int(frames) * 2) {
            precondition(sample.isFinite)
            energy += Double(sample * sample)
            samples += 1
            decoded.append(sample)
        }
    }
    let rms = sqrt(energy / Double(samples))
    if expectSilence {
        precondition(samples == packets.count * Int(input.mFramesPerPacket) * 2 && energy == 0,
                     "Transported ALAC silence must decode to complete, exact-zero PCM frames")
        print("PASS transported 32-byte ALAC silence decodes to full-duration zero PCM")
        return
    }
    precondition(samples > 10_000 && rms > 0.05 && rms < 0.13, "Decoded audio is silent, attenuated, or clipped")
    let frames = decoded.count / 2
    let trim = min(4096, frames / 4)
    var minimumPurity = 1.0
    for channel in 0..<2 {
        let frequency = channel == 0 ? 440.0 : 660.0
        var sine: Double = 0, cosine: Double = 0, power: Double = 0
        for frame in trim..<(frames - trim) {
            let x = Double(decoded[frame * 2 + channel])
            let phase = 2 * Double.pi * frequency * Double(frame) / 44_100
            sine += x * sin(phase)
            cosine += x * cos(phase)
            power += x * x
        }
        let count = Double(frames - 2 * trim)
        let purity = 2 * (sine * sine + cosine * cosine) / (count * power)
        precondition(purity > 0.97, "Decoded stereo has discontinuities/noise or the wrong sample rate")
        minimumPurity = min(minimumPurity, purity)
    }
    print(String(format: "  waveform ct=%d RMS=%.4f stereo purity=%.5f", format.compressionType, rms, minimumPurity))
}

private func packetData(_ sample: CMSampleBuffer) -> Data {
    let block = CMSampleBufferGetDataBuffer(sample)!
    let length = CMBlockBufferGetDataLength(block)
    var result = Data(count: length)
    check(result.withUnsafeMutableBytes {
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
    }, "copy received packet")
    return result
}

private final class WarmingAudioRenderer: AVSampleBufferAudioRenderer {
    private let lock = NSLock()
    private var ready = false
    private var received: [CMSampleBuffer] = []
    private var flushes = 0
    private var nextFlushDelay: TimeInterval = 0
    private var request: (DispatchQueue, @Sendable () -> Void)?
    override var isReadyForMoreMediaData: Bool { lock.withLock { ready } }
    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock { received.append(sampleBuffer) }
    }
    override func requestMediaDataWhenReady(on queue: DispatchQueue, using block: @escaping @Sendable () -> Void) {
        let ready = lock.withLock { request = (queue, block); return self.ready }
        if ready { queue.async(execute: block) }
    }
    override func stopRequestingMediaData() { lock.withLock { request = nil } }
    override func flush() {
        let delay = lock.withLock { let delay = nextFlushDelay; nextFlushDelay = 0; flushes += 1; return delay }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
    }
    func stallNextFlush(_ delay: TimeInterval) { lock.withLock { nextFlushDelay = delay } }
    var flushCount: Int { lock.withLock { flushes } }
    func finishWarmingUp() {
        let request = lock.withLock { ready = true; return self.request }
        if let request { request.0.async(execute: request.1) }
    }
    var receivedCount: Int { lock.withLock { received.count } }
    var firstSample: CMSampleBuffer? { lock.withLock { received.first } }
    var receivedTimes: [CMTime] { lock.withLock { received.map(CMSampleBufferGetPresentationTimeStamp) } }
    var receivedPackets: [Data] { lock.withLock { received.map(packetData) } }
}

/// Uses the real system decoder/output queue, muted, while measuring scheduling.
private final class ColdAudioRenderer: AVSampleBufferAudioRenderer {
    private let lock = NSLock()
    private let clock: CMTimebase
    private var count = 0
    private var minimumLead = Double.infinity
    private var flushDelay: TimeInterval = 0
    init(clock: CMTimebase) { self.clock = clock; super.init() }
    override func enqueue(_ sampleBuffer: CMSampleBuffer) {
        let lead = (CMSampleBufferGetPresentationTimeStamp(sampleBuffer) - CMTimebaseGetTime(clock)).seconds
        lock.withLock { count += 1; minimumLead = min(minimumLead, lead) }
        super.enqueue(sampleBuffer)
    }
    override func flush() {
        let delay = lock.withLock { let delay = flushDelay; flushDelay = 0; return delay }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        super.flush()
    }
    func stallNextFlush(_ delay: TimeInterval) { lock.withLock { flushDelay = delay } }
    var receivedCount: Int { lock.withLock { count } }
    var leastLead: Double { lock.withLock { minimumLead } }
}

@main
private enum MediaPlaybackChecks {
    static func main() {
        setbuf(stdout, nil)
        precondition(AirPlayAudioFormat(compressionType: 0) == nil)
        precondition(AirPlayAudioFormat(compressionType: 8, samplesPerFrame: 1024) == nil)
        precondition(AirPlayAudioFormat(compressionType: 2, samplesPerFrame: -1) == nil)
        let timestamp = CMTime(value: 3, timescale: 1)
        let fixtures: [(String, UInt8, Int)] = [("eld", 8, 480), ("eld512", 8, 512), ("aac", 4, 1024), ("alac", 2, 352)]
        for (name, ct, frames) in fixtures {
            let format = AirPlayAudioFormat(compressionType: ct, samplesPerFrame: frames)!
            let data = packets(name)
            let sample = format.sampleBuffer(data[0], presentationTime: timestamp)!
            precondition(CMSampleBufferGetPresentationTimeStamp(sample) == timestamp)
            precondition(abs(CMSampleBufferGetDuration(sample).seconds - Double(frames) / 44_100) < 0.000001)
            precondition(format.sampleBuffer(Data(), presentationTime: timestamp) == nil)
            precondition(format.sampleBuffer(Data(count: 65_537), presentationTime: timestamp) == nil)
            decode(data, format: format)
            print("PASS \(name): packets, timestamps, duration, native decode and non-silent PCM")
        }
        let transportedSilence = try! Data(contentsOf: URL(fileURLWithPath: ".build/audio-tests/transported-alac-silence.bin"))
        precondition(transportedSilence.count == 32)
        decode(Array(repeating: transportedSilence, count: 32), format: AirPlayAudioFormat(compressionType: 2)!, expectSilence: true)
        let pcm = AirPlayAudioFormat(compressionType: 1)!
        precondition(pcm.sampleBuffer(Data(count: 3), presentationTime: timestamp) == nil)
        let sample = pcm.sampleBuffer(Data(count: 480 * 4), presentationTime: timestamp)!
        precondition(CMSampleBufferGetNumSamples(sample) == 480)
        precondition(abs(CMSampleBufferGetDuration(sample).seconds - 480.0 / 44_100) < 0.000001)

        let aac = AirPlayAudioFormat(compressionType: 4)!
        let raw = packets("aac")[0]
        let length = raw.count + 7
        var adts = Data([0xff, 0xf1, 0x50, 0x80 | UInt8((length >> 11) & 3),
                         UInt8((length >> 3) & 255), UInt8((length & 7) << 5) | 0x1f, 0xfc])
        adts.append(raw)
        precondition(CMSampleBufferGetTotalSampleSize(aac.sampleBuffer(adts, presentationTime: timestamp)!) == raw.count)
        adts[2] = 0x4c
        precondition(aac.sampleBuffer(adts, presentationTime: timestamp) == nil)
        print("PASS PCM alignment and ADTS validation")

        let warmingRenderer = WarmingAudioRenderer()
        warmingRenderer.isMuted = true
        let warmingPlayback = MediaPlayback(displayLayer: AVSampleBufferDisplayLayer(), audioRenderer: warmingRenderer)
        warmingPlayback.configureAudio(compressionType: 8, samplesPerFrame: 480)
        let opening = Array(packets("eld").prefix(8))
        let openingTime = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        for (index, packet) in opening.enumerated() {
            packet.withUnsafeBytes {
                warmingPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, packet.count, compressionType: 8,
                                            timestamp: openingTime + UInt64(index) * 480 * 1_000_000_000 / 44_100)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        warmingRenderer.finishWarmingUp()
        waitFor { warmingRenderer.receivedCount == opening.count }
        precondition(CMSampleBufferGetTotalSampleSize(warmingRenderer.firstSample!) == opening[0].count)
        warmingPlayback.reset()
        print("PASS codec warm-up preserves the opening eight audio packets")

        let burstRenderer = WarmingAudioRenderer()
        burstRenderer.isMuted = true
        let burstPlayback = MediaPlayback(displayLayer: AVSampleBufferDisplayLayer(), audioRenderer: burstRenderer)
        let burst = Array(packets("eld").prefix(256))
        precondition(burst.count == 256)
        for (index, packet) in burst.enumerated() {
            packet.withUnsafeBytes {
                burstPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, packet.count, compressionType: 8,
                                          timestamp: openingTime + UInt64(index) * 480 * 1_000_000_000 / 44_100)
            }
        }
        burst[0].withUnsafeBytes {
            burstPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, burst[0].count,
                                      compressionType: 8, timestamp: openingTime + 3_000_000_000)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        burstRenderer.finishWarmingUp()
        let deadline = Date().addingTimeInterval(2)
        while burstRenderer.receivedCount < burst.count, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        precondition(burstRenderer.receivedCount == burst.count,
                     "Native burst dropped audio: received \(burstRenderer.receivedCount)/256 packets")
        precondition(burstRenderer.receivedPackets == burst, "Burst reordered or corrupted the opening audio")
        decode(burstRenderer.receivedPackets, format: AirPlayAudioFormat(compressionType: 8)!)
        burstPlayback.reset()
        print("PASS 256-packet RTP burst retains every packet and clean stereo waveform")

        let stoppedRenderer = WarmingAudioRenderer()
        stoppedRenderer.isMuted = true
        let stoppedPlayback = MediaPlayback(displayLayer: AVSampleBufferDisplayLayer(), audioRenderer: stoppedRenderer)
        for _ in 0..<256 {
            opening[0].withUnsafeBytes {
                stoppedPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, opening[0].count,
                                            compressionType: 8, timestamp: openingTime)
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        stoppedPlayback.reset()
        stoppedRenderer.finishWarmingUp()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        precondition(stoppedRenderer.receivedCount == 0, "Stop must discard pending opening audio")
        for packet in opening {
            packet.withUnsafeBytes {
                stoppedPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, packet.count,
                                            compressionType: 8, timestamp: openingTime)
            }
        }
        waitFor { stoppedRenderer.receivedCount == opening.count }
        stoppedPlayback.reset()
        print("PASS stop clears warm-up audio and releases all bounded queue slots")

        let standaloneRenderer = WarmingAudioRenderer()
        standaloneRenderer.isMuted = true
        standaloneRenderer.finishWarmingUp()
        let standaloneLayer = AVSampleBufferDisplayLayer()
        let standalonePlayback = MediaPlayback(displayLayer: standaloneLayer, audioRenderer: standaloneRenderer)
        standalonePlayback.configureAudio(compressionType: 2, samplesPerFrame: 352, screenMirroring: false)
        let standalonePackets = Array(packets("alac").prefix(32))
        let arrival = Date()
        let standaloneTime = UInt64(arrival.timeIntervalSince1970 * 1_000_000_000) + 1_750_000_000
        for (index, packet) in standalonePackets.enumerated() {
            if index == 16 { RunLoop.current.run(until: Date().addingTimeInterval(0.04)) }
            RunLoop.current.run(until: arrival.addingTimeInterval(Double(index) * 352 / 44_100))
            packet.withUnsafeBytes {
                standalonePlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, packet.count, compressionType: 2,
                                                timestamp: standaloneTime + UInt64(index) * 352 * 1_000_000_000 / 44_100)
            }
            if index == 0 {
                waitFor { standaloneRenderer.receivedCount == 1 }
                let onset = (standaloneRenderer.receivedTimes[0] - CMTimebaseGetTime(standaloneLayer.sampleBufferRenderer.timebase)).seconds
                precondition(onset > -0.1 && onset < 0.2, "ALAC playback has \(onset) seconds of added onset delay")
            }
        }
        waitFor { standaloneRenderer.receivedCount == standalonePackets.count }
        let standaloneTimes = standaloneRenderer.receivedTimes
        let tail = (standaloneTimes.last! + CMTime(value: 352, timescale: 44_100)
                    - CMTimebaseGetTime(standaloneLayer.sampleBufferRenderer.timebase)).seconds
        precondition(tail > -0.1 && tail < 0.2, "Pausing input leaves \(tail) seconds of old ALAC audio")
        for index in 1..<standaloneTimes.count {
            precondition(abs((standaloneTimes[index] - standaloneTimes[index - 1]).seconds - 352.0 / 44_100) < 0.000001)
        }
        precondition(standaloneRenderer.receivedPackets == standalonePackets)
        decode(standaloneRenderer.receivedPackets, format: AirPlayAudioFormat(compressionType: 2)!)
        print("PASS standalone ALAC onset and pause tail stay short; 40 ms delivery jitter preserves clean stereo and packet order")

        RunLoop.current.run(until: Date().addingTimeInterval(1.1))
        let resumedTime = UInt64(Date().timeIntervalSince1970 * 1_000_000_000) + 1_750_000_000
        standalonePackets[0].withUnsafeBytes {
            standalonePlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, standalonePackets[0].count,
                                            compressionType: 2, timestamp: resumedTime)
        }
        waitFor { standaloneRenderer.receivedCount == standalonePackets.count + 1 }
        precondition(standaloneRenderer.receivedTimes.last == CMTime(value: Int64(resumedTime), timescale: 1_000_000_000),
                     "Resuming after silence must not clamp the first packet to a stale audio cursor")
        standalonePlayback.flushAudio()
        waitFor { standaloneRenderer.flushCount == 2 }
        standalonePlayback.reset()
        print("PASS standalone ALAC resumes after silence without losing its opening and clears on flush/reset")

        let timingCases: [(UInt8, Bool, Double)] = [
            (2, true, 1.75), (8, true, 1.75), (2, false, 0), (2, false, 30)
        ]
        for (ct, screen, seconds) in timingCases {
            standalonePlayback.configureAudio(compressionType: ct, samplesPerFrame: ct == 2 ? 352 : 480, screenMirroring: screen)
            let packet = ct == 2 ? standalonePackets[0] : opening[0]
            let before = standaloneRenderer.receivedCount
            let time = UInt64((Date().timeIntervalSince1970 + seconds) * 1_000_000_000)
            packet.withUnsafeBytes {
                standalonePlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, packet.count,
                                                compressionType: ct, timestamp: time)
            }
            waitFor { standaloneRenderer.receivedCount == before + 1 }
            let lead = (standaloneRenderer.receivedTimes.last! - CMTimebaseGetTime(standaloneLayer.sampleBufferRenderer.timebase)).seconds
            precondition(lead > -0.2 && lead < 0.3, "Unexpected profile timing: ct=\(ct) screen=\(screen) lead=\(lead)")
            standalonePlayback.reset()
        }
        print("PASS screen-mirroring latency is unchanged and standalone ALAC never adds the sender's multi-second lead")

        let edgeRenderer = WarmingAudioRenderer()
        edgeRenderer.isMuted = true
        edgeRenderer.finishWarmingUp()
        let edgePlayback = MediaPlayback(displayLayer: AVSampleBufferDisplayLayer(), audioRenderer: edgeRenderer)
        edgePlayback.configureAudio(compressionType: 2, samplesPerFrame: 352, screenMirroring: false)
        let edgedPackets = [transportedSilence] + standalonePackets + [transportedSilence]
        for (index, packet) in edgedPackets.enumerated() {
            packet.withUnsafeBytes {
                edgePlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, packet.count, compressionType: 2,
                                         timestamp: standaloneTime + UInt64(index) * 352 * 1_000_000_000 / 44_100)
            }
        }
        waitFor { edgeRenderer.receivedCount == edgedPackets.count }
        precondition(edgeRenderer.receivedPackets == edgedPackets)
        let edgeTimes = edgeRenderer.receivedTimes
        for index in 1..<edgeTimes.count {
            precondition(abs((edgeTimes[index] - edgeTimes[index - 1]).seconds - 352.0 / 44_100) < 0.000001)
        }
        decode(edgeRenderer.receivedPackets, format: AirPlayAudioFormat(compressionType: 2)!)
        edgePlayback.reset()
        print("PASS valid ALAC silence at both clip edges preserves continuous timing and clean decoded stereo")

        let coldRenderer = WarmingAudioRenderer()
        coldRenderer.isMuted = true
        coldRenderer.finishWarmingUp()
        let coldLayer = AVSampleBufferDisplayLayer()
        let coldPlayback = MediaPlayback(displayLayer: coldLayer, audioRenderer: coldRenderer)
        coldPlayback.configureAudio(compressionType: 2, samplesPerFrame: 352, screenMirroring: false)
        let coldTime = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        standalonePackets[0].withUnsafeBytes {
            coldPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, standalonePackets[0].count,
                                     compressionType: 2, timestamp: coldTime)
        }
        waitFor { coldRenderer.receivedCount == 1 }
        coldRenderer.stallNextFlush(0.12)
        coldPlayback.flushAudio()
        standalonePackets[1].withUnsafeBytes {
            coldPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, standalonePackets[1].count,
                                     compressionType: 2, timestamp: coldTime + 352 * 1_000_000_000 / 44_100)
        }
        waitFor { coldRenderer.receivedCount == 2 }
        let coldLead = (coldRenderer.receivedTimes.last! - CMTimebaseGetTime(coldLayer.sampleBufferRenderer.timebase)).seconds
        precondition(coldLead > 0.04 && coldLead < 0.2, "Decoder reset left the first ALAC packet late: lead=\(coldLead)")
        coldRenderer.stallNextFlush(0.12)
        coldPlayback.configureAudio(compressionType: 2, samplesPerFrame: 352, screenMirroring: false)
        standalonePackets[2].withUnsafeBytes {
            coldPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, standalonePackets[2].count,
                                     compressionType: 2, timestamp: coldTime + 2 * 352 * 1_000_000_000 / 44_100)
        }
        waitFor { coldRenderer.receivedCount == 3 }
        let configuredLead = (coldRenderer.receivedTimes.last! - CMTimebaseGetTime(coldLayer.sampleBufferRenderer.timebase)).seconds
        precondition(configuredLead > 0.04 && configuredLead < 0.2, "Repeated ALAC configuration retained an expired clock")
        coldPlayback.reset()
        print("PASS standalone ALAC reanchors after a slow decoder reset without starting late")

        for iteration in 0..<8 {
            let layer = AVSampleBufferDisplayLayer()
            let actual = ColdAudioRenderer(clock: layer.sampleBufferRenderer.timebase)
            actual.isMuted = true
            let player = MediaPlayback(displayLayer: layer, audioRenderer: actual)
            player.configureAudio(compressionType: 2, samplesPerFrame: 352, screenMirroring: false)
            let time = UInt64(Date().timeIntervalSince1970 * 1_000_000_000) + 1_750_000_000
            transportedSilence.withUnsafeBytes {
                player.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, transportedSilence.count,
                                   compressionType: 2, timestamp: time)
            }
            waitFor { actual.receivedCount == 1 }
            actual.stallNextFlush([0.0, 0.025, 0.06, 0.12][iteration % 4])
            player.flushAudio()
            for index in 0..<16 {
                let packet = standalonePackets[index]
                packet.withUnsafeBytes {
                    player.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, packet.count,
                                       compressionType: 2, timestamp: time + UInt64(index + 1) * 352 * 1_000_000_000 / 44_100)
                }
            }
            waitFor { actual.receivedCount == 17 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
            precondition(actual.status != .failed, "Real ALAC startup decoder failed: \(String(describing: actual.error))")
            precondition(actual.leastLead > 0.02, "Real ALAC startup enqueued an expired packet: \(actual.leastLead)")
            player.reset()
        }
        print("PASS eight muted real-decoder cold starts and 0/25/60/120 ms resets keep every opening packet timely")

        let frame = Data(base64Encoded: "AAAAASdkAAusVlDDeBRghQAAAAEo7jywAAAAAQYFLUdWStxcTEM/lO/FETzRQ6gBAAADAAEDAAADAAECAAHmAAsAAAMAAAMAAAMA5gwDkSsBgAAAAAEluCAfgC5KrBE+QARPnjV9IxrUjT6OFZ4dOwEo+WY4J/YSAABAABzl+nA=")!
        let delayedAudioRenderer = AVSampleBufferAudioRenderer()
        delayedAudioRenderer.isMuted = true
        let earlyVideoLayer = AVSampleBufferDisplayLayer()
        let delayedPlayback = MediaPlayback(displayLayer: earlyVideoLayer, audioRenderer: delayedAudioRenderer)
        let earlyVideo = VideoPipeline()
        earlyVideo.onSampleBuffer = { sample, timestamp in delayedPlayback.enqueueVideo(sample, timestamp: timestamp) }
        let earlyTime = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        frame.withUnsafeBytes {
            earlyVideo.handleAccessUnit($0.bindMemory(to: UInt8.self).baseAddress!, frame.count, timestamp: earlyTime)
        }
        waitFor { earlyVideoLayer.isReadyForDisplay }
        let beforeAudio = CMTimebaseGetTime(earlyVideoLayer.sampleBufferRenderer.timebase)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let afterAudio = CMTimebaseGetTime(earlyVideoLayer.sampleBufferRenderer.timebase)
        precondition((afterAudio - beforeAudio).seconds > 0.2, "Missing audio must not freeze the video clock")
        let delayedTime = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        for (index, packet) in opening.enumerated() {
            packet.withUnsafeBytes {
                delayedPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, packet.count, compressionType: 8,
                                            timestamp: delayedTime + UInt64(index) * 480 * 1_000_000_000 / 44_100)
            }
        }
        waitFor { delayedAudioRenderer.status == .rendering || delayedAudioRenderer.status == .failed }
        precondition(delayedAudioRenderer.status == .rendering)
        let joinedTime = CMTimebaseGetTime(earlyVideoLayer.sampleBufferRenderer.timebase).seconds
        precondition(abs(joinedTime - Date().timeIntervalSince1970) < 0.3, "Late audio startup must not rewind the video timeline")
        let videoBeforeFlush = CMTimebaseGetTime(earlyVideoLayer.sampleBufferRenderer.timebase)
        delayedPlayback.flushAudio()
        RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        let videoAfterFlush = CMTimebaseGetTime(earlyVideoLayer.sampleBufferRenderer.timebase)
        precondition((videoAfterFlush - videoBeforeFlush).seconds > 0.08, "Audio flush must not stop or rewind the video clock")
        earlyVideo.reset()
        delayedPlayback.reset()
        print("PASS video-first startup, silent video clock, and delayed audio joining the timeline")

        let jumpingRenderer = WarmingAudioRenderer()
        jumpingRenderer.finishWarmingUp()
        jumpingRenderer.isMuted = true
        let jumpingPlayback = MediaPlayback(displayLayer: AVSampleBufferDisplayLayer(), audioRenderer: jumpingRenderer)
        jumpingPlayback.configureAudio(compressionType: 8, samplesPerFrame: 480)
        let masterVideo = VideoPipeline()
        let masterQueued = DispatchSemaphore(value: 0)
        let masterTime = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        masterVideo.onSampleBuffer = { sample, timestamp in
            jumpingPlayback.enqueueVideo(sample, timestamp: timestamp)
            masterQueued.signal()
        }
        frame.withUnsafeBytes {
            masterVideo.handleAccessUnit($0.bindMemory(to: UInt8.self).baseAddress!, frame.count, timestamp: masterTime)
        }
        precondition(masterQueued.wait(timeout: .now() + 2) == .success)
        for index in 0..<3 {
            opening[index].withUnsafeBytes {
                jumpingPlayback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, opening[index].count,
                                            compressionType: 8, timestamp: masterTime - 2_700_000_000 + UInt64(index) * 480 * 1_000_000_000 / 44_100)
            }
        }
        waitFor { jumpingRenderer.receivedCount == 3 }
        let times = jumpingRenderer.receivedTimes
        precondition(abs((times[1] - times[0]).seconds - 480.0 / 44_100) < 0.000001)
        precondition(abs((times[2] - times[1]).seconds - 480.0 / 44_100) < 0.000001)
        let scheduled = CMSampleBufferGetPresentationTimeStamp(jumpingRenderer.firstSample!)
        let masterPTS = CMTime(value: Int64(masterTime), timescale: 1_000_000_000)
        precondition(scheduled >= masterPTS, "Opening audio is scheduled 2.7 seconds in the past")
        precondition(jumpingRenderer.flushCount == 1, "Discontinuous audio must not repeatedly flush/restart both decoders")
        jumpingPlayback.reset()
        print("PASS transient audio timestamp jumps preserve the opening without resetting video")

        let renderer = AVSampleBufferAudioRenderer()
        renderer.isMuted = true
        let displayLayer = AVSampleBufferDisplayLayer()
        let playback = MediaPlayback(displayLayer: displayLayer, audioRenderer: renderer)
        playback.configureAudio(compressionType: 8, samplesPerFrame: 480)
        let audio = packets("eld")
        let now = UInt64(Date().timeIntervalSince1970 * 1_000_000_000)
        for (index, packet) in audio.enumerated() {
            packet.withUnsafeBytes {
                playback.handleAudio($0.bindMemory(to: UInt8.self).baseAddress!, packet.count, compressionType: 8,
                                     timestamp: now + UInt64(index) * 480 * 1_000_000_000 / 44_100)
            }
        }
        waitFor { renderer.status == .rendering || renderer.status == .failed }
        precondition(renderer.status == .rendering, "Audio renderer failed: \(String(describing: renderer.error))")
        print("PASS audio renderer accepted compressed packets")

        // An authored 32×32 gray H.264 frame, encoded with VideoToolbox.
        let video = VideoPipeline()
        let received = DispatchSemaphore(value: 0)
        let frameTime = now + 10_000_000
        var dimensions: [(Int, Int)] = []
        video.onDimensions = { width, height, _ in dimensions.append((width, height)) }
        video.onSampleBuffer = { sample, timestamp in
            precondition(timestamp == frameTime)
            precondition(CMSampleBufferGetPresentationTimeStamp(sample) == .zero)
            playback.enqueueVideo(sample, timestamp: timestamp)
            received.signal()
        }
        video.onFlush = { playback.flushVideo(removingDisplayedImage: $0) }
        frame.withUnsafeBytes {
            video.handleAccessUnit($0.bindMemory(to: UInt8.self).baseAddress!, frame.count, timestamp: frameTime)
        }
        precondition(received.wait(timeout: .now() + 2) == .success)
        waitFor { displayLayer.isReadyForDisplay || displayLayer.sampleBufferRenderer.status == .failed }
        precondition(displayLayer.isReadyForDisplay, "Synchronized video did not decode/display")
        waitFor { dimensions.count == 1 }
        precondition(dimensions[0] == (32, 32))
        print("PASS timestamped H.264 decode/display alongside audio")
        playback.setVolume(decibels: -6)
        waitFor { abs(renderer.volume - 0.501187) < 0.001 }
        playback.setVolume(decibels: -144)
        waitFor { renderer.volume == 0 }
        playback.setVolume(decibels: .nan)
        video.reset()
        playback.reset()
        precondition(renderer.volume == 1)
        waitFor { !renderer.hasSufficientMediaDataForReliablePlaybackStart }
        precondition(renderer.status != .failed)
        print("PASS muted playback, source volume/mute, invalid volume, and synchronous reset")

        waitFor { !displayLayer.isReadyForDisplay }
        frame.withUnsafeBytes {
            video.handleAccessUnit($0.bindMemory(to: UInt8.self).baseAddress!, frame.count, timestamp: frameTime)
        }
        precondition(received.wait(timeout: .now() + 2) == .success)
        waitFor { displayLayer.isReadyForDisplay && dimensions.count == 2 }
        precondition(dimensions[1] == (32, 32))
        playback.reset()
        print("PASS reconnect at the same resolution and video playback without audio")
    }
}
