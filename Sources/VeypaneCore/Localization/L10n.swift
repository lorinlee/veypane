import Foundation

public enum L10n {
    private static let bundleNames = [
        "Veypane_VeypaneCore.bundle"
    ]

    private static var resourceBundle: Bundle {
        // 1. Inside packaged .app Contents/Resources/
        for name in bundleNames {
            if let resURL = Bundle.main.resourceURL?.appendingPathComponent(name),
               let bundle = Bundle(url: resURL) {
                return bundle
            }
        }
        // 2. Helper CLI inside .app/Contents/MacOS/ -> ../Resources/Veypane_VeypaneCore.bundle
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            for name in bundleNames {
                let appResourcesURL = execDir
                    .deletingLastPathComponent()
                    .appendingPathComponent("Resources", isDirectory: true)
                    .appendingPathComponent(name, isDirectory: true)
                if let bundle = Bundle(url: appResourcesURL) {
                    return bundle
                }
            }
            // 3. Beside executable (e.g. .build/release/)
            for name in bundleNames {
                let siblingURL = execDir.appendingPathComponent(name)
                if let bundle = Bundle(url: siblingURL) {
                    return bundle
                }
            }
        }
        // 4. Direct .lproj folders inside Bundle.main (e.g. Veypane.app/Contents/Resources/en.lproj)
        if Bundle.main.path(forResource: "en", ofType: "lproj") != nil {
            return Bundle.main
        }
        // 5. SwiftPM generated Bundle.module (test runner / local swift run)
        return Bundle.module
    }

    public static var iconFileURL: URL? {
        let iconName = AppBrandIdentity.iconResourceName
        if let mainIcon = Bundle.main.url(forResource: iconName, withExtension: "icns") {
            return mainIcon
        }
        if let execDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            let appIcon = execDir
                .deletingLastPathComponent()
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("\(iconName).icns", isDirectory: false)
            if FileManager.default.fileExists(atPath: appIcon.path) {
                return appIcon
            }
        }
        if let resIcon = resourceBundle.url(forResource: iconName, withExtension: "icns") {
            return resIcon
        }
        return nil
    }

    public static var currentLanguageCode: String {
        resolvedLanguageCode(preferred: Locale.preferredLanguages)
    }

    public static func resolvedLanguageCode(preferred: [String]) -> String {
        for tag in preferred {
            let lower = tag.lowercased()
            if lower.hasPrefix("zh-hans") || lower == "zh-cn" || lower == "zh-sg" || lower == "zh" {
                return "zh-Hans"
            }
            if lower.hasPrefix("en") {
                return "en"
            }
        }
        return "en"
    }

    private static func lprojBundle(for language: String, in baseBundle: Bundle) -> Bundle? {
        for candidate in [language, language.lowercased()] {
            if let path = baseBundle.path(forResource: candidate, ofType: "lproj"),
               let bundle = Bundle(path: path) {
                return bundle
            }
            if let directURL = baseBundle.bundleURL
                .appendingPathComponent("\(candidate).lproj", isDirectory: true) as URL?,
               let bundle = Bundle(url: directURL),
               bundle.url(forResource: "Localizable", withExtension: "strings") != nil {
                return bundle
            }
        }
        return nil
    }

    public static func string(_ key: String, language: String? = nil) -> String {
        let lang = language ?? currentLanguageCode
        let baseBundle = resourceBundle

        if let localizedBundle = lprojBundle(for: lang, in: baseBundle) {
            let found = localizedBundle.localizedString(forKey: key, value: nil, table: "Localizable")
            if found != key {
                return found
            }
        }

        if lang != "en", let enBundle = lprojBundle(for: "en", in: baseBundle) {
            return enBundle.localizedString(forKey: key, value: key, table: "Localizable")
        }

        return baseBundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    public static func format(_ key: String, language: String? = nil, _ args: CVarArg...) -> String {
        let template = string(key, language: language)
        return String(format: template, locale: Locale(identifier: language ?? currentLanguageCode), arguments: args)
    }
}
