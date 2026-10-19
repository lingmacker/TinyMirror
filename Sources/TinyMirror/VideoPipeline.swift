import Foundation
import AVFoundation
import CoreMedia

/// Packages Annex-B H.264/HEVC frames for AVSampleBufferDisplayLayer's native decoder.
final class VideoPipeline {
    var onSampleBuffer: ((CMSampleBuffer, UInt64) -> Void)?
    var onFlush: ((Bool) -> Void)?
    /// Reported on the main thread whenever the coded video size changes.
    var onDimensions: ((Int, Int, Bool) -> Void)?

    static let debugEnabled = ProcessInfo.processInfo.environment["TINYMIRROR_DEBUG"] == "1"

    private let queue = DispatchQueue(label: "tinymirror.video", qos: .userInteractive)
    private let generationLock = NSLock()
    private var generation = 0
    private var formatDescription: CMVideoFormatDescription?
    private var isH265 = false
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    private var lastReportedSize: (Int, Int) = (0, 0)
    private var framesSeen = 0

    /// Safe to call from any thread; copies the frame and processes async.
    func handleAccessUnit(_ bytes: UnsafePointer<UInt8>, _ length: Int, isH265: Bool = false, timestamp: UInt64 = 0) {
        guard length > 0 else { return }
        let generation = generationLock.withLock { self.generation }
        let data = Data(bytes: bytes, count: length)
        queue.async { [weak self] in
            guard let self, self.generationLock.withLock({ self.generation }) == generation else { return }
            self.process(data, isH265: isH265, timestamp: timestamp, generation: generation)
        }
    }

    func flush() {
        queue.async { [weak self] in
            self?.onFlush?(false)
        }
    }

    func reset() {
        generationLock.withLock { generation += 1 }
        // Drain in-flight video before AppDelegate resets the shared playback clock.
        queue.sync {
            onFlush?(true)
            formatDescription = nil
            isH265 = false
            vps = nil
            sps = nil
            pps = nil
            lastReportedSize = (0, 0) // A reconnect must reopen even at the same resolution.
        }
    }

    // MARK: - Parsing

    private func process(_ frame: Data, isH265: Bool, timestamp: UInt64, generation: Int) {
        if self.isH265 != isH265 {
            self.isH265 = isH265
            formatDescription = nil
            vps = nil
            sps = nil
            pps = nil
            lastReportedSize = (0, 0)
        }
        var vclUnits: [Data] = []
        var parameterSetsChanged = false

        let nals = VideoPipeline.splitAnnexB(frame)
        if VideoPipeline.debugEnabled && framesSeen < 5 {
            let types = nals.map { String(isH265 ? (($0.first ?? 0) >> 1) & 0x3F : ($0.first ?? 0) & 0x1F) }.joined(separator: ",")
            NSLog("[TinyMirror] video frame %d: %d bytes, %d NAL(s), types=[%@]",
                  framesSeen, frame.count, nals.count, types)
        }
        framesSeen += 1

        for nal in nals {
            guard nal.count >= (isH265 ? 2 : 1), let first = nal.first else { continue }
            if isH265 {
                switch (first >> 1) & 0x3F {
                case 32:
                    if vps != nal { vps = nal; parameterSetsChanged = true }
                case 33:
                    if sps != nal { sps = nal; parameterSetsChanged = true }
                case 34:
                    if pps != nal { pps = nal; parameterSetsChanged = true }
                case 0...31:
                    vclUnits.append(nal)
                default: break
                }
            } else {
                switch first & 0x1F {
                case 7:
                    if sps != nal { sps = nal; parameterSetsChanged = true }
                case 8:
                    if pps != nal { pps = nal; parameterSetsChanged = true }
                case 1, 5:
                    vclUnits.append(nal)
                default: break
                }
            }
        }

        if parameterSetsChanged || formatDescription == nil {
            rebuildFormatDescription(generation: generation)
        }
        guard let formatDescription, !vclUnits.isEmpty else { return }
        guard let sampleBuffer = makeSampleBuffer(vclUnits, format: formatDescription) else { return }

        guard generationLock.withLock({ self.generation }) == generation else { return }
        onSampleBuffer?(sampleBuffer, timestamp)
    }

    private func rebuildFormatDescription(generation: Int) {
        guard let sps, let pps else { return }
        var format: CMVideoFormatDescription?
        let status = sps.withUnsafeBytes { spsPtr -> OSStatus in
            pps.withUnsafeBytes { ppsPtr -> OSStatus in
                let pointers: [UnsafePointer<UInt8>] = [
                    spsPtr.bindMemory(to: UInt8.self).baseAddress!,
                    ppsPtr.bindMemory(to: UInt8.self).baseAddress!,
                ]
                let sizes: [Int] = [sps.count, pps.count]
                if isH265 {
                    guard let vps else { return kCMFormatDescriptionError_InvalidParameter }
                    return vps.withUnsafeBytes { vpsPtr in
                        let hevcPointers = [vpsPtr.bindMemory(to: UInt8.self).baseAddress!, pointers[0], pointers[1]]
                        return CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 3,
                            parameterSetPointers: hevcPointers,
                            parameterSetSizes: [vps.count] + sizes,
                            nalUnitHeaderLength: 4,
                            extensions: nil,
                            formatDescriptionOut: &format)
                    }
                }
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: pointers,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &format)
            }
        }
        guard status == noErr, let format else {
            NSLog("[TinyMirror] format description FAILED (status %d) sps=%d pps=%d bytes",
                  Int(status), sps.count, pps.count)
            return
        }
        formatDescription = format
        if VideoPipeline.debugEnabled {
            let d = CMVideoFormatDescriptionGetDimensions(format)
            NSLog("[TinyMirror] format description ready: %dx%d", d.width, d.height)
        }

        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let size = (Int(dims.width), Int(dims.height))
        if size != lastReportedSize {
            lastReportedSize = size
            let h265 = isH265
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generationLock.withLock({ self.generation }) == generation else { return }
                self.onDimensions?(size.0, size.1, h265)
            }
        }
    }

    private func makeSampleBuffer(_ nalUnits: [Data], format: CMVideoFormatDescription) -> CMSampleBuffer? {
        // AVCC layout: 4-byte big-endian length prefix per NAL unit.
        var avcc = Data(capacity: nalUnits.reduce(0) { $0 + $1.count + 4 })
        for nal in nalUnits {
            var lengthBE = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &lengthBE) { avcc.append(contentsOf: $0) }
            avcc.append(nal)
        }

        var blockBuffer: CMBlockBuffer?
        let count = avcc.count
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: count,
            flags: 0,
            blockBufferOut: &blockBuffer)
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        status = avcc.withUnsafeBytes { ptr in
            CMBlockBufferReplaceDataBytes(
                with: ptr.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: count)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: format,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr, let sampleBuffer else { return nil }

        return sampleBuffer
    }

    /// Splits an Annex-B byte stream into NAL unit payloads (start codes removed).
    static func splitAnnexB(_ data: Data) -> [Data] {
        var units: [Data] = []
        let bytes = [UInt8](data)
        var i = 0
        var currentStart: Int? = nil
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                let startCodeLength = (i > 0 && bytes[i - 1] == 0) ? 4 : 3
                let boundary = startCodeLength == 4 ? i - 1 : i
                if let start = currentStart, boundary > start {
                    units.append(Data(bytes[start..<boundary]))
                }
                i += 3
                currentStart = i
            } else {
                i += 1
            }
        }
        if let start = currentStart, start < bytes.count {
            units.append(Data(bytes[start...]))
        }
        return units
    }
}
