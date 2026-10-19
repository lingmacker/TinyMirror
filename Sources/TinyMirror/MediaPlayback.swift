import AVFoundation
import CoreMedia
import Foundation

/// Audio and video share a playout clock instead of racing two independent players.
final class MediaPlayback {
    private let queue = DispatchQueue(label: "tinymirror.playback", qos: .userInteractive)
    // The native RTP reorder buffer can release a whole 256-packet window at once.
    private let audioSlots = DispatchSemaphore(value: 256)
    private let generationLock = NSLock()
    private var generation = 0
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let audioRenderer: AVSampleBufferAudioRenderer
    private let videoRenderer: AVSampleBufferVideoRenderer
    private var audioType: UInt8?
    private var audioFormat: AirPlayAudioFormat?
    private var clockStarted = false
    private var audioErrorReported = false
    private var pendingAudio: [CMSampleBuffer] = []
    private var requestingAudio = false
    private var nextAudioTime: CMTime?
    private var audioRTPAnchor: (position: UInt32, time: CMTime, arrival: UInt64)?
    private var lastVideoTime: CMTime?
    private var screenMirroring = true
    private var standaloneALAC: Bool { audioType == 2 && !screenMirroring }

    init(displayLayer: AVSampleBufferDisplayLayer, audioRenderer: AVSampleBufferAudioRenderer = AVSampleBufferAudioRenderer()) {
        self.audioRenderer = audioRenderer
        videoRenderer = displayLayer.sampleBufferRenderer
        synchronizer.addRenderer(videoRenderer)
        synchronizer.addRenderer(audioRenderer)
        // A silent sender must not hold up video while the audio renderer waits for data.
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
    }

    func configureAudio(compressionType: UInt8, samplesPerFrame: Int, screenMirroring: Bool = true) {
        queue.async { [weak self] in
            self?.configureAudioOnQueue(compressionType: compressionType, samplesPerFrame: samplesPerFrame,
                                       screenMirroring: screenMirroring)
        }
    }

    private func configureAudioOnQueue(compressionType: UInt8, samplesPerFrame: Int, screenMirroring: Bool) {
        let wasStandaloneALAC = standaloneALAC
        clearPendingAudio()
        audioRenderer.flush()
        audioType = compressionType
        self.screenMirroring = screenMirroring
        if standaloneALAC || wasStandaloneALAC != standaloneALAC { clockStarted = false }
        audioFormat = AirPlayAudioFormat(compressionType: compressionType, samplesPerFrame: samplesPerFrame)
        nextAudioTime = nil
        audioRTPAnchor = nil
        audioErrorReported = false
        if audioFormat == nil {
            NSLog("[TinyMirror] unsupported audio format: ct=%d spf=%d", compressionType, samplesPerFrame)
        } else if VideoPipeline.debugEnabled {
            NSLog("[TinyMirror] audio format ready: ct=%d spf=%d", compressionType, samplesPerFrame)
        }
    }

    /// Copies receiver-owned bytes before returning; bounds queued audio during CPU stalls.
    func handleAudio(_ bytes: UnsafePointer<UInt8>, _ length: Int, compressionType: UInt8, timestamp: UInt64,
                     rtpTimestamp: UInt32? = nil) {
        let arrival = DispatchTime.now().uptimeNanoseconds
        guard length > 0, length <= 65_536, audioSlots.wait(timeout: .now()) == .success else { return }
        let generation = generationLock.withLock { self.generation }
        let packet = Data(bytes: bytes, count: length)
        queue.async { [weak self, audioSlots] in
            var queued = false
            defer { if !queued { audioSlots.signal() } }
            guard let self, self.generationLock.withLock({ self.generation }) == generation else { return }
            if self.audioType != compressionType {
                self.configureAudioOnQueue(compressionType: compressionType, samplesPerFrame: 0,
                                           screenMirroring: self.screenMirroring)
            }
            guard let format = self.audioFormat, let pts = self.presentationTime(timestamp, isAudio: true, rtpTimestamp: rtpTimestamp, audioArrival: arrival),
                  let sample = format.sampleBuffer(packet, presentationTime: pts) else { return }
            if self.audioRenderer.status == .failed {
                if !self.audioErrorReported {
                    NSLog("[TinyMirror] audio playback failed: %@", self.audioRenderer.error?.localizedDescription ?? "unknown")
                    self.audioErrorReported = true
                }
                self.clearPendingAudio()
                self.audioRenderer.flush()
            }
            if self.standaloneALAC, let position = rtpTimestamp { self.audioRTPAnchor = (position, pts, arrival) }
            self.pendingAudio.append(sample)
            self.nextAudioTime = pts + CMSampleBufferGetDuration(sample)
            queued = true
            if !self.requestingAudio {
                self.requestingAudio = true
                self.audioRenderer.requestMediaDataWhenReady(on: self.queue) { [weak self] in
                    self?.drainAudio()
                }
            }
            self.drainAudio()
        }
    }

