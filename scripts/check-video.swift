// Run from the repository root (no AirPlay library or phone required):
// swiftc -module-cache-path .build/module-cache Sources/MirrorDeck/VideoPipeline.swift scripts/check-video.swift -o .build/check-video
// .build/check-video
import Foundation

@main
struct VideoChecks {
    static func main() {
        // H.264 SPS/PPS for a 1280×720 stream; no decoded picture is needed.
        let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1f, 0xac, 0xd9, 0x40, 0x50,
                           0x05, 0xbb, 0x01, 0x10, 0x00, 0x00, 0x03, 0x00,
                           0x10, 0x00, 0x00, 0x03, 0x03, 0xc0, 0xf1, 0x83, 0x19, 0x60]
        let pps: [UInt8] = [0x68, 0xeb, 0xec, 0xb2, 0x2c]
        let frame = [0, 0, 0, 1] + sps + [0, 0, 0, 1] + pps
        let pipeline = VideoPipeline()
        var reports = 0
        pipeline.onDimensions = { width, height in
            assert(width == 1280 && height == 720)
            reports += 1
        }

        for expected in 1...2 {
            if expected == 2 { pipeline.reset() }
            frame.withUnsafeBufferPointer { pipeline.handleAccessUnit($0.baseAddress!, $0.count) }
            let deadline = Date().addingTimeInterval(2)
            while reports < expected && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            assert(reports == expected, "A same-resolution reconnect must report dimensions to reopen the window")
        }
        print("Video reconnect checks passed")
    }
}
