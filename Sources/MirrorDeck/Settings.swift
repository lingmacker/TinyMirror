import Foundation

enum MirrorResolution: Int, CaseIterable {
    case hd = 720, fullHD = 1080, quadHD = 1440, ultraHD = 2160

    var width: Int { rawValue * 16 / 9 }
    var usesHEVC: Bool { rawValue > 1080 }
    var title: String {
        switch self {
        case .hd: return String(localized: "720p — Smooth", bundle: .appLocalization)
        case .fullHD: return String(localized: "1080p — Compatible", bundle: .appLocalization)
        case .quadHD: return String(localized: "2K (1440p) — HEVC", bundle: .appLocalization)
        case .ultraHD: return String(localized: "4K — HEVC", bundle: .appLocalization)
        }
    }
}

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

    static var resolution: MirrorResolution {
        get { MirrorResolution(rawValue: defaults.integer(forKey: "resolution")) ?? .quadHD }
        set { defaults.set(newValue.rawValue, forKey: "resolution") }
    }

    /// Whether the mirror window floats above other applications.
    static var alwaysOnTop: Bool {
        get { defaults.object(forKey: "alwaysOnTop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "alwaysOnTop") }
    }
}