    private func drainAudio() {
        while !pendingAudio.isEmpty, audioRenderer.isReadyForMoreMediaData {
            audioRenderer.enqueue(pendingAudio.removeFirst())
            audioSlots.signal()
        }
        if pendingAudio.isEmpty, requestingAudio {
            audioRenderer.stopRequestingMediaData()
            requestingAudio = false
        }
    }

    private func clearPendingAudio() {
        if requestingAudio {
            audioRenderer.stopRequestingMediaData()
            requestingAudio = false
        }
        for _ in pendingAudio { audioSlots.signal() }
        pendingAudio.removeAll(keepingCapacity: true)
    }

    deinit { clearPendingAudio() }

    func enqueueVideo(_ sample: CMSampleBuffer, timestamp: UInt64) {
        let generation = generationLock.withLock { self.generation }
        queue.async { [weak self] in
            guard let self, self.generationLock.withLock({ self.generation }) == generation,
                  let pts = self.presentationTime(timestamp) else { return }
            guard CMSampleBufferSetOutputPresentationTimeStamp(sample, newValue: pts) == noErr else { return }
            self.lastVideoTime = pts
            if self.videoRenderer.status == .failed {
                NSLog("[TinyMirror] video playback failed: %@", self.videoRenderer.error?.localizedDescription ?? "unknown")
                self.videoRenderer.flush()
            }
            self.videoRenderer.enqueue(sample)
        }
    }

    private func presentationTime(_ timestamp: UInt64, isAudio: Bool = false, rtpTimestamp: UInt32? = nil,
                                  audioArrival: UInt64? = nil) -> CMTime? {
        guard timestamp <= UInt64(Int64.max) else { return nil }
        if isAudio, standaloneALAC, let position = rtpTimestamp, let arrival = audioArrival, let anchor = audioRTPAnchor {
            let samples = Int32(bitPattern: position &- anchor.position)
            guard samples > 0 else { return nil }
            // RTP samples stay continuous when NTP is unavailable or recalibrated; arrival time does not.
            let projected = anchor.time + CMTime(value: Int64(samples), timescale: 44_100)
            if arrival - anchor.arrival < 250_000_000 || projected >= synchronizer.currentTime() { return projected }
            // A sender may pause its RTP clock along with packet delivery.
            clockStarted = false
        }
        let pts = timestamp == 0
            ? CMTime(seconds: Date().timeIntervalSince1970, preferredTimescale: 1_000_000_000)
            : CMTime(value: Int64(timestamp), timescale: 1_000_000_000)
        let current = synchronizer.currentTime()
        let reference = isAudio && standaloneALAC ? max(nextAudioTime ?? current, current) : current
        let discontinuity = abs((pts - reference).seconds) > 1
        if clockStarted, isAudio, discontinuity {
            // An RTP sync correction must not rewind the shared video clock or erase the opening.
            let videoTime = standaloneALAC ? current : (lastVideoTime ?? current)
            return max(nextAudioTime ?? current, videoTime, current)
        }
        if !clockStarted || discontinuity {
            if clockStarted {
                clearPendingAudio()
                nextAudioTime = nil
                audioRenderer.flush()
                videoRenderer.flush()
            }
            // shortcut: ALAC covers measured ~100 ms bursts; revisit if real jitter exceeds the 120 ms budget.
            let jitter: Int64 = standaloneALAC ? 120 : 80
            let start = CMClockGetTime(CMClockGetHostTimeClock()) + CMTime(value: jitter, timescale: 1000)
            synchronizer.setRate(1, time: pts, atHostTime: start)
            clockStarted = true
        }
        return pts
    }

    func setVolume(decibels: Float) {
        guard decibels.isFinite else { return }
        let volume: Float = decibels <= -144 ? 0 : Float(pow(10, Double(min(0, decibels)) / 20))
        queue.async { [weak self] in self?.audioRenderer.volume = volume }
    }

    func flushAudio() {
        queue.async { [weak self] in
            guard let self else { return }
            self.clearPendingAudio()
            self.nextAudioTime = nil
            self.audioRTPAnchor = nil
            self.audioRenderer.flush()
            if self.standaloneALAC { self.clockStarted = false }
        }
    }

    func flushVideo(removingDisplayedImage: Bool) {
        queue.async { [weak self] in
            self?.videoRenderer.flush(removingDisplayedImage: removingDisplayedImage, completionHandler: nil)
        }
    }

    func reset() {
        generationLock.withLock { generation += 1 }
        queue.sync {
            synchronizer.setRate(0, time: .zero)
            clearPendingAudio()
            audioRenderer.flush()
            videoRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
            audioRenderer.volume = 1
            audioFormat = nil
            audioType = nil
            screenMirroring = true
            nextAudioTime = nil
            audioRTPAnchor = nil
            lastVideoTime = nil
            clockStarted = false
            audioErrorReported = false
        }
    }
}
