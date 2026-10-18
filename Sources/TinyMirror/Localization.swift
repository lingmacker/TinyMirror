import Foundation

extension Bundle {
    static let appLocalization: Bundle = {
        let resources = Bundle.module
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
