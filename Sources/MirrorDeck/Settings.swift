import Foundation

enum Settings {
    private static let defaults = UserDefaults.standard

    /// Name shown in the iOS Screen Mirroring list.
    static var receiverName: String {
        get {
            if let custom = defaults.string(forKey: "receiverName") { return custom }
            let host = Host.current().localizedName ?? "Mac"
            return "\(host) (MirrorDeck)"
        }
        set { defaults.set(newValue, forKey: "receiverName") }
    }

    /// Whether the mirror window floats above other applications.
    static var alwaysOnTop: Bool {
        get { defaults.object(forKey: "alwaysOnTop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "alwaysOnTop") }
    }
}
