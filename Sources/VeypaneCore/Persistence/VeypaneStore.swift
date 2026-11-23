import Foundation

public struct StoreLoadResult: Sendable {
    public var state: WorkspaceState
    public var didRecoverFromCorruption: Bool
    public var backupFileURL: URL?
    public var migratedFromVersion: Int?

    public init(
        state: WorkspaceState,
        didRecoverFromCorruption: Bool = false,
        backupFileURL: URL? = nil,
        migratedFromVersion: Int? = nil
    ) {
        self.state = state
        self.didRecoverFromCorruption = didRecoverFromCorruption
        self.backupFileURL = backupFileURL
        self.migratedFromVersion = migratedFromVersion
    }
}

/// Portable export/sync payload (deliberately excludes local auth tokens and browser cookies per SPEC.md #21 & #23).
public struct SettingsExportBundle: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var pads: [Pad]
    public var selectedPadID: UUID?
    public var activeProfileID: UUID?
    public var profiles: [BrowserProfile]
    public var favorites: [FavoriteItem]
    public var siteSizeRules: [SiteSizeRule]
    public var injectionRules: [InjectionRule]
    public var settings: ExportedPreferences

    public struct ExportedPreferences: Codable, Equatable, Sendable {
        public var anchor: AnchorPosition
        public var widthPercent: Double
        public var heightPercent: Double
        public var edgeInset: Double
        public var animationDuration: Double
        public var edgeTrigger: EdgeTriggerSettings
        public var toggleHotkey: HotkeyBinding
        public var searchEngine: SearchEnginePreset
        public var customSearchTemplate: String
        public var newWindowBehavior: NewWindowBehavior
        public var isPinnedOpen: Bool
        public var isAlwaysOnTop: Bool
        public var commandWHidesPanel: Bool
        public var enableTrackpadGestures: Bool
        public var autoHibernateMinutes: Int
        public var maxLivePads: Int
        public var appearance: AppearanceSettings
        public var contentBlocker: ContentBlockerSettings

        public init(from appSettings: AppSettings) {
            self.anchor = appSettings.anchor
            self.widthPercent = appSettings.widthPercent
            self.heightPercent = appSettings.heightPercent
            self.edgeInset = appSettings.edgeInset
            self.animationDuration = appSettings.animationDuration
            self.edgeTrigger = appSettings.edgeTrigger
            self.toggleHotkey = appSettings.toggleHotkey
            self.searchEngine = appSettings.searchEngine
            self.customSearchTemplate = appSettings.customSearchTemplate
            self.newWindowBehavior = appSettings.newWindowBehavior
            self.isPinnedOpen = appSettings.isPinnedOpen
            self.isAlwaysOnTop = appSettings.isAlwaysOnTop
            self.commandWHidesPanel = appSettings.commandWHidesPanel
            self.enableTrackpadGestures = appSettings.enableTrackpadGestures
            self.autoHibernateMinutes = AppSettings.sanitizedAutoHibernateMinutes(appSettings.autoHibernateMinutes)
            self.maxLivePads = AppSettings.sanitizedMaxLivePads(appSettings.maxLivePads)
            self.appearance = appSettings.appearance
            self.contentBlocker = appSettings.contentBlocker
        }

        private enum CodingKeys: String, CodingKey {
            case anchor, widthPercent, heightPercent, edgeInset, animationDuration
            case edgeTrigger, toggleHotkey, searchEngine, customSearchTemplate, newWindowBehavior
            case isPinnedOpen, isAlwaysOnTop, commandWHidesPanel, enableTrackpadGestures
            case autoHibernateMinutes, maxLivePads, appearance, contentBlocker
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.anchor = try c.decodeIfPresent(AnchorPosition.self, forKey: .anchor) ?? .right
            self.widthPercent = try c.decodeIfPresent(Double.self, forKey: .widthPercent) ?? AppSettings.defaultWidthPercent
            self.heightPercent = try c.decodeIfPresent(Double.self, forKey: .heightPercent) ?? AppSettings.defaultHeightPercent
            self.edgeInset = try c.decodeIfPresent(Double.self, forKey: .edgeInset) ?? AppSettings.defaultEdgeInset
            self.animationDuration = try c.decodeIfPresent(Double.self, forKey: .animationDuration) ?? AppSettings.defaultAnimationDuration
            self.edgeTrigger = try c.decodeIfPresent(EdgeTriggerSettings.self, forKey: .edgeTrigger) ?? EdgeTriggerSettings()
            self.toggleHotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .toggleHotkey) ?? .defaultToggle
            self.searchEngine = try c.decodeIfPresent(SearchEnginePreset.self, forKey: .searchEngine) ?? .duckDuckGo
            self.customSearchTemplate = try c.decodeIfPresent(String.self, forKey: .customSearchTemplate) ?? ""
            self.newWindowBehavior = try c.decodeIfPresent(NewWindowBehavior.self, forKey: .newWindowBehavior) ?? .openInNewPad
            self.isPinnedOpen = try c.decodeIfPresent(Bool.self, forKey: .isPinnedOpen) ?? false
            self.isAlwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .isAlwaysOnTop) ?? false
            self.commandWHidesPanel = try c.decodeIfPresent(Bool.self, forKey: .commandWHidesPanel) ?? true
            self.enableTrackpadGestures = try c.decodeIfPresent(Bool.self, forKey: .enableTrackpadGestures) ?? true
            let rawHibernate = try c.decodeIfPresent(Int.self, forKey: .autoHibernateMinutes) ?? AppSettings.defaultAutoHibernateMinutes
            self.autoHibernateMinutes = AppSettings.sanitizedAutoHibernateMinutes(rawHibernate)
            let rawMaxLive = try c.decodeIfPresent(Int.self, forKey: .maxLivePads) ?? AppSettings.defaultMaxLivePads
            self.maxLivePads = AppSettings.sanitizedMaxLivePads(rawMaxLive)
            self.appearance = try c.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? AppearanceSettings()
            self.contentBlocker = try c.decodeIfPresent(ContentBlockerSettings.self, forKey: .contentBlocker) ?? ContentBlockerSettings()
        }

        public func applying(onto existing: AppSettings) -> AppSettings {
            var copy = existing
            copy.anchor = anchor
            copy.widthPercent = widthPercent
            copy.heightPercent = heightPercent
            copy.edgeInset = edgeInset
            copy.animationDuration = animationDuration
            copy.edgeTrigger = edgeTrigger
            copy.toggleHotkey = toggleHotkey
            copy.searchEngine = searchEngine
            copy.customSearchTemplate = customSearchTemplate
            copy.newWindowBehavior = newWindowBehavior
            copy.isPinnedOpen = isPinnedOpen
            copy.isAlwaysOnTop = isAlwaysOnTop
            copy.commandWHidesPanel = commandWHidesPanel
            copy.enableTrackpadGestures = enableTrackpadGestures
            copy.autoHibernateMinutes = AppSettings.sanitizedAutoHibernateMinutes(autoHibernateMinutes)
            copy.maxLivePads = AppSettings.sanitizedMaxLivePads(maxLivePads)
            copy.appearance = appearance
            copy.contentBlocker = contentBlocker
            return copy
        }
    }

    public init(from state: WorkspaceState, exportedAt: Date = Date()) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.pads = state.pads
        self.selectedPadID = state.selectedPadID
        self.activeProfileID = state.activeProfileID
        self.profiles = state.profiles
        self.favorites = state.favorites
        self.siteSizeRules = state.siteSizeRules
        self.injectionRules = state.injectionRules
        self.settings = ExportedPreferences(from: state.settings)
    }

    public func applying(to state: WorkspaceState, merge: Bool = false) -> WorkspaceState {
        var next = state
        if merge {
            let existingPadIDs = Set(next.pads.map(\.id))
            for pad in pads where !existingPadIDs.contains(pad.id) {
                next.pads.append(pad)
            }
            let existingProfileIDs = Set(next.profiles.map(\.id))
            for profile in profiles where !existingProfileIDs.contains(profile.id) {
                next.profiles.append(profile)
            }
            let existingFavURLs = Set(next.favorites.map(\.url))
            for fav in favorites where !existingFavURLs.contains(fav.url) {
                next.favorites.append(fav)
            }
            let existingRuleIDs = Set(next.siteSizeRules.map(\.id))
            for rule in siteSizeRules where !existingRuleIDs.contains(rule.id) {
                next.siteSizeRules.append(rule)
            }
            let existingInjIDs = Set(next.injectionRules.map(\.id))
            for rule in injectionRules where !existingInjIDs.contains(rule.id) {
                next.injectionRules.append(rule)
            }
        } else {
            next.pads = pads
            next.selectedPadID = selectedPadID ?? pads.first?.id
            next.profiles = profiles.isEmpty ? BrowserProfile.defaultProfiles() : profiles
            next.activeProfileID = activeProfileID ?? next.profiles.first?.id
            next.favorites = favorites
            next.siteSizeRules = siteSizeRules
            next.injectionRules = injectionRules
            next.settings = settings.applying(onto: next.settings)
        }
        next.updatedAt = Date()
        return next
    }
}

