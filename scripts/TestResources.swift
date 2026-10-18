import Foundation

// Standalone swiftc checks read the same tables without SwiftPM's generated accessor.
extension Bundle {
    static let module = Bundle(path: "Sources/MirrorDeck/Resources")!
}
