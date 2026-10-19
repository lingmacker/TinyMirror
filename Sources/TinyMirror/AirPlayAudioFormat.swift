import AudioToolbox
import CoreMedia
import Foundation

/// The receiver negotiates stereo 44.1 kHz audio; packet sizes vary by codec.
struct AirPlayAudioFormat {
    let compressionType: UInt8
    let description: CMAudioFormatDescription

    init?(compressionType: UInt8, samplesPerFrame: Int = 0) {
        var stream = AudioStreamBasicDescription()
        stream.mSampleRate = 44_100
        stream.mChannelsPerFrame = 2
        var cookie: [UInt8] = []
        switch compressionType {
        case 1:
            stream.mFormatID = kAudioFormatLinearPCM
            stream.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
            stream.mBytesPerPacket = 4
            stream.mFramesPerPacket = 1
            stream.mBytesPerFrame = 4
            stream.mBitsPerChannel = 16
        case 2:
            let frames = samplesPerFrame == 0 ? 352 : samplesPerFrame
            guard (1...4096).contains(frames) else { return nil }
            stream.mFormatID = kAudioFormatAppleLossless
            stream.mFormatFlags = kAppleLosslessFormatFlag_16BitSourceData
            stream.mFramesPerPacket = UInt32(frames)
            // ALACSpecificConfig: frame length, 16-bit stereo, predictor parameters, sample rate.
            cookie = [UInt8(frames >> 24), UInt8((frames >> 16) & 255), UInt8((frames >> 8) & 255), UInt8(frames & 255),
                      0, 16, 40, 10, 14, 2, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 172, 68]
        case 4:
            let frames = samplesPerFrame == 0 ? 1024 : samplesPerFrame
            guard frames == 1024 || frames == 960 else { return nil }
            stream.mFormatID = kAudioFormatMPEG4AAC
            stream.mFramesPerPacket = UInt32(frames)
            cookie = [0x12, frames == 1024 ? 0x10 : 0x14]
        case 8:
            let frames = samplesPerFrame == 0 ? 480 : samplesPerFrame
            guard frames == 480 || frames == 512 else { return nil }
            stream.mFormatID = kAudioFormatMPEG4AAC_ELD
            stream.mFramesPerPacket = UInt32(frames)
            cookie = [0xf8, 0xe8, frames == 480 ? 0x50 : 0x40, 0x00]
        default:
            return nil
        }
        if compressionType == 4 || compressionType == 8 {
            // Core Audio needs an MPEG-4 ES descriptor, not a bare AudioSpecificConfig.
            let config = cookie
            cookie = [0x03, UInt8(23 + config.count), 0, 0, 0, 0x04, UInt8(15 + config.count), 0x40, 0x15]
                + [UInt8](repeating: 0, count: 11)
                + [0x05, UInt8(config.count)] + config + [0x06, 0x01, 0x02]
        }
        var format: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes {
            CMAudioFormatDescriptionCreate(
                allocator: kCFAllocatorDefault, asbd: &stream,
                layoutSize: 0, layout: nil, magicCookieSize: cookie.count,
                magicCookie: $0.baseAddress, extensions: nil, formatDescriptionOut: &format)
        }
        guard status == noErr, let format else { return nil }
        self.compressionType = compressionType
        self.description = format
    }

    func sampleBuffer(_ packet: Data, presentationTime: CMTime) -> CMSampleBuffer? {
        guard !packet.isEmpty, packet.count <= 65_536 else { return nil }
        var payload = packet
        if compressionType == 4, packet.count >= 2, packet[0] == 0xff, packet[1] & 0xf6 == 0xf0 {
            // AAC-LC senders may include an ADTS transport header instead of raw AAC.
            guard packet.count >= 7 else { return nil }
            let headerSize = packet[1] & 1 == 1 ? 7 : 9
            let length = Int(packet[3] & 3) << 11 | Int(packet[4]) << 3 | Int(packet[5] >> 5)
            let channels = Int(packet[2] & 1) << 2 | Int(packet[3] >> 6)
            guard packet[2] >> 6 == 1, (packet[2] >> 2) & 15 == 4, channels == 2,
                  packet[6] & 3 == 0, length == packet.count, length > headerSize else { return nil }
            payload = Data(packet.dropFirst(headerSize))
        }
        if compressionType == 1, payload.count % 4 != 0 { return nil }
        var block: CMBlockBuffer?
        let status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: payload.count, flags: 0, blockBufferOut: &block)
        guard status == noErr, let block else { return nil }
        guard payload.withUnsafeBytes({
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: payload.count)
        }) == noErr else { return nil }
        var packetDescription = AudioStreamPacketDescription(
            mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(payload.count))
        var sample: CMSampleBuffer?
        let result = withUnsafePointer(to: &packetDescription) {
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
                sampleCount: compressionType == 1 ? payload.count / 4 : 1,
                presentationTimeStamp: presentationTime,
                packetDescriptions: compressionType == 1 ? nil : $0,
                sampleBufferOut: &sample)
        }
        return result == noErr ? sample : nil
    }
}
