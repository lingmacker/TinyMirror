import Foundation

extension Bundle {
    // Packaged apps must not depend on SwiftPM's toolchain-specific resource paths.
    static let appResources: Bundle = Bundle.main.bundleURL.pathExtension == "app"
        ? .main : .module

    static let appLocalization: Bundle = {
        let resources = Bundle.appResources
        // Bare SwiftPM executables have no declared main-bundle languages.
        guard Bundle.main.localizations.isEmpty else { return resources }
        let language = Bundle.preferredLocalizations(
            from: resources.localizations,
            forPreferences: Locale.preferredLanguages + ["en"]).first ?? "en"
        guard let url = resources.url(forResource: language, withExtension: "lproj"),
              let localized = Bundle(url: url) else { return resources }
        return localized
    }()
}
