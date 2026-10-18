// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MirrorDeck",
    platforms: [.macOS(.v14)],
    targets: [
        // Exposes native/include/mirror_bridge.h to Swift; the implementation
        // is linked from native/build/libMirrorCore.dylib (built by native/build.sh).
        .target(
            name: "CMirrorBridge",
            path: "Sources/CMirrorBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "MirrorDeck",
            dependencies: ["CMirrorBridge"],
            path: "Sources/MirrorDeck",
            linkerSettings: [
                // libMirrorCore.dylib is linked dynamically and kept replaceable
                // (it holds all copyleft code — see licenses/NOTICE.md).
                // Cover SwiftPM's native and Xcode build layouts, plus app bundles.
                .unsafeFlags([
                    "-Lnative/build",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../../native/build",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../../native/build",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../../native/build",
                    "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks",
                ]),
                .linkedLibrary("MirrorCore"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
