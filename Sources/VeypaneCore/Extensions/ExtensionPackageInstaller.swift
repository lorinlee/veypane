import Foundation

public enum ExtensionInstallError: Error, LocalizedError, Equatable, Sendable {
    case sourceNotFound(String)
    case invalidCRXMagic
    case unsupportedCRXVersion(UInt32)
    case truncatedCRXHeader
    case invalidZipPayload
    case unzipFailed(String)
    case manifestNotFound
    case invalidManifestJSON(String)
    case safariWebExtensionNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let path):
            return "Extension source not found at \(path)."
        case .invalidCRXMagic:
            return "File is not a valid Chrome extension (.crx) archive (missing Cr24 header)."
        case .unsupportedCRXVersion(let v):
            return "Unsupported CRX format version \(v) (only CRX2 and CRX3 are supported)."
        case .truncatedCRXHeader:
            return "CRX file header is truncated or corrupt."
        case .invalidZipPayload:
            return "Archive payload is not a valid ZIP archive."
        case .unzipFailed(let detail):
            return "Failed to unpack extension archive: \(detail)"
        case .manifestNotFound:
            return "No manifest.json found in the extension folder or archive."
        case .invalidManifestJSON(let detail):
            return "Invalid manifest.json: \(detail)"
        case .safariWebExtensionNotFound(let path):
            return "No Safari Web Extension (com.apple.Safari.web-extension with manifest.json) found in \(path)."
        }
    }
}

public struct DiscoveredSafariWebExtension: Equatable, Sendable {
    public var containingAppURL: URL?
    public var appExtensionURL: URL
    public var resourcesURL: URL
    public var appExtensionBundleID: String
    public var appDisplayName: String?
    public var appShortVersion: String?
    public var appBuildVersion: String?
    public var extensionShortVersion: String?
    public var extensionBuildVersion: String?
    public var manifest: ParsedExtensionManifest

    public init(
        containingAppURL: URL?,
        appExtensionURL: URL,
        resourcesURL: URL,
        appExtensionBundleID: String,
        appDisplayName: String?,
        appShortVersion: String?,
        appBuildVersion: String?,
        extensionShortVersion: String?,
        extensionBuildVersion: String?,
        manifest: ParsedExtensionManifest
    ) {
        self.containingAppURL = containingAppURL
        self.appExtensionURL = appExtensionURL
        self.resourcesURL = resourcesURL
        self.appExtensionBundleID = appExtensionBundleID
        self.appDisplayName = appDisplayName
        self.appShortVersion = appShortVersion
        self.appBuildVersion = appBuildVersion
        self.extensionShortVersion = extensionShortVersion
        self.extensionBuildVersion = extensionBuildVersion
        self.manifest = manifest
    }
}

public struct SafariExtensionUpdateCheckResult: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case notApplicable
        case upToDate
        case updated(
            previousVersion: String,
            newVersion: String,
            previousAppVersion: String?,
            newAppVersion: String?
        )
        case sourceMissing(path: String)
    }

    public var extensionID: String
    public var status: Status
    public var updatedRecord: InstalledExtension?

    public init(extensionID: String, status: Status, updatedRecord: InstalledExtension? = nil) {
        self.extensionID = extensionID
        self.status = status
        self.updatedRecord = updatedRecord
    }
}

public struct ParsedExtensionManifest: Equatable, Sendable {
    public var displayName: String
    public var version: String
    public var manifestVersion: Int
    public var permissions: [String]
    public var matchPatterns: [String]
    public var allURLsRequested: Bool
    public var explicitIDHint: String?

    public init(
        displayName: String,
        version: String,
        manifestVersion: Int,
        permissions: [String],
        matchPatterns: [String],
        allURLsRequested: Bool,
        explicitIDHint: String? = nil
    ) {
        self.displayName = displayName
        self.version = version
        self.manifestVersion = manifestVersion
        self.permissions = permissions
        self.matchPatterns = matchPatterns
        self.allURLsRequested = allURLsRequested
        self.explicitIDHint = explicitIDHint
    }
}

public enum ExtensionPackageInstaller {

