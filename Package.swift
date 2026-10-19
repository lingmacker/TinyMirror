// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TinyMirror",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    targets: [
        // Exposes native/include/mirror_bridge.h to Swift; the implementation
        // is linked from native/build/libMirrorCore.dylib (built by native/build.sh).
        .target(
            name: "CMirrorBridge",
            path: "Sources/CMirrorBridge",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "TinyMirror",
            dependencies: ["CMirrorBridge"],
            path: "Sources/TinyMirror",
            // Bundle metadata and icon sources are handled by scripts/build-app.sh.
            exclude: [
                "Resources/Info.plist",
                "Resources/AppIcon.icon",
                "Resources/MenuBarIcon.svg",
                "Resources/MenuBarIconConnected.svg",
            ],
            resources: [.process("Resources")],
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
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
