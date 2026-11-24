import Foundation

/// Canonical branding, storage, bundle, URL scheme, CLI, and IPC identifiers for Veypane.
public enum AppBrandIdentity {
    public static let productName = "Veypane"
    public static let marketingVersion = "1.2.10"
    public static let buildNumber = "13"
    public static let bundleIdentifier = "com.veypane.app"
    public static let urlSchemeBundleName = "com.veypane.urlscheme"
    public static let applicationSupportFolderName = "Veypane"
    public static let bundleExecutableName = "VeypaneApp"
    public static let appBundleName = "Veypane.app"
    public static let appArchiveName = "Veypane.zip"
    public static let iconResourceName = "Veypane"

    public static let primaryURLScheme = "veypane"
    public static let supportedURLSchemes: [String] = [primaryURLScheme]

    public static let primaryCLIName = "veypanectl"
    public static let supportedCLINames: [String] = [primaryCLIName]

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
        _ = cliName
        return primaryURLScheme
    }
}