    /// Strips a Chrome CRX2 or CRX3 header (`"Cr24"`) and returns the embedded ZIP archive bytes.
    /// - CRX2 layout: `"Cr24"` (4B) + `version=2` (u32 LE) + `pubKeyLen` (u32 LE) + `sigLen` (u32 LE) + pubKey + sig + ZIP
    /// - CRX3 layout: `"Cr24"` (4B) + `version=3` (u32 LE) + `headerLen` (u32 LE) + protobufHeader + ZIP
    public static func stripCRXHeader(_ data: Data) throws -> Data {
        guard data.count >= 12 else {
            throw ExtensionInstallError.truncatedCRXHeader
        }
        let magic = Array(data.prefix(4))
        guard magic == [0x43, 0x72, 0x32, 0x34] else { // "Cr24"
            throw ExtensionInstallError.invalidCRXMagic
        }

        let version = readUInt32LE(data, offset: 4)
        let zipOffset: Int

        switch version {
        case 2:
            guard data.count >= 16 else {
                throw ExtensionInstallError.truncatedCRXHeader
            }
            let pubKeyLen = UInt64(readUInt32LE(data, offset: 8))
            let sigLen = UInt64(readUInt32LE(data, offset: 12))
            let totalHeader = 16 + pubKeyLen + sigLen
            guard totalHeader <= UInt64(data.count) else {
                throw ExtensionInstallError.truncatedCRXHeader
            }
            zipOffset = Int(totalHeader)

        case 3:
            let headerLen = UInt64(readUInt32LE(data, offset: 8))
            let totalHeader = 12 + headerLen
            guard totalHeader <= UInt64(data.count) else {
                throw ExtensionInstallError.truncatedCRXHeader
            }
            zipOffset = Int(totalHeader)

        default:
            throw ExtensionInstallError.unsupportedCRXVersion(version)
        }

        let zipData = Data(data.dropFirst(zipOffset))
        guard zipData.count >= 4 else {
            throw ExtensionInstallError.invalidZipPayload
        }
        let zipMagic = Array(zipData.prefix(4))
        let isValidZip = (zipMagic == [0x50, 0x4B, 0x03, 0x04]) || (zipMagic == [0x50, 0x4B, 0x05, 0x06])
        guard isValidZip else {
            throw ExtensionInstallError.invalidZipPayload
        }
        return zipData
    }

