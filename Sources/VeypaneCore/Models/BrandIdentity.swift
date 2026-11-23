import Foundation

/// Canonical branding and backward-compatible storage/IPC identifiers for Veypane
/// (formerly developed under the working names Sidelark and SlideCraft).
/// Preserves `com.slidecraft.app`, `SlideCraftApp` (`CFBundleExecutable`), and
/// `~/Library/Application Support/SlideCraft` so all existing workspaces, profiles,
/// website data stores, Accessibility permissions, and browser extensions remain intact.
public enum AppBrandIdentity {
    public static let productName = "Veypane"
    public static let marketingVersion = "1.2.10"
    public static let buildNumber = "13"
    public static let bundleIdentifier = "com.slidecraft.app"
    public static let applicationSupportFolderName = "SlideCraft"
    public static let bundleExecutableName = "SlideCraftApp"
    public static let appBundleName = "Veypane.app"
    public static let appArchiveName = "Veypane.zip"
    public static let iconResourceName = "Veypane"
    public static let legacyIconResourceName = "Sidelark"

    public static let primaryURLScheme = "veypane"
    public static let legacySidelarkURLScheme = "sidelark"
    public static let legacyURLScheme = "slidecraft"
    public static let legacyURLSchemes: [String] = [legacySidelarkURLScheme, legacyURLScheme]
    public static let supportedURLSchemes: [String] = [primaryURLScheme, legacySidelarkURLScheme, legacyURLScheme]

    public static let primaryCLIName = "veypanectl"
    public static let legacySidelarkCLIName = "sidelarkctl"
    public static let legacyCLIName = "slidecraftctl"
    public static let legacyCLINames: [String] = [legacySidelarkCLIName, legacyCLIName]
    public static let supportedCLINames: [String] = [primaryCLIName, legacySidelarkCLIName, legacyCLIName]

    public static func isSupportedURLScheme(_ rawScheme: String?) -> Bool {
        guard let lower = rawScheme?.lowercased() else { return false }
        return supportedURLSchemes.contains(lower)
    }

    public static func resolvedCLIInvocationName(from arguments: [String]) -> String {
        guard let first = arguments.first, !first.isEmpty else {
            return primaryCLIName
        }
        let base = URL(fileURLWithPath: first).lastPathComponent
        if supportedCLINames.contains(base) {
            return base
        }
        return primaryCLIName
    }

    public static func preferredURLScheme(forCLIInvocationName cliName: String) -> String {
        switch cliName {
        case legacyCLIName:
            return legacyURLScheme
        case legacySidelarkCLIName:
            return legacySidelarkURLScheme
        default:
            return primaryURLScheme
        }
    }
}