public final class VeypaneStore: Sendable {
    /// Preserved sync snapshot filename (Bucket A) so existing folder / iCloud Drive sync continues seamlessly.
    public static let syncSnapshotFileName = "slidecraft-sync.json"
    public static let alternateSyncSnapshotFileName = "veypane-sync.json"
    public let directoryURL: URL
    public let stateFileURL: URL
    public let uiStateFileURL: URL
    public let extensionsDirectoryURL: URL
    public let faviconsDirectoryURL: URL

    public init(directoryURL: URL? = nil) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
            self.directoryURL = appSupport.appendingPathComponent(AppBrandIdentity.applicationSupportFolderName, isDirectory: true)
        }
        self.stateFileURL = self.directoryURL.appendingPathComponent("workspace.json", isDirectory: false)
        self.uiStateFileURL = self.directoryURL.appendingPathComponent("ui-state.json", isDirectory: false)
        self.extensionsDirectoryURL = self.directoryURL.appendingPathComponent("Extensions", isDirectory: true)
        self.faviconsDirectoryURL = self.directoryURL.appendingPathComponent("Favicons", isDirectory: true)
    }

    public func writeUIState(_ snapshot: UIStateSnapshot) throws {
        let data = try Self.makeEncoder().encode(snapshot)
        try Self.writeAtomically(data: data, to: uiStateFileURL)
    }

    public func readUIStateData() throws -> Data {
        try Data(contentsOf: uiStateFileURL)
    }

    public func readUIState() throws -> UIStateSnapshot {
        let data = try readUIStateData()
        return try Self.makeDecoder().decode(UIStateSnapshot.self, from: data)
    }

    public static var defaultiCloudSyncFolderURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/SlideCraft", isDirectory: true)
    }

    public func load() -> StoreLoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stateFileURL.path) else {
            let initial = WorkspaceState.makeDefault()
            return StoreLoadResult(state: initial)
        }

        do {
            let rawData = try Data(contentsOf: stateFileURL)
            let (migratedData, oldVersion) = try StoreMigrator.migrateIfNeeded(data: rawData)
            let decoder = Self.makeDecoder()
            var decoded = try decoder.decode(WorkspaceState.self, from: migratedData)
            decoded.schemaVersion = WorkspaceState.currentSchemaVersion
            if decoded.profiles.isEmpty {
                decoded.profiles = BrowserProfile.defaultProfiles()
            }
            if decoded.selectedPadID == nil {
                decoded.selectedPadID = decoded.pads.first?.id
            }
            let didMigratePanelSize = decoded.settings.migrateLegacyPanelSizeIfNeeded()
            if (oldVersion != nil && oldVersion! < WorkspaceState.currentSchemaVersion) || didMigratePanelSize {
                try? save(decoded)
            }
            return StoreLoadResult(
                state: decoded,
                didRecoverFromCorruption: false,
                backupFileURL: nil,
                migratedFromVersion: oldVersion
            )
        } catch {
            // Corrupt file -> atomically back up and return safe defaults per SPEC.md
            let timestamp = Int(Date().timeIntervalSince1970)
            let backupURL = directoryURL.appendingPathComponent("workspace.corrupt-\(timestamp).json.bak")
            try? fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            try? fm.moveItem(at: stateFileURL, to: backupURL)

            let fallback = WorkspaceState.makeDefault()
            try? save(fallback)
            return StoreLoadResult(
                state: fallback,
                didRecoverFromCorruption: true,
                backupFileURL: backupURL,
                migratedFromVersion: nil
            )
        }
    }

    public func save(_ state: WorkspaceState) throws {
        var normalized = state
        normalized.schemaVersion = WorkspaceState.currentSchemaVersion
        normalized.updatedAt = Date()

        let fm = FileManager.default
        try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let encoder = Self.makeEncoder()
        let data = try encoder.encode(normalized)
        try Self.writeAtomically(data: data, to: stateFileURL)

        // Mirror portable bundle (no cookies, no auth token) to sync folder if configured
        if let syncPath = normalized.settings.syncFolderPath,
           !syncPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let syncDir = URL(fileURLWithPath: (syncPath as NSString).expandingTildeInPath, isDirectory: true)
            try? writeSyncSnapshot(for: normalized, toDirectory: syncDir)
        }
    }

    public func exportData(from state: WorkspaceState) throws -> Data {
        let bundle = SettingsExportBundle(from: state)
        return try Self.makeEncoder().encode(bundle)
    }

    public func importData(_ data: Data, into current: WorkspaceState, merge: Bool = false) throws -> WorkspaceState {
        let bundle = try Self.makeDecoder().decode(SettingsExportBundle.self, from: data)
        return bundle.applying(to: current, merge: merge)
    }

    public func writeSyncSnapshot(for state: WorkspaceState, toDirectory syncDir: URL) throws {
        try FileManager.default.createDirectory(at: syncDir, withIntermediateDirectories: true)
        let bundle = SettingsExportBundle(from: state, exportedAt: state.updatedAt)
        let data = try Self.makeEncoder().encode(bundle)
        let targetFile = syncDir.appendingPathComponent(Self.syncSnapshotFileName, isDirectory: false)
        try Self.writeAtomically(data: data, to: targetFile)
    }

    public func loadNewerSyncSnapshotIfAvailable(
        fromDirectory syncDir: URL,
        currentState: WorkspaceState
    ) throws -> WorkspaceState? {
        let candidates = [
            syncDir.appendingPathComponent(Self.alternateSyncSnapshotFileName, isDirectory: false),
            syncDir.appendingPathComponent(Self.syncSnapshotFileName, isDirectory: false)
        ]
        var newestBundle: SettingsExportBundle?
        for syncFile in candidates where FileManager.default.fileExists(atPath: syncFile.path) {
            let data = try Data(contentsOf: syncFile)
            let bundle = try Self.makeDecoder().decode(SettingsExportBundle.self, from: data)
            if let existing = newestBundle {
                if bundle.exportedAt > existing.exportedAt {
                    newestBundle = bundle
                }
            } else {
                newestBundle = bundle
            }
        }
        guard let bundle = newestBundle, bundle.exportedAt > currentState.updatedAt else {
            return nil
        }
        return bundle.applying(to: currentState, merge: false)
    }

    private static func writeAtomically(data: Data, to destinationURL: URL) throws {
        let fm = FileManager.default
        let parent = destinationURL.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let tempURL = parent.appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: tempURL, options: .atomic)
        if fm.fileExists(atPath: destinationURL.path) {
            _ = try fm.replaceItemAt(destinationURL, withItemAt: tempURL)
        } else {
            try fm.moveItem(at: tempURL, to: destinationURL)
        }
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public enum StoreMigrator {
    /// Migrates older schema JSON payloads (v1 or v2) into current schema v3 seamlessly.
    public static func migrateIfNeeded(data: Data) throws -> (Data, Int?) {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CocoaError(.coderReadCorrupt)
        }

        let originalVersion = (root["schemaVersion"] as? Int) ?? 1
        if originalVersion >= WorkspaceState.currentSchemaVersion {
            return (data, nil)
        }

        var workingVersion = originalVersion
        let nowISO = ISO8601DateFormatter().string(from: Date())

        // v1 -> v2: add profiles, favorites, siteSizeRules, closedPads, Phase 2 settings defaults
        if workingVersion < 2 {
            if root["profiles"] == nil {
                let defaultProfilesData = try VeypaneStore.makeEncoder().encode(BrowserProfile.defaultProfiles())
                root["profiles"] = try JSONSerialization.jsonObject(with: defaultProfilesData)
            }
            if root["favorites"] == nil {
                let defaultFavsData = try VeypaneStore.makeEncoder().encode(FavoriteItem.builtInPresets())
                root["favorites"] = try JSONSerialization.jsonObject(with: defaultFavsData)
            }
            if root["siteSizeRules"] == nil {
                root["siteSizeRules"] = []
            }
            if root["closedPads"] == nil {
                root["closedPads"] = []
            }
            workingVersion = 2
        }

        // v2 -> v3: add injectionRules, contentBlocker, automation, appearance defaults
        if workingVersion < 3 {
            if root["injectionRules"] == nil {
                root["injectionRules"] = []
            }
            if root["updatedAt"] == nil {
                root["updatedAt"] = nowISO
            }
            var settingsDict = (root["settings"] as? [String: Any]) ?? [:]
            let defaultSettingsData = try VeypaneStore.makeEncoder().encode(AppSettings())
            if let defaultSettingsObj = try JSONSerialization.jsonObject(with: defaultSettingsData) as? [String: Any] {
                for (key, value) in defaultSettingsObj where settingsDict[key] == nil {
                    settingsDict[key] = value
                }
            }
            root["settings"] = settingsDict

            // Fill any missing fields on legacy Pad dictionaries
            if var padsArray = root["pads"] as? [[String: Any]] {
                for idx in padsArray.indices {
                    if padsArray[idx]["symbolName"] == nil { padsArray[idx]["symbolName"] = "globe" }
                    if padsArray[idx]["userAgentPreset"] == nil { padsArray[idx]["userAgentPreset"] = "desktopSafari" }
                    if padsArray[idx]["isMuted"] == nil { padsArray[idx]["isMuted"] = false }
                    if padsArray[idx]["isInspectable"] == nil { padsArray[idx]["isInspectable"] = false }
                    if padsArray[idx]["isHibernated"] == nil { padsArray[idx]["isHibernated"] = false }
                    if padsArray[idx]["hasUnreadDot"] == nil { padsArray[idx]["hasUnreadDot"] = false }
                    if padsArray[idx]["pageZoom"] == nil { padsArray[idx]["pageZoom"] = 1.0 }
                    if padsArray[idx]["lastActiveAt"] == nil { padsArray[idx]["lastActiveAt"] = nowISO }
                    if padsArray[idx]["createdAt"] == nil { padsArray[idx]["createdAt"] = nowISO }
                }
                root["pads"] = padsArray
            }

            workingVersion = 3
        }

        // v3 -> v4: add recentHistory, onboarding flag, selectedSettingsPane
        if workingVersion < 4 {
            if root["recentHistory"] == nil {
                root["recentHistory"] = []
            }
            var settingsDict = (root["settings"] as? [String: Any]) ?? [:]
            if settingsDict["hasCompletedOnboarding"] == nil {
                settingsDict["hasCompletedOnboarding"] = false
            }
            if settingsDict["selectedSettingsPane"] == nil {
                settingsDict["selectedSettingsPane"] = SettingsPaneID.general.rawValue
            }
            root["settings"] = settingsDict
            workingVersion = 4
        }

        // v4 -> v5: add installedExtensions, webExtensionControllerID, panelSizeUserCustomized & legacy 34% / 653pt migration
        if workingVersion < 5 {
            if root["installedExtensions"] == nil {
                root["installedExtensions"] = []
            }
            if root["webExtensionControllerID"] == nil {
                root["webExtensionControllerID"] = UUID().uuidString
            }
            var settingsDict = (root["settings"] as? [String: Any]) ?? [:]
            let explicitCustomFlag = settingsDict["panelSizeUserCustomized"] as? Bool
            let storedWidthPct = settingsDict["widthPercent"] as? Double
            let storedFixedWidth = settingsDict["fixedWidth"] as? Double

            if explicitCustomFlag != true {
                let isLegacyPct = storedWidthPct.map { AppSettings.isLegacyDefaultWidthPercent($0) } ?? false
                let isLegacyFixed = storedFixedWidth.map { AppSettings.isLegacyDefaultFixedWidth($0) } ?? false

                if isLegacyPct || isLegacyFixed || storedWidthPct == nil {
                    settingsDict["widthPercent"] = AppSettings.defaultWidthPercent
                    settingsDict["heightPercent"] = AppSettings.defaultHeightPercent
                    if let inset = settingsDict["edgeInset"] as? Double, inset < 12.0 {
                        settingsDict["edgeInset"] = AppSettings.defaultEdgeInset
                    }
                    settingsDict.removeValue(forKey: "fixedWidth")
                    settingsDict["panelSizeUserCustomized"] = false
                } else if let w = storedWidthPct, abs(w - AppSettings.defaultWidthPercent) > 0.01 {
                    // User had explicitly selected a non-legacy custom width (e.g. 40% or 52%)
                    settingsDict["panelSizeUserCustomized"] = true
                } else {
                    settingsDict["panelSizeUserCustomized"] = false
                }
            }
            root["settings"] = settingsDict
            workingVersion = 5
        }

        // v5 -> v6: add hasCustomTitle & pauseCustomModifications on pads, preserving hand-renamed titles
        if workingVersion < 6 {
            let historyEntries = (root["recentHistory"] as? [[String: Any]]) ?? []
            let favoriteEntries = (root["favorites"] as? [[String: Any]]) ?? []
            let defaultTitlesLower: Set<String> = [
                "search", "wikipedia", "example domain", "hacker news"
            ]

            if var padsArray = root["pads"] as? [[String: Any]] {
                for idx in padsArray.indices {
                    if padsArray[idx]["pauseCustomModifications"] == nil {
                        padsArray[idx]["pauseCustomModifications"] = false
                    }
                    if padsArray[idx]["hasCustomTitle"] == nil {
                        let rawTitle = ((padsArray[idx]["title"] as? String) ?? "")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        let rawURLString = (padsArray[idx]["url"] as? String) ?? ""
                        let parsedURL = URL(string: rawURLString)
                        let hostLower = (parsedURL?.host ?? "").lowercased()
                        let bareHostLower = hostLower.hasPrefix("www.") ? String(hostLower.dropFirst(4)) : hostLower
                        let titleLower = rawTitle.lowercased()

                        let matchesHistoryTitle = historyEntries.contains { entry in
                            let hTitle = ((entry["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            let hURL = URL(string: (entry["url"] as? String) ?? "")
                            let hHost = (hURL?.host ?? "").lowercased()
                            return !hTitle.isEmpty && hTitle == titleLower && (hHost == hostLower || hURL == parsedURL)
                        }
                        let matchesFavoriteTitle = favoriteEntries.contains { entry in
                            let fTitle = ((entry["title"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                            return !fTitle.isEmpty && fTitle == titleLower
                        }
                        let isAutoTitle = rawTitle.isEmpty
                            || titleLower == rawURLString.lowercased()
                            || titleLower == hostLower
                            || titleLower == bareHostLower
                            || defaultTitlesLower.contains(titleLower)
                            || titleLower.hasSuffix(" options")
                            || matchesHistoryTitle
                            || matchesFavoriteTitle

                        padsArray[idx]["hasCustomTitle"] = !isAutoTitle
                    }
                }
                root["pads"] = padsArray
            }
            workingVersion = 6
        }

        root["schemaVersion"] = WorkspaceState.currentSchemaVersion
        let migrated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        return (migrated, originalVersion)
    }
}