    /// Unpacks a `.zip` archive into `destinationDirectory` using `/usr/bin/ditto -x -k`.
    public static func unpackZipArchive(at zipURL: URL, to destinationDirectory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipURL.path, destinationDirectory.path]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw ExtensionInstallError.unzipFailed(error.localizedDescription)
        }

        guard process.terminationStatus == 0 else {
            let errBytes = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(decoding: errBytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw ExtensionInstallError.unzipFailed(errStr.isEmpty ? "ditto exited with \(process.terminationStatus)" : errStr)
        }
    }

    /// Locates the directory containing `manifest.json`: either `rootDirectory` itself or one directory level nested inside it.
    public static func locateExtensionRoot(in rootDirectory: URL) throws -> URL {
        let fm = FileManager.default
        let directManifest = rootDirectory.appendingPathComponent("manifest.json", isDirectory: false)
        if fm.fileExists(atPath: directManifest.path) {
            return rootDirectory
        }

        let children = (try? fm.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let candidateDirs = children
            .filter { url in
                guard url.lastPathComponent != "__MACOSX" else { return false }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                return isDir
            }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        for subdir in candidateDirs {
            let nestedManifest = subdir.appendingPathComponent("manifest.json", isDirectory: false)
            if fm.fileExists(atPath: nestedManifest.path) {
                return subdir
            }
        }

        throw ExtensionInstallError.manifestNotFound
    }

    /// Reads `manifest.json` (and optional `_locales/.../messages.json` for `__MSG_...__` placeholders) without modifying any files.
    public static func inspectManifest(in extensionRoot: URL) throws -> ParsedExtensionManifest {
        let manifestURL = extensionRoot.appendingPathComponent("manifest.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw ExtensionInstallError.manifestNotFound
        }

        let rawData: Data
        do {
            rawData = try Data(contentsOf: manifestURL)
        } catch {
            throw ExtensionInstallError.invalidManifestJSON(error.localizedDescription)
        }

        let jsonObj: Any
        do {
            jsonObj = try JSONSerialization.jsonObject(with: rawData)
        } catch {
            throw ExtensionInstallError.invalidManifestJSON(error.localizedDescription)
        }

        guard let manifest = jsonObj as? [String: Any] else {
            throw ExtensionInstallError.invalidManifestJSON("Root must be a JSON object")
        }

        let defaultLocale = manifest["default_locale"] as? String
        let rawName = (manifest["name"] as? String) ?? (manifest["short_name"] as? String) ?? extensionRoot.lastPathComponent
        let resolvedName = resolveLocalizedManifestString(rawName, in: extensionRoot, defaultLocale: defaultLocale)
        let version = (manifest["version"] as? String) ?? "1.0"
        let mv = (manifest["manifest_version"] as? Int) ?? 3

        var permissions: Set<String> = []
        var matchPatterns: Set<String> = []

        // MV2 splits API permissions and match patterns together in "permissions"; MV3 adds "host_permissions"
        if let perms = manifest["permissions"] as? [String] {
            for item in perms {
                if looksLikeMatchPattern(item) {
                    matchPatterns.insert(item)
                } else {
                    permissions.insert(item)
                }
            }
        }
        if let hostPerms = manifest["host_permissions"] as? [String] {
            for item in hostPerms {
                matchPatterns.insert(item)
            }
        }
        if let contentScripts = manifest["content_scripts"] as? [[String: Any]] {
            for cs in contentScripts {
                if let matches = cs["matches"] as? [String] {
                    for pattern in matches {
                        matchPatterns.insert(pattern)
                    }
                }
            }
        }

        let allURLs = matchPatterns.contains("<all_urls>")
            || matchPatterns.contains("*://*/*")
            || matchPatterns.contains("http://*/*") && matchPatterns.contains("https://*/*")

        var explicitID: String?
        if let bss = manifest["browser_specific_settings"] as? [String: Any],
           let gecko = bss["gecko"] as? [String: Any],
           let geckoID = gecko["id"] as? String, !geckoID.isEmpty {
            explicitID = sanitizeIdentifier(geckoID)
        } else if let apps = manifest["applications"] as? [String: Any],
                  let gecko = apps["gecko"] as? [String: Any],
                  let geckoID = gecko["id"] as? String, !geckoID.isEmpty {
            explicitID = sanitizeIdentifier(geckoID)
        }

        return ParsedExtensionManifest(
            displayName: resolvedName,
            version: version,
            manifestVersion: mv,
            permissions: permissions.sorted(),
            matchPatterns: matchPatterns.sorted(),
            allURLsRequested: allURLs,
            explicitIDHint: explicitID
        )
    }

    public static let safariWebExtensionPointIdentifier = "com.apple.Safari.web-extension"

    /// Returns true if `url` points to a macOS `.app` or `.appex` bundle.
    public static func isSafariAppOrAppexSource(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "app" || ext == "appex"
    }

    /// Read-only inspection of a containing macOS `.app` bundle (or a direct `.appex` bundle) to discover
    /// embedded Safari Web Extensions (`NSExtensionPointIdentifier == "com.apple.Safari.web-extension"` with
    /// `Contents/Resources/manifest.json`). Never accesses Safari browser profiles, `~/Library/Safari`,
    /// permissions, or user credentials, and never copies or modifies any files inside the app bundle.
    public static func discoverSafariWebExtensions(in sourceURL: URL) throws -> [DiscoveredSafariWebExtension] {
        let fm = FileManager.default
        let standardized = sourceURL.standardizedFileURL
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: standardized.path, isDirectory: &isDir), isDir.boolValue else {
            throw ExtensionInstallError.sourceNotFound(standardized.path)
        }

        let ext = standardized.pathExtension.lowercased()
        let containingAppURL: URL?
        let candidateAppexURLs: [URL]

        if ext == "appex" {
            containingAppURL = inferContainingAppURL(forAppExtension: standardized)
            candidateAppexURLs = [standardized]
        } else if ext == "app" {
            containingAppURL = standardized
            let pluginsDir = standardized
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("PlugIns", isDirectory: true)
            let entries = (try? fm.contentsOfDirectory(
                at: pluginsDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            candidateAppexURLs = entries
                .filter { $0.pathExtension.lowercased() == "appex" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            throw ExtensionInstallError.safariWebExtensionNotFound(standardized.path)
        }

        let appInfo = containingAppURL.flatMap { readBundleInfoPlist(at: $0) }
        let appDisplayName = (appInfo?["CFBundleDisplayName"] as? String)
            ?? (appInfo?["CFBundleName"] as? String)
            ?? containingAppURL?.deletingPathExtension().lastPathComponent
        let appShortVersion = appInfo?["CFBundleShortVersionString"] as? String
        let appBuildVersion = appInfo?["CFBundleVersion"] as? String

        var discovered: [DiscoveredSafariWebExtension] = []
        for appexURL in candidateAppexURLs {
            guard let info = readBundleInfoPlist(at: appexURL),
                  let nsExtension = info["NSExtension"] as? [String: Any],
                  let pointID = nsExtension["NSExtensionPointIdentifier"] as? String,
                  pointID == safariWebExtensionPointIdentifier else {
                continue
            }

            let resourcesURL = appexURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
            guard let manifest = try? inspectManifest(in: resourcesURL) else {
                continue
            }

            let bundleID = (info["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedBundleID = (bundleID?.isEmpty == false)
                ? bundleID!
                : "safari-appex.\(sanitizeIdentifier(appexURL.deletingPathExtension().lastPathComponent))"

            discovered.append(
                DiscoveredSafariWebExtension(
                    containingAppURL: containingAppURL,
                    appExtensionURL: appexURL,
                    resourcesURL: resourcesURL,
                    appExtensionBundleID: resolvedBundleID,
                    appDisplayName: appDisplayName,
                    appShortVersion: appShortVersion,
                    appBuildVersion: appBuildVersion,
                    extensionShortVersion: info["CFBundleShortVersionString"] as? String,
                    extensionBuildVersion: info["CFBundleVersion"] as? String,
                    manifest: manifest
                )
            )
        }

        guard !discovered.isEmpty else {
            throw ExtensionInstallError.safariWebExtensionNotFound(standardized.path)
        }
        return discovered
    }

    /// Registers one or more Safari Web Extensions discovered inside a containing `.app` (or direct `.appex`)
    /// without copying third-party bundle resources into Veypane's store. Existing entries with the same
    /// `.appex` bundle identifier preserve their `id`, `contextUniqueIdentifier` (`chrome.storage`), enabled state,
    /// toolbar pin, and user permission choices.
    public static func registerSafariAppExtensions(
        from sourceURL: URL,
        existingExtensions: [InstalledExtension] = []
    ) throws -> [InstalledExtension] {
        let discoveredList = try discoverSafariWebExtensions(in: sourceURL)
        return discoveredList.map { discovered in
            buildSafariExtensionRecord(from: discovered, existingExtensions: existingExtensions)
        }
    }

    /// Inspects a linked `.safariAppExtension` record's containing `.app` / `.appex` on disk to detect version
    /// or path changes (for example after a Mac App Store update of the containing app). Preserves Veypane's
    /// `id`, `contextUniqueIdentifier`, and user permission overrides.
    public static func checkSafariExtensionForUpdate(_ record: InstalledExtension) -> SafariExtensionUpdateCheckResult {
        guard record.sourceKind == .safariAppExtension else {
            return SafariExtensionUpdateCheckResult(extensionID: record.id, status: .notApplicable)
        }

        let candidateSources: [URL] = [
            record.sourceAppPath.map { URL(fileURLWithPath: $0) },
            record.sourceAppExtensionPath.map { URL(fileURLWithPath: $0) }
        ].compactMap { $0 }

        var matched: DiscoveredSafariWebExtension?
        for source in candidateSources {
            guard let list = try? discoverSafariWebExtensions(in: source) else { continue }
            if let targetBundleID = record.sourceAppExtensionBundleID,
               let byID = list.first(where: { $0.appExtensionBundleID.caseInsensitiveCompare(targetBundleID) == .orderedSame }) {
                matched = byID
                break
            }
            if let targetPath = record.sourceAppExtensionPath,
               let byPath = list.first(where: { $0.appExtensionURL.standardizedFileURL.path == URL(fileURLWithPath: targetPath).standardizedFileURL.path }) {
                matched = byPath
                break
            }
            if list.count == 1 {
                matched = list[0]
                break
            }
        }

        guard let discovered = matched else {
            let missingPath = record.sourceAppPath ?? record.sourceAppExtensionPath ?? record.id
            return SafariExtensionUpdateCheckResult(
                extensionID: record.id,
                status: .sourceMissing(path: missingPath)
            )
        }

        let updated = buildSafariExtensionRecord(from: discovered, existingExtensions: [record])
        let versionChanged = (updated.version != record.version)
            || (updated.sourceAppVersion != record.sourceAppVersion)
            || (updated.sourceAppBuild != record.sourceAppBuild)
            || (updated.sourceAppExtensionPath != record.sourceAppExtensionPath)
            || (updated.displayName != record.displayName)
            || (Set(updated.grantedPermissions) != Set(record.grantedPermissions))
            || (Set(updated.grantedMatchPatterns) != Set(record.grantedMatchPatterns))

        if versionChanged {
            return SafariExtensionUpdateCheckResult(
                extensionID: record.id,
                status: .updated(
                    previousVersion: record.version,
                    newVersion: updated.version,
                    previousAppVersion: record.sourceAppVersion,
                    newAppVersion: updated.sourceAppVersion
                ),
                updatedRecord: updated
            )
        }
        return SafariExtensionUpdateCheckResult(extensionID: record.id, status: .upToDate)
    }

    private static func buildSafariExtensionRecord(
        from discovered: DiscoveredSafariWebExtension,
        existingExtensions: [InstalledExtension]
    ) -> InstalledExtension {
        let bundleSlug = sanitizeIdentifier(discovered.appExtensionBundleID)
        let deterministicID = bundleSlug.isEmpty ? "safari-ext-\(String(UUID().uuidString.lowercased().prefix(8)))" : "safari-\(bundleSlug)"

        let existingMatch = existingExtensions.first { item in
            if let existingBundleID = item.sourceAppExtensionBundleID,
               existingBundleID.caseInsensitiveCompare(discovered.appExtensionBundleID) == .orderedSame {
                return true
            }
            if let existingAppexPath = item.sourceAppExtensionPath,
               URL(fileURLWithPath: existingAppexPath).standardizedFileURL.path == discovered.appExtensionURL.standardizedFileURL.path {
                return true
            }
            return item.id == deterministicID
        }

        let extID = existingMatch?.id ?? deterministicID
        let contextUID = existingMatch?.contextUniqueIdentifier ?? UUID().uuidString.lowercased()
        let deniedPerms = Set(existingMatch?.deniedPermissions ?? [])
        let deniedPatterns = Set(existingMatch?.deniedMatchPatterns ?? [])

        var mergedGrantedPerms = Set(existingMatch?.grantedPermissions ?? [])
        for perm in discovered.manifest.permissions where !deniedPerms.contains(perm) {
            mergedGrantedPerms.insert(perm)
        }

        var mergedGrantedPatterns = Set(existingMatch?.grantedMatchPatterns ?? [])
        for pat in discovered.manifest.matchPatterns where !deniedPatterns.contains(pat) {
            mergedGrantedPatterns.insert(pat)
        }

        return InstalledExtension(
            id: extID,
            folderName: "",
            displayName: discovered.manifest.displayName,
            version: discovered.manifest.version,
            enabled: existingMatch?.enabled ?? true,
            grantedPermissions: mergedGrantedPerms.sorted(),
            deniedPermissions: existingMatch?.deniedPermissions ?? [],
            grantedMatchPatterns: mergedGrantedPatterns.sorted(),
            deniedMatchPatterns: existingMatch?.deniedMatchPatterns ?? [],
            allURLsGranted: existingMatch?.allURLsGranted ?? true,
            websiteAccessMode: existingMatch?.websiteAccessMode ?? .allWebsites,
            contextUniqueIdentifier: contextUID,
            pinnedToToolbar: existingMatch?.pinnedToToolbar ?? true,
            hasBootstrappedPermissions: existingMatch?.hasBootstrappedPermissions ?? false,
            installedAt: existingMatch?.installedAt ?? Date(),
            sourceKind: .safariAppExtension,
            sourceAppPath: discovered.containingAppURL?.standardizedFileURL.path,
            sourceAppExtensionPath: discovered.appExtensionURL.standardizedFileURL.path,
            sourceAppExtensionBundleID: discovered.appExtensionBundleID,
            sourceAppVersion: discovered.appShortVersion ?? discovered.extensionShortVersion,
            sourceAppBuild: discovered.appBuildVersion ?? discovered.extensionBuildVersion
        )
    }

    private static func readBundleInfoPlist(at bundleURL: URL) -> [String: Any]? {
        let plistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: plistURL),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = raw as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func inferContainingAppURL(forAppExtension appexURL: URL) -> URL? {
        let pluginsDir = appexURL.deletingLastPathComponent()
        guard pluginsDir.lastPathComponent == "PlugIns" else { return nil }
        let contentsDir = pluginsDir.deletingLastPathComponent()
        guard contentsDir.lastPathComponent == "Contents" else { return nil }
        let appDir = contentsDir.deletingLastPathComponent()
        guard appDir.pathExtension.lowercased() == "app" else { return nil }
        return appDir
    }

    /// Installs an extension from an unpacked folder, `.zip`, `.crx`, or Safari containing `.app`/`.appex`.
    /// Copied packages are stored under `<extensionsRootDirectory>/<extID>/`; Safari `.app`/`.appex` bundles are
    /// linked in-place without copying third-party resources.
    public static func installExtensionPackage(
        from sourceURL: URL,
        extensionsRootDirectory: URL,
        existingExtensions: [InstalledExtension] = []
    ) throws -> InstalledExtension {
        if isSafariAppOrAppexSource(sourceURL) {
            let registered = try registerSafariAppExtensions(
                from: sourceURL,
                existingExtensions: existingExtensions
            )
            guard let first = registered.first else {
                throw ExtensionInstallError.safariWebExtensionNotFound(sourceURL.path)
            }
            return first
        }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw ExtensionInstallError.sourceNotFound(sourceURL.path)
        }

        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("VeypaneExtStage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let resolvedSourceFolder: URL
        if isDir.boolValue {
            resolvedSourceFolder = try locateExtensionRoot(in: sourceURL)
        } else {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
            let extLower = sourceURL.pathExtension.lowercased()
            let unpackDir = stagingRoot.appendingPathComponent("unpacked", isDirectory: true)

            if extLower == "crx" {
                let rawCRX = try Data(contentsOf: sourceURL)
                let zipData = try stripCRXHeader(rawCRX)
                let tempZip = stagingRoot.appendingPathComponent("stripped.zip", isDirectory: false)
                try zipData.write(to: tempZip, options: .atomic)
                try unpackZipArchive(at: tempZip, to: unpackDir)
            } else {
                // Treat .zip (or archive file) via ditto -x -k; if it happens to have a Cr24 header, handle gracefully too
                let head = (try? FileHandle(forReadingFrom: sourceURL))?.readData(ofLength: 4)
                if let head, Array(head) == [0x43, 0x72, 0x32, 0x34] {
                    let rawCRX = try Data(contentsOf: sourceURL)
                    let zipData = try stripCRXHeader(rawCRX)
                    let tempZip = stagingRoot.appendingPathComponent("stripped.zip", isDirectory: false)
                    try zipData.write(to: tempZip, options: .atomic)
                    try unpackZipArchive(at: tempZip, to: unpackDir)
                } else {
                    try unpackZipArchive(at: sourceURL, to: unpackDir)
                }
            }
            resolvedSourceFolder = try locateExtensionRoot(in: unpackDir)
        }

        let parsed = try inspectManifest(in: resolvedSourceFolder)

        // Reuse existing ID + contextUniqueIdentifier if updating an extension with the exact same display name or explicit ID
        let existingMatch = existingExtensions.first { item in
            if let hint = parsed.explicitIDHint, item.id == hint { return true }
            return item.displayName.caseInsensitiveCompare(parsed.displayName) == .orderedSame
        }

        let extID: String
        let contextUID: String
        if let existingMatch {
            extID = existingMatch.id
            contextUID = existingMatch.contextUniqueIdentifier
        } else {
            let baseSlug = parsed.explicitIDHint ?? sanitizeIdentifier(parsed.displayName)
            let suffix = String(UUID().uuidString.lowercased().prefix(8))
            let candidate = baseSlug.isEmpty ? "ext-\(suffix)" : "\(baseSlug)-\(suffix)"
            extID = candidate
            contextUID = UUID().uuidString.lowercased()
        }

        try fm.createDirectory(at: extensionsRootDirectory, withIntermediateDirectories: true)
        let destinationFolder = extensionsRootDirectory.appendingPathComponent(extID, isDirectory: true)

        // Copy into a temporary sibling first so replacing an existing folder is atomic and leaves extension files untouched
        let tempCopy = extensionsRootDirectory.appendingPathComponent(".\(extID).installing-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempCopy) }
        try fm.copyItem(at: resolvedSourceFolder, to: tempCopy)

        if fm.fileExists(atPath: destinationFolder.path) {
            try fm.removeItem(at: destinationFolder)
        }
        try fm.moveItem(at: tempCopy, to: destinationFolder)

        return InstalledExtension(
            id: extID,
            folderName: extID,
            displayName: parsed.displayName,
            version: parsed.version,
            enabled: existingMatch?.enabled ?? true,
            grantedPermissions: parsed.permissions,
            deniedPermissions: existingMatch?.deniedPermissions ?? [],
            grantedMatchPatterns: parsed.matchPatterns,
            deniedMatchPatterns: existingMatch?.deniedMatchPatterns ?? [],
            allURLsGranted: true,
            websiteAccessMode: existingMatch?.websiteAccessMode ?? .allWebsites,
            contextUniqueIdentifier: contextUID,
            pinnedToToolbar: existingMatch?.pinnedToToolbar ?? true,
            hasBootstrappedPermissions: false,
            installedAt: existingMatch?.installedAt ?? Date()
        )
    }

    // MARK: - Helpers

    private static func readUInt32LE(_ data: Data, offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1]) << 8
        let b2 = UInt32(data[data.startIndex + offset + 2]) << 16
        let b3 = UInt32(data[data.startIndex + offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }

    private static func looksLikeMatchPattern(_ value: String) -> Bool {
        value == "<all_urls>" || value.contains("://")
    }

    public static func sanitizeIdentifier(_ raw: String) -> String {
        let lower = raw.lowercased()
        var scalars: [Character] = []
        var lastWasDash = false
        for ch in lower {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                scalars.append(ch)
                lastWasDash = false
            } else if !lastWasDash && !scalars.isEmpty {
                scalars.append("-")
                lastWasDash = true
            }
        }
        while scalars.last == "-" {
            scalars.removeLast()
        }
        return String(scalars.prefix(32))
    }

    private static func resolveLocalizedManifestString(
        _ value: String,
        in extensionRoot: URL,
        defaultLocale: String?
    ) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("__MSG_"), trimmed.hasSuffix("__"), trimmed.count > 8 else {
            return value
        }
        let messageKey = String(trimmed.dropFirst(6).dropLast(2))
        let localesDir = extensionRoot.appendingPathComponent("_locales", isDirectory: true)
        let preferredLang = L10n.currentLanguageCode == "zh-Hans"
            ? ["zh_CN", "zh-CN", "zh", defaultLocale ?? "en", "en"]
            : ["en", "en_US", defaultLocale ?? "en"]

        for loc in preferredLang {
            let msgFile = localesDir
                .appendingPathComponent(loc, isDirectory: true)
                .appendingPathComponent("messages.json", isDirectory: false)
            guard let data = try? Data(contentsOf: msgFile),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }
            if let entry = dict[messageKey] as? [String: Any],
               let msg = entry["message"] as? String, !msg.isEmpty {
                return msg
            }
            // Case-insensitive message key fallback per WebExtensions spec
            if let match = dict.first(where: { $0.key.caseInsensitiveCompare(messageKey) == .orderedSame }),
               let entry = match.value as? [String: Any],
               let msg = entry["message"] as? String, !msg.isEmpty {
                return msg
            }
        }
        return value
    }
}
