// Run from the repository root:
// swiftc -target "$(uname -m)-apple-macos26.0" -module-cache-path .build/module-cache Sources/MirrorDeck/{Localization,Settings,StatusBarController}.swift scripts/TestResources.swift scripts/check-resolutions.swift -o .build/check-resolutions
// .build/check-resolutions -AppleLanguages '(zh-Hans)'
import AppKit

@main
struct ResolutionChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        let defaults = UserDefaults.standard
        let originalArguments = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain) }
        for value in [0, -1, 9999] {
            defaults.setVolatileDomain(["resolution": value], forName: UserDefaults.argumentDomain)
            assert(Settings.resolution == .quadHD, "Unknown preferences must fall back to the 2K default")
        }
        for resolution in MirrorResolution.allCases {
            defaults.setVolatileDomain(["resolution": resolution.rawValue], forName: UserDefaults.argumentDomain)
            assert(Settings.resolution == resolution)
            assert(resolution.width * 9 == resolution.rawValue * 16)
            assert(resolution.usesHEVC == (resolution.rawValue > 1080))
        }

        let statusBar = StatusBarController()
        let menu = NSApp.mainMenu!.items.first!.submenu!
        let qualityMenu = menu.items.compactMap(\.submenu).first!
        let choices = qualityMenu.items.filter { $0.action != nil }
        assert(choices.map(\.tag) == [720, 1080, 1440, 2160])
        var selected: [MirrorResolution] = []
        statusBar.onResolutionChange = {
            selected.append($0)
            statusBar.setResolution($0)
        }
        statusBar.setResolution(.fullHD)
        assert(choices.filter { $0.state == .on }.map(\.tag) == [1080])
        for (index, resolution) in MirrorResolution.allCases.enumerated() {
            qualityMenu.performActionForItem(at: index)
            assert(selected.last == resolution)
            assert(choices.filter { $0.state == .on }.map(\.tag) == [resolution.rawValue])
        }
        statusBar.setResolutionEnabled(false)
        assert(choices.allSatisfy { !$0.isEnabled })
        let before = selected.count
        qualityMenu.performActionForItem(at: 0)
        assert(selected.count == before, "Disabled resolution choices must never change a live stream")
        statusBar.setResolutionEnabled(true)
        qualityMenu.performActionForItem(at: 0)
        assert(selected.count == before + 1)

        statusBar.setVideoSize(width: 996, height: 2160, isH265: true)
        let actual = menu.items.first { $0.title.contains("996") }!
        assert(actual.title.contains(String.localizedStringWithFormat("%d", 2160)) && actual.title.contains("HEVC") && !actual.isHidden)
        let stop = menu.items.first { $0.title == String(localized: "Stop Mirroring", bundle: .appLocalization) }!
        var stops = 0
        statusBar.onStopMirroring = { stops += 1 }
        assert(!stop.isEnabled)
        menu.performActionForItem(at: menu.index(of: stop))
        assert(stops == 0, "An idle receiver must not offer a stop action")
        statusBar.setClient("Test iPhone")
        assert(stop.isEnabled)
        menu.performActionForItem(at: menu.index(of: stop))
        assert(stops == 1, "Stop must use the menu callback, not terminate the application")
        statusBar.setClient(nil)
        assert(actual.isHidden && !stop.isEnabled)
        print("Resolution preferences, menu selection, live-stream guard and actual size checks passed")
    }
}
