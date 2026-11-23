import Foundation

public enum ExtensionWebsiteAccessMode: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case allWebsites
    case ask
    case specificSites

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .allWebsites: L10n.string("settings.extensions.access_all")
        case .ask: L10n.string("settings.extensions.access_ask")
        case .specificSites: L10n.string("settings.extensions.access_specific")
        }
    }
}

public enum InstalledExtensionSourceKind: String, Codable, Equatable, Sendable {
    case copiedPackage
    case safariAppExtension
}

public struct InstalledExtension: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var folderName: String
    public var displayName: String
    public var version: String
    public var enabled: Bool
    public var grantedPermissions: [String]
    public var deniedPermissions: [String]
    public var grantedMatchPatterns: [String]
    public var deniedMatchPatterns: [String]
    public var allURLsGranted: Bool
    public var websiteAccessMode: ExtensionWebsiteAccessMode
    public var contextUniqueIdentifier: String
    public var pinnedToToolbar: Bool
    public var hasBootstrappedPermissions: Bool
    public var installedAt: Date
    public var sourceKind: InstalledExtensionSourceKind
    public var sourceAppPath: String?
    public var sourceAppExtensionPath: String?
    public var sourceAppExtensionBundleID: String?
    public var sourceAppVersion: String?
    public var sourceAppBuild: String?

    public init(
        id: String,
        folderName: String,
        displayName: String,
        version: String,
        enabled: Bool = true,
        grantedPermissions: [String] = [],
        deniedPermissions: [String] = [],
        grantedMatchPatterns: [String] = [],
        deniedMatchPatterns: [String] = [],
        allURLsGranted: Bool = true,
        websiteAccessMode: ExtensionWebsiteAccessMode = .allWebsites,
        contextUniqueIdentifier: String = UUID().uuidString.lowercased(),
        pinnedToToolbar: Bool = true,
        hasBootstrappedPermissions: Bool = false,
        installedAt: Date = Date(),
        sourceKind: InstalledExtensionSourceKind = .copiedPackage,
        sourceAppPath: String? = nil,
        sourceAppExtensionPath: String? = nil,
        sourceAppExtensionBundleID: String? = nil,
        sourceAppVersion: String? = nil,
        sourceAppBuild: String? = nil
    ) {
        self.id = id
        self.folderName = folderName
        self.displayName = displayName
        self.version = version
        self.enabled = enabled
        self.grantedPermissions = grantedPermissions
        self.deniedPermissions = deniedPermissions
        self.grantedMatchPatterns = grantedMatchPatterns
        self.deniedMatchPatterns = deniedMatchPatterns
        self.allURLsGranted = allURLsGranted
        self.websiteAccessMode = websiteAccessMode
        self.contextUniqueIdentifier = contextUniqueIdentifier
        self.pinnedToToolbar = pinnedToToolbar
        self.hasBootstrappedPermissions = hasBootstrappedPermissions
        self.installedAt = installedAt
        self.sourceKind = sourceKind
        self.sourceAppPath = sourceAppPath
        self.sourceAppExtensionPath = sourceAppExtensionPath
        self.sourceAppExtensionBundleID = sourceAppExtensionBundleID
        self.sourceAppVersion = sourceAppVersion
        self.sourceAppBuild = sourceAppBuild
    }

    private enum CodingKeys: String, CodingKey {
        case id, folderName, displayName, version, enabled
        case grantedPermissions, deniedPermissions
        case grantedMatchPatterns, deniedMatchPatterns
        case allURLsGranted, websiteAccessMode
        case contextUniqueIdentifier, pinnedToToolbar
        case hasBootstrappedPermissions, installedAt
        case sourceKind, sourceAppPath, sourceAppExtensionPath
        case sourceAppExtensionBundleID, sourceAppVersion, sourceAppBuild
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = try c.decode(String.self, forKey: .id)
        self.id = decodedID
        self.folderName = try c.decodeIfPresent(String.self, forKey: .folderName) ?? decodedID
        self.displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? decodedID
        self.version = try c.decodeIfPresent(String.self, forKey: .version) ?? "0.0"
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.grantedPermissions = try c.decodeIfPresent([String].self, forKey: .grantedPermissions) ?? []
        self.deniedPermissions = try c.decodeIfPresent([String].self, forKey: .deniedPermissions) ?? []
        self.grantedMatchPatterns = try c.decodeIfPresent([String].self, forKey: .grantedMatchPatterns) ?? []
        self.deniedMatchPatterns = try c.decodeIfPresent([String].self, forKey: .deniedMatchPatterns) ?? []
        let allGranted = try c.decodeIfPresent(Bool.self, forKey: .allURLsGranted) ?? true
        self.allURLsGranted = allGranted
        self.websiteAccessMode = try c.decodeIfPresent(ExtensionWebsiteAccessMode.self, forKey: .websiteAccessMode)
            ?? (allGranted ? .allWebsites : .specificSites)
        self.contextUniqueIdentifier = try c.decodeIfPresent(String.self, forKey: .contextUniqueIdentifier)
            ?? UUID().uuidString.lowercased()
        self.pinnedToToolbar = try c.decodeIfPresent(Bool.self, forKey: .pinnedToToolbar) ?? true
        self.hasBootstrappedPermissions = try c.decodeIfPresent(Bool.self, forKey: .hasBootstrappedPermissions) ?? false
        self.installedAt = try c.decodeIfPresent(Date.self, forKey: .installedAt) ?? Date()
        self.sourceKind = try c.decodeIfPresent(InstalledExtensionSourceKind.self, forKey: .sourceKind) ?? .copiedPackage
        self.sourceAppPath = try c.decodeIfPresent(String.self, forKey: .sourceAppPath)
        self.sourceAppExtensionPath = try c.decodeIfPresent(String.self, forKey: .sourceAppExtensionPath)
        self.sourceAppExtensionBundleID = try c.decodeIfPresent(String.self, forKey: .sourceAppExtensionBundleID)
        self.sourceAppVersion = try c.decodeIfPresent(String.self, forKey: .sourceAppVersion)
        self.sourceAppBuild = try c.decodeIfPresent(String.self, forKey: .sourceAppBuild)
    }
}

public struct AutomationExtensionCommand: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var shortcut: String?

    public init(id: String, title: String, shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.shortcut = shortcut
    }
}

public struct AutomationExtensionSummary: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var version: String
    public var enabled: Bool
    public var loaded: Bool
    public var errors: [String]
    public var commands: [AutomationExtensionCommand]

    public init(
        id: String,
        name: String,
        version: String,
        enabled: Bool,
        loaded: Bool,
        errors: [String] = [],
        commands: [AutomationExtensionCommand] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.enabled = enabled
        self.loaded = loaded
        self.errors = errors
        self.commands = commands
    }
}

public struct AutomationExtensionCommandResult: Codable, Equatable, Sendable {
    public var ok: Bool
    public var extensionID: String
    public var commandID: String

    public init(ok: Bool, extensionID: String, commandID: String) {
        self.ok = ok
        self.extensionID = extensionID
        self.commandID = commandID
    }
}
