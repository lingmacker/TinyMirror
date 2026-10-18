// Run from the repository root:
// swiftc -target "$(uname -m)-apple-macos26.0" -module-cache-path .build/module-cache Sources/MirrorDeck/Localization.swift scripts/TestResources.swift scripts/check-localizations.swift -o .build/check-localizations
// .build/check-localizations -AppleLanguages '(zh-Hans)'
import Foundation

@main
struct LocalizationChecks {
    static func table(at path: String) throws -> [String: String] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
    }

    static func main() throws {
        let root = "Sources/MirrorDeck/Resources"
        let english = try table(at: "\(root)/en.lproj/Localizable.strings")
        let chinese = try table(at: "\(root)/zh-Hans.lproj/Localizable.strings")
        assert(Set(english.keys) == Set(chinese.keys), "Every key needs both translations")
        let keyPattern = try NSRegularExpression(pattern: #"String\(localized:\s*"([^"]+)""#)
        let formats = try NSRegularExpression(pattern: #"(?<!%)%(?:\d+\$)?[@dfiu]"#)
        var usedKeys = Set<String>()
        for file in try FileManager.default.contentsOfDirectory(atPath: "Sources/MirrorDeck") where file.hasSuffix(".swift") {
            let source = try String(contentsOfFile: "Sources/MirrorDeck/\(file)", encoding: .utf8) as NSString
            for match in keyPattern.matches(in: source as String, range: NSRange(location: 0, length: source.length)) {
                usedKeys.insert(source.substring(with: match.range(at: 1)))
            }
        }
        assert(usedKeys == Set(english.keys), "Translation keys must exactly cover the UI strings")
        for (key, value) in english {
            let translated = chinese[key]!
            assert(!value.isEmpty && !translated.isEmpty)
            let enFormats = formats.matches(in: value, range: NSRange(location: 0, length: (value as NSString).length)).map {
                (value as NSString).substring(with: $0.range)
            }
            let zhFormats = formats.matches(in: translated, range: NSRange(location: 0, length: (translated as NSString).length)).map {
                (translated as NSString).substring(with: $0.range)
            }
            assert(enFormats == zhFormats, "Format arguments must match for \(key)")
        }
        for (language, expected) in [("en", "Ready to mirror"), ("zh-Hans", "准备投屏")] {
            let bundle = Bundle(path: "\(root)/\(language).lproj")!
            assert(bundle.localizedString(forKey: "Ready to mirror", value: nil, table: nil) == expected)
            let name = "iPhone 100% · 手机"
            let format = bundle.localizedString(forKey: "Mirroring: %@", value: nil, table: nil)
            assert(String.localizedStringWithFormat(format, name).contains(name))
            let permission = try table(at: "packaging/\(language).lproj/InfoPlist.strings")
            assert(permission["NSLocalNetworkUsageDescription"]?.isEmpty == false)
        }
        let language = Bundle.preferredLocalizations(
            from: ["en", "zh-Hans"], forPreferences: Locale.preferredLanguages + ["en"]).first!
        let expected = language == "zh-Hans" ? "窗口置顶" : "Keep Window on Top"
        assert(String(localized: "Keep Window on Top", bundle: .appLocalization) == expected,
               "System language selection and English fallback must work")
        if Bundle.main.bundleURL.pathExtension == "app" {
            assert(Bundle.appLocalization.bundlePath.hasPrefix(Bundle.main.resourceURL!.path),
                   "Packaged apps must load their embedded resource bundle")
            let permission = try table(at: "packaging/\(language).lproj/InfoPlist.strings")
            assert(Bundle.main.localizedInfoDictionary?["NSLocalNetworkUsageDescription"] as? String == permission["NSLocalNetworkUsageDescription"],
                   "The local network permission must use the app’s selected language")
        }
        print("Localization checks passed: \(english.count) keys, selected \(language)")
        print("Resource bundle: \(Bundle.appLocalization.bundlePath)")
    }
}
