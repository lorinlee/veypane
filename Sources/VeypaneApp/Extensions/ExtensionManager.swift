import AppKit
import Foundation
import Observation
import WebKit
import VeypaneCore

public struct ExtensionToolbarItem: Identifiable {
    public let id: String
    public let title: String
    public let tooltip: String
    public let icon: NSImage?
    public let badgeText: String
    public let isPinned: Bool
}

public enum ExtensionLoadMode: String, Codable, Equatable, Sendable {
    case copiedPackage
    case appExtensionBundle
}

public struct ExtensionSettingsItem: Identifiable {
    public let id: String
    public let displayName: String
    public let version: String
    public let icon: NSImage?
    public let enabled: Bool
    public let isLoaded: Bool
    public let pinnedToToolbar: Bool
    public let hasOptionsPage: Bool
    public let websiteAccessMode: ExtensionWebsiteAccessMode
    public let grantedMatchPatterns: [String]
    public let allPermissions: [String]
    public let grantedPermissions: Set<String>
    public let errors: [String]
    public let sourceKind: InstalledExtensionSourceKind
    public let sourceAppDisplayName: String?
    public let sourceAppVersion: String?
    public let loadMode: ExtensionLoadMode?
}

private final class WeakNSViewBox {
    weak var view: NSView?
    init(_ view: NSView?) { self.view = view }
}

/// Shared manager for WebKit browser extensions (`WKWebExtensionController`).
/// Compiles cleanly on macOS 14+ and activates full extension support on macOS 15.4+.
@MainActor
@Observable
public final class ExtensionManager {
    public static let shared = ExtensionManager()

    /// Incremented whenever loaded extensions, action icons/badges, or errors change so SwiftUI refreshes.
    public var uiRevision: Int = 0

    /// Suppresses interactive modal NSAlert prompts during automated snapshot rendering.
    public var allowInteractivePrompts: Bool = true

    @ObservationIgnored
    private weak var appModel: AppModel?

    @ObservationIgnored
    private var runtimeBox: AnyObject?

    @ObservationIgnored
    private var toolbarAnchorViews: [String: WeakNSViewBox] = [:]

    @ObservationIgnored
    private weak var overflowAnchorView: NSView?

    public init() {}

    public var isSupported: Bool {
        if #available(macOS 15.4, *) {
            return true
        }
        return false
    }

    public var isAnyPopupVisible: Bool {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            return runtime.isAnyPopupShown
        }
        return false
    }

    @available(macOS 15.4, *)
    private var runtimeCoordinator: ExtensionRuntimeCoordinator? {
        runtimeBox as? ExtensionRuntimeCoordinator
    }

    public func bind(to model: AppModel, allowInteractivePrompts: Bool = true) {
        self.appModel = model
        self.allowInteractivePrompts = allowInteractivePrompts

        if #available(macOS 15.4, *) {
            let controllerID = model.state.webExtensionControllerID
            if let existing = runtimeCoordinator, existing.controllerIdentifier == controllerID {
                existing.appModel = model
                existing.owner = self
            } else {
                if let old = runtimeCoordinator {
                    old.shutdownAllContexts()
                }
                let created = ExtensionRuntimeCoordinator(
                    controllerIdentifier: controllerID,
                    owner: self,
                    appModel: model
                )
                self.runtimeBox = created
            }
        }
        bumpRevision()
    }

    public func loadEnabledExtensionsAtStartup() async {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            await runtime.reconcileWithStoreState()
            bumpRevision()
        }
    }

    public func reconcileWithStoreState() async {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            await runtime.reconcileWithStoreState()
            bumpRevision()
        }
    }

    // MARK: - WebView Configuration Attachment

    public func prepareWebViewConfiguration(
        baseConfiguration: WKWebViewConfiguration,
        initialURL: URL
    ) -> WKWebViewConfiguration {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            return runtime.prepareWebViewConfiguration(
                baseConfiguration: baseConfiguration,
                initialURL: initialURL
            )
        }
        return baseConfiguration
    }

    public func attachController(to configuration: WKWebViewConfiguration) {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            configuration.webExtensionController = runtime.controller
        }
    }

    public func isExtensionInternalURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "webkit-extension"
    }

    // MARK: - Tab & Window Notifications

    public func syncTabsWithWorkspace(previousSelectedPadID: UUID? = nil) {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.syncTabsWithWorkspace(previousSelectedPadID: previousSelectedPadID)
            bumpRevision()
        }
    }

    public func notifyTabMoved(padID: UUID, from oldIndex: Int) {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.notifyTabMoved(padID: padID, from: oldIndex)
        }
    }

    public func notifyTabPropertiesChanged(
        padID: UUID,
        loading: Bool = false,
        title: Bool = false,
        url: Bool = false,
        muted: Bool = false,
        zoom: Bool = false,
        size: Bool = false
    ) {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.notifyTabPropertiesChanged(
                padID: padID,
                loading: loading,
                title: title,
                url: url,
                muted: muted,
                zoom: zoom,
                size: size
            )
            if title || url || !loading {
                bumpRevision()
            }
        }
    }

    public func notifyWindowFocused() {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.notifyWindowFocused()
        }
    }

    // MARK: - Keyboard Commands & Context Menu

    public func handleKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = EdgeMonitorController.activeModifiers(from: flags)
        if StandardEditCommand.match(
            modifiers: mods,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode
        ) != nil {
            return false
        }
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            return runtime.handleKeyEvent(event)
        }
        return false
    }

    public func contextMenuItems(for padID: UUID) -> [NSMenuItem] {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            return runtime.contextMenuItems(for: padID)
        }
        return []
    }

    // MARK: - Toolbar Anchor Registration & Actions

    public func registerToolbarAnchorView(_ view: NSView?, for extensionID: String) {
        if let view {
            toolbarAnchorViews[extensionID] = WeakNSViewBox(view)
        } else {
            toolbarAnchorViews.removeValue(forKey: extensionID)
        }
    }

    public func registerOverflowAnchorView(_ view: NSView?) {
        overflowAnchorView = view
    }

    fileprivate func bestAnchorView(for extensionID: String) -> NSView? {
        if let buttonView = toolbarAnchorViews[extensionID]?.view, buttonView.window != nil {
            return buttonView
        }
        if let overflow = overflowAnchorView, overflow.window != nil {
            return overflow
        }
        return appModel?.panelContentRootView
    }

    public func toolbarItems(for padID: UUID?) -> [ExtensionToolbarItem] {
        _ = uiRevision
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            return runtime.toolbarItems(for: padID)
        }
        return []
    }

    public func settingsItems() -> [ExtensionSettingsItem] {
        _ = uiRevision
        guard let model = appModel else { return [] }
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            return runtime.settingsItems(installed: model.state.installedExtensions)
        }
        return model.state.installedExtensions.map { ext in
            ExtensionSettingsItem(
                id: ext.id,
                displayName: ext.displayName,
                version: ext.version,
                icon: nil,
                enabled: ext.enabled,
                isLoaded: false,
                pinnedToToolbar: ext.pinnedToToolbar,
                hasOptionsPage: false,
                websiteAccessMode: ext.websiteAccessMode,
                grantedMatchPatterns: ext.grantedMatchPatterns,
                allPermissions: ext.grantedPermissions,
                grantedPermissions: Set(ext.grantedPermissions),
                errors: [],
                sourceKind: ext.sourceKind,
                sourceAppDisplayName: ext.sourceAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent },
                sourceAppVersion: ext.sourceAppVersion,
                loadMode: nil
            )
        }
    }

    public func performToolbarAction(for extensionID: String) {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.performToolbarAction(for: extensionID)
            bumpRevision()
        }
    }

    // MARK: - Install / Enable / Permissions / Remove

    @discardableResult
    public func installExtension(from sourceURL: URL) async throws -> InstalledExtension {
        if ExtensionPackageInstaller.isSafariAppOrAppexSource(sourceURL) {
            let registered = try await installSafariAppExtensions(from: sourceURL)
            guard let first = registered.first else {
                throw ExtensionInstallError.safariWebExtensionNotFound(sourceURL.path)
            }
            return first
        }

        guard let model = appModel else {
            throw ExtensionInstallError.manifestNotFound
        }
        let installed = try ExtensionPackageInstaller.installExtensionPackage(
            from: sourceURL,
            extensionsRootDirectory: model.store.extensionsDirectoryURL,
            existingExtensions: model.state.installedExtensions
        )
        if let idx = model.state.installedExtensions.firstIndex(where: { $0.id == installed.id }) {
            model.state.installedExtensions[idx] = installed
        } else {
            model.state.installedExtensions.append(installed)
        }
        model.persist()

        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            await runtime.reloadExtension(id: installed.id)
        }
        bumpRevision()
        return model.state.installedExtensions.first(where: { $0.id == installed.id }) ?? installed
    }

    /// Selects a containing macOS `.app` bundle (or `.appex` directly) once, discovers all embedded
    /// `com.apple.Safari.web-extension` bundles read-only in place (without copying third-party resources
    /// or touching Safari's profile/permissions/storage), registers them under Veypane's own isolated
    /// `WKWebExtensionController`, and loads them via `WKWebExtension(appExtensionBundle:)`.
    @discardableResult
    public func installSafariAppExtensions(from appOrAppexURL: URL) async throws -> [InstalledExtension] {
        guard let model = appModel else {
            throw ExtensionInstallError.manifestNotFound
        }
        let registered = try ExtensionPackageInstaller.registerSafariAppExtensions(
            from: appOrAppexURL,
            existingExtensions: model.state.installedExtensions
        )
        for ext in registered {
            if let idx = model.state.installedExtensions.firstIndex(where: { $0.id == ext.id }) {
                model.state.installedExtensions[idx] = ext
            } else {
                model.state.installedExtensions.append(ext)
            }
        }
        model.persist()

        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            for ext in registered {
                await runtime.reloadExtension(id: ext.id)
            }
        }
        bumpRevision()
        return registered.map { item in
            model.state.installedExtensions.first(where: { $0.id == item.id }) ?? item
        }
    }

    /// Checks linked Safari containing `.app` bundles for version/build/path updates and reloads changed
    /// extensions in-place while preserving `id`, `contextUniqueIdentifier` (`chrome.storage`), and user permissions.
    @discardableResult
    public func checkAndReloadSafariExtensionUpdates(extensionID: String? = nil) async -> [SafariExtensionUpdateCheckResult] {
        guard let model = appModel else { return [] }
        let targets = model.state.installedExtensions.filter { ext in
            ext.sourceKind == .safariAppExtension && (extensionID == nil || ext.id == extensionID)
        }
        guard !targets.isEmpty else { return [] }

        var results: [SafariExtensionUpdateCheckResult] = []
        var updatedIDs: [String] = []
        var missingByID: [String: String] = [:]
        var didMutateStore = false

        for record in targets {
            let check = ExtensionPackageInstaller.checkSafariExtensionForUpdate(record)
            results.append(check)
            switch check.status {
            case .updated:
                if let updatedRecord = check.updatedRecord,
                   let idx = model.state.installedExtensions.firstIndex(where: { $0.id == record.id }) {
                    model.state.installedExtensions[idx] = updatedRecord
                    didMutateStore = true
                    updatedIDs.append(record.id)
                }
            case .sourceMissing(let path):
                missingByID[record.id] = path
            case .upToDate, .notApplicable:
                break
            }
        }

        if didMutateStore {
            model.persist()
        }

        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            for extID in updatedIDs {
                await runtime.reloadExtension(id: extID)
            }
            for (extID, missingPath) in missingByID {
                runtime.markSourceAppMissing(for: extID, path: missingPath)
            }
        }
        bumpRevision()
        return results
    }

    public func loadedMode(for extensionID: String) -> ExtensionLoadMode? {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            return runtime.loadedMode(for: extensionID)
        }
        return nil
    }

    public func setExtensionEnabled(id: String, enabled: Bool) async {
        guard let model = appModel,
              let idx = model.state.installedExtensions.firstIndex(where: { $0.id == id }) else {
            return
        }
        model.state.installedExtensions[idx].enabled = enabled
        model.persist()

        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            await runtime.reconcileWithStoreState()
        }
        bumpRevision()
    }

    public func setExtensionPinned(id: String, pinned: Bool) {
        guard let model = appModel,
              let idx = model.state.installedExtensions.firstIndex(where: { $0.id == id }) else {
            return
        }
        model.state.installedExtensions[idx].pinnedToToolbar = pinned
        model.persist()
        bumpRevision()
    }

    public func setWebsiteAccessMode(id: String, mode: ExtensionWebsiteAccessMode) {
        guard let model = appModel,
              let idx = model.state.installedExtensions.firstIndex(where: { $0.id == id }) else {
            return
        }
        model.state.installedExtensions[idx].websiteAccessMode = mode
        model.state.installedExtensions[idx].allURLsGranted = (mode == .allWebsites)
        model.persist()

        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.applyPermissions(for: id)
        }
        bumpRevision()
    }

    public func addSpecificSitePattern(id: String, pattern: String) {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let model = appModel,
              let idx = model.state.installedExtensions.firstIndex(where: { $0.id == id }) else {
            return
        }
        if !model.state.installedExtensions[idx].grantedMatchPatterns.contains(trimmed) {
            model.state.installedExtensions[idx].grantedMatchPatterns.append(trimmed)
            model.state.installedExtensions[idx].grantedMatchPatterns.sort()
        }
        model.state.installedExtensions[idx].deniedMatchPatterns.removeAll { $0 == trimmed }
        model.persist()

        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.applyPermissions(for: id)
        }
        bumpRevision()
    }

    public func removeSpecificSitePattern(id: String, pattern: String) {
        guard let model = appModel,
              let idx = model.state.installedExtensions.firstIndex(where: { $0.id == id }) else {
            return
        }
        model.state.installedExtensions[idx].grantedMatchPatterns.removeAll { $0 == pattern }
        if !model.state.installedExtensions[idx].deniedMatchPatterns.contains(pattern) {
            model.state.installedExtensions[idx].deniedMatchPatterns.append(pattern)
        }
        model.persist()

        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.applyPermissions(for: id)
        }
        bumpRevision()
    }

    public func setPermissionGranted(id: String, permission: String, granted: Bool) {
        guard let model = appModel,
              let idx = model.state.installedExtensions.firstIndex(where: { $0.id == id }) else {
            return
        }
        if granted {
            if !model.state.installedExtensions[idx].grantedPermissions.contains(permission) {
                model.state.installedExtensions[idx].grantedPermissions.append(permission)
                model.state.installedExtensions[idx].grantedPermissions.sort()
            }
            model.state.installedExtensions[idx].deniedPermissions.removeAll { $0 == permission }
        } else {
            model.state.installedExtensions[idx].grantedPermissions.removeAll { $0 == permission }
            if !model.state.installedExtensions[idx].deniedPermissions.contains(permission) {
                model.state.installedExtensions[idx].deniedPermissions.append(permission)
            }
        }
        model.persist()

        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.applyPermissions(for: id)
        }
        bumpRevision()
    }

    public func openOptionsPage(id: String) {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            runtime.openOptionsPage(id: id)
        }
    }

    public func removeExtension(id: String) async {
        guard let model = appModel,
              let idx = model.state.installedExtensions.firstIndex(where: { $0.id == id }) else {
            return
        }
        let removed = model.state.installedExtensions.remove(at: idx)
        model.persist()

        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            await runtime.unloadAndClearData(for: removed.id)
        }

        // Only delete Veypane's own copied package folder — NEVER delete a linked Safari containing `.app`/`.appex`!
        if removed.sourceKind == .copiedPackage, !removed.folderName.isEmpty {
            let folderURL = model.store.extensionsDirectoryURL.appendingPathComponent(removed.folderName, isDirectory: true)
            try? FileManager.default.removeItem(at: folderURL)
        }
        bumpRevision()
    }

    // MARK: - Automation & MCP Bridge

    public func listAutomationSummaries() -> [AutomationExtensionSummary] {
        guard let model = appModel else { return [] }
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            return runtime.listAutomationSummaries(installed: model.state.installedExtensions)
        }
        return model.state.installedExtensions.map { ext in
            AutomationExtensionSummary(
                id: ext.id,
                name: ext.displayName,
                version: ext.version,
                enabled: ext.enabled,
                loaded: false,
                errors: ["Requires macOS 15.4 or later"],
                commands: []
            )
        }
    }

    public func performAutomationCommand(
        extensionQuery: String,
        commandID: String,
        padQuery: String?
    ) throws -> AutomationExtensionCommandResult {
        if #available(macOS 15.4, *), let runtime = runtimeCoordinator {
            return try runtime.performAutomationCommand(
                extensionQuery: extensionQuery,
                commandID: commandID,
                padQuery: padQuery
            )
        }
        throw AutomationBridgeError.extensionNotFound(extensionQuery)
    }

    fileprivate func bumpRevision() {
        uiRevision &+= 1
    }
}

// MARK: - macOS 15.4+ WKWebExtension Implementation

@available(macOS 15.4, *)
@MainActor
final class VeypaneExtensionTab: NSObject, WKWebExtensionTab {
    let padID: UUID
    weak var runtime: ExtensionRuntimeCoordinator?

    /// Optional override web view used by isolated snapshot runs.
    weak var overrideWebView: WKWebView?

    init(padID: UUID, runtime: ExtensionRuntimeCoordinator) {
        self.padID = padID
        self.runtime = runtime
        super.init()
    }

    private var pad: Pad? {
        runtime?.appModel?.state.pads.first(where: { $0.id == padID })
    }

    private var resolvedWebView: WKWebView? {
        if let overrideWebView {
            return overrideWebView
        }
        return runtime?.appModel?.existingWebView(for: padID)
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        runtime?.extensionWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tabs = runtime?.orderedOpenTabs else { return NSNotFound }
        return tabs.firstIndex(where: { $0.padID == padID }) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        resolvedWebView
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        resolvedWebView?.url ?? pad?.url
    }

    func title(for context: WKWebExtensionContext) -> String? {
        if let liveTitle = resolvedWebView?.title, !liveTitle.isEmpty {
            return liveTitle
        }
        return pad?.title
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        runtime?.appModel?.state.selectedPadID == padID
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard let wv = resolvedWebView else { return true }
        return !wv.isLoading
    }

    func isMuted(for context: WKWebExtensionContext) -> Bool {
        pad?.isMuted ?? false
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let current = pad, current.isMuted != muted {
            runtime?.appModel?.toggleMute(padID: padID)
        }
        completionHandler(nil)
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        if let wv = resolvedWebView, wv.bounds.width > 1, wv.bounds.height > 1 {
            return wv.bounds.size
        }
        return CGSize(width: 1020, height: 700)
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        resolvedWebView.map { Double($0.pageZoom) } ?? pad?.pageZoom ?? 1.0
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        resolvedWebView?.pageZoom = zoomFactor
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtime?.appModel?.navigatePad(id: padID, to: url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let wv = resolvedWebView {
            if fromOrigin {
                wv.reloadFromOrigin()
            } else {
                wv.reload()
            }
        } else {
            runtime?.appModel?.wakePad(id: padID)
        }
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        resolvedWebView?.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        resolvedWebView?.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtime?.appModel?.selectPad(id: padID)
        completionHandler(nil)
    }

    func setSelected(_ selected: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if selected {
            runtime?.appModel?.selectPad(id: padID)
        }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtime?.appModel?.removePad(id: padID)
        completionHandler(nil)
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }
}

@available(macOS 15.4, *)
@MainActor
final class VeypaneExtensionWindow: NSObject, WKWebExtensionWindow {
    weak var runtime: ExtensionRuntimeCoordinator?

    init(runtime: ExtensionRuntimeCoordinator) {
        self.runtime = runtime
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        runtime?.orderedOpenTabs ?? []
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        runtime?.activeExtensionTab
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func frame(for context: WKWebExtensionContext) -> CGRect {
        if let panelFrame = runtime?.appModel?.currentPanelFrame, panelFrame.width > 1 {
            return panelFrame
        }
        return CGRect(x: 0, y: 0, width: 1200, height: 820)
    }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect {
        NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtime?.appModel?.showPanel()
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        runtime?.appModel?.hidePanel()
        completionHandler(nil)
    }
}

@available(macOS 15.4, *)
@MainActor
final class ExtensionRuntimeCoordinator: NSObject, WKWebExtensionControllerDelegate {
    private struct LoadedRecord {
        let id: String
        let webExtension: WKWebExtension
        let context: WKWebExtensionContext
        let loadMode: ExtensionLoadMode
    }

    let controllerIdentifier: UUID
    let controller: WKWebExtensionController
    weak var owner: ExtensionManager?
    weak var appModel: AppModel?

    private(set) lazy var extensionWindow = VeypaneExtensionWindow(runtime: self)
    private var loadedByID: [String: LoadedRecord] = [:]
    private var loadErrorsByID: [String: String] = [:]
    private var loadNoticesByID: [String: String] = [:]
    private var tabsByPadID: [UUID: VeypaneExtensionTab] = [:]
    private var lastActivePadID: UUID?
    private var fallbackPopover: NSPopover?
    private var actionObserver: NSObjectProtocol?

    init(controllerIdentifier: UUID, owner: ExtensionManager, appModel: AppModel) {
        self.controllerIdentifier = controllerIdentifier
        let config = WKWebExtensionController.Configuration(identifier: controllerIdentifier)
        self.controller = WKWebExtensionController(configuration: config)
        self.owner = owner
        self.appModel = appModel
        super.init()

        self.controller.delegate = self
        self.controller.didOpenWindow(extensionWindow)
        self.controller.didFocusWindow(extensionWindow)

        self.actionObserver = NotificationCenter.default.addObserver(
            forName: WKWebExtensionContext.errorsDidUpdateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.owner?.bumpRevision()
            }
        }
    }

    var orderedOpenTabs: [VeypaneExtensionTab] {
        guard let model = appModel else { return [] }
        return model.state.pads
            .filter { !$0.isHibernated }
            .compactMap { tabsByPadID[$0.id] }
    }

    var activeExtensionTab: VeypaneExtensionTab? {
        if let selectedID = appModel?.state.selectedPadID,
           let tab = tabsByPadID[selectedID] {
            return tab
        }
        return orderedOpenTabs.first
    }

    var isAnyPopupShown: Bool {
        if fallbackPopover?.isShown == true {
            return true
        }
        for entry in loadedByID.values {
            if let action = entry.context.action(for: activeExtensionTab),
               action.popupPopover?.isShown == true {
                return true
            }
            if let defaultAction = entry.context.action(for: nil),
               defaultAction.popupPopover?.isShown == true {
                return true
            }
        }
        return false
    }

    func shutdownAllContexts() {
        if let obs = actionObserver {
            NotificationCenter.default.removeObserver(obs)
            actionObserver = nil
        }
        for entry in loadedByID.values {
            try? controller.unload(entry.context)
        }
        loadedByID.removeAll()
        tabsByPadID.removeAll()
    }

    // MARK: - Loading & Reconciling Extensions

    func loadedMode(for extensionID: String) -> ExtensionLoadMode? {
        loadedByID[extensionID]?.loadMode
    }

    func markSourceAppMissing(for extensionID: String, path: String) {
        if let existing = loadedByID.removeValue(forKey: extensionID) {
            try? controller.unload(existing.context)
        }
        loadNoticesByID.removeValue(forKey: extensionID)
        loadErrorsByID[extensionID] = "Linked Safari extension app not found at \(path)."
    }

    func reconcileWithStoreState() async {
        guard let model = appModel else { return }

        // 0. Check linked Safari containing `.app` bundles for version/path updates before loading
        var didUpdateSafariMetadata = false
        var safariUpdatedIDs = Set<String>()
        for idx in model.state.installedExtensions.indices {
            let record = model.state.installedExtensions[idx]
            guard record.sourceKind == .safariAppExtension else { continue }
            let check = ExtensionPackageInstaller.checkSafariExtensionForUpdate(record)
            switch check.status {
            case .updated:
                if let updatedRecord = check.updatedRecord {
                    model.state.installedExtensions[idx] = updatedRecord
                    didUpdateSafariMetadata = true
                    safariUpdatedIDs.insert(record.id)
                }
            case .sourceMissing(let path):
                markSourceAppMissing(for: record.id, path: path)
            case .upToDate, .notApplicable:
                break
            }
        }
        if didUpdateSafariMetadata {
            model.persist()
        }

        let installed = model.state.installedExtensions
        let installedByID = Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0) })

        // 1. Unload extensions that were disabled, removed, or updated in-place from their Safari app
        for (extID, loaded) in Array(loadedByID) {
            if let record = installedByID[extID] {
                if !record.enabled || safariUpdatedIDs.contains(extID) {
                    try? controller.unload(loaded.context)
                    loadedByID.removeValue(forKey: extID)
                }
            } else {
                await unloadAndClearData(for: extID)
            }
        }

        // 2. Ensure tabs are registered before background scripts inspect open tabs
        syncTabsWithWorkspace()

        // 3. Load enabled extensions that are not yet loaded
        for record in installed where record.enabled {
            if loadedByID[record.id] == nil {
                await loadSingleExtension(record: record)
            } else {
                applyPermissions(for: record.id)
            }
        }

        // 4. Re-broadcast active tab + focus so newly loaded background workers see current state
        if let active = activeExtensionTab {
            controller.didActivateTab(active, previousActiveTab: nil)
        }
        controller.didFocusWindow(extensionWindow)
    }

    func reloadExtension(id: String) async {
        if let existing = loadedByID.removeValue(forKey: id) {
            try? controller.unload(existing.context)
        }
        guard let record = appModel?.state.installedExtensions.first(where: { $0.id == id }),
              record.enabled else {
            return
        }
        syncTabsWithWorkspace()
        await loadSingleExtension(record: record)
        if let active = activeExtensionTab {
            controller.didActivateTab(active, previousActiveTab: nil)
        }
        controller.didFocusWindow(extensionWindow)
    }

    private func loadSingleExtension(record: InstalledExtension) async {
        guard let model = appModel else { return }
        loadNoticesByID.removeValue(forKey: record.id)

        do {
            let webExt: WKWebExtension
            let loadMode: ExtensionLoadMode

            switch record.sourceKind {
            case .copiedPackage:
                let folderURL = model.store.extensionsDirectoryURL.appendingPathComponent(record.folderName, isDirectory: true)
                guard FileManager.default.fileExists(atPath: folderURL.path) else {
                    loadErrorsByID[record.id] = "Missing unpacked folder: \(record.folderName)"
                    return
                }
                webExt = try await WKWebExtension(resourceBaseURL: folderURL)
                loadMode = .copiedPackage

            case .safariAppExtension:
                guard let appexURL = resolveSafariAppExtensionURL(for: record),
                      let appexBundle = Bundle(url: appexURL) else {
                    let missing = record.sourceAppPath ?? record.sourceAppExtensionPath ?? record.id
                    loadErrorsByID[record.id] = "Linked Safari extension app not found at \(missing)."
                    return
                }
                do {
                    webExt = try await WKWebExtension(appExtensionBundle: appexBundle)
                    loadMode = .appExtensionBundle
                } catch let nsErr as NSError where nsErr.domain == WKWebExtension.errorDomain
                    && nsErr.code == WKWebExtension.Error.invalidResourceCodeSignature.rawValue {
                    // Fail closed to preserve Apple's code-signature boundary: `invalidResourceCodeSignature`
                    // covers both unsigned bundles and signed bundles tampered with after signing. Never
                    // silently downgrade a Safari `.appex` to `resourceBaseURL`.
                    loadErrorsByID[record.id] = "Safari app extension code signature validation failed (\(nsErr.localizedDescription)). \(AppBrandIdentity.productName) refuses to load unsigned or modified Safari .appex bundles; install a properly signed app or explicitly import an unpacked extension package instead."
                    return
                }
            }

            let context = WKWebExtensionContext(for: webExt)
            // Persist chrome.storage identity across launches BEFORE controller.load(context)
            context.uniqueIdentifier = record.contextUniqueIdentifier
            context.isInspectable = true

            // Sync localized displayName / version / initial requested permissions back into store if needed
            if let idx = model.state.installedExtensions.firstIndex(where: { $0.id == record.id }) {
                var updated = model.state.installedExtensions[idx]
                if let extName = webExt.displayName, !extName.isEmpty, !extName.hasPrefix("__MSG_") {
                    updated.displayName = extName
                }
                if let extVer = webExt.version, !extVer.isEmpty {
                    updated.version = extVer
                }
                for reqPerm in webExt.requestedPermissions {
                    let raw = reqPerm.rawValue
                    if !updated.grantedPermissions.contains(raw) && !updated.deniedPermissions.contains(raw) {
                        updated.grantedPermissions.append(raw)
                    }
                }
                updated.grantedPermissions.sort()
                for pattern in webExt.allRequestedMatchPatterns {
                    let raw = pattern.string
                    if !updated.grantedMatchPatterns.contains(raw) && !updated.deniedMatchPatterns.contains(raw) {
                        updated.grantedMatchPatterns.append(raw)
                    }
                }
                updated.grantedMatchPatterns.sort()
                if updated != model.state.installedExtensions[idx] {
                    model.state.installedExtensions[idx] = updated
                    model.persist()
                }
            }

            let freshRecord = model.state.installedExtensions.first(where: { $0.id == record.id }) ?? record
            configurePermissions(on: context, webExtension: webExt, record: freshRecord)

            try controller.load(context)
            loadedByID[record.id] = LoadedRecord(
                id: record.id,
                webExtension: webExt,
                context: context,
                loadMode: loadMode
            )
            loadErrorsByID.removeValue(forKey: record.id)

            if webExt.hasBackgroundContent {
                context.loadBackgroundContent { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.owner?.bumpRevision()
                    }
                }
            }
        } catch {
            loadErrorsByID[record.id] = error.localizedDescription
        }
    }

    private func resolveSafariAppExtensionURL(for record: InstalledExtension) -> URL? {
        let fm = FileManager.default
        if let appexPath = record.sourceAppExtensionPath, fm.fileExists(atPath: appexPath) {
            return URL(fileURLWithPath: appexPath, isDirectory: true)
        }
        if let appPath = record.sourceAppPath,
           let discovered = try? ExtensionPackageInstaller.discoverSafariWebExtensions(in: URL(fileURLWithPath: appPath)) {
            if let bundleID = record.sourceAppExtensionBundleID,
               let match = discovered.first(where: { $0.appExtensionBundleID.caseInsensitiveCompare(bundleID) == .orderedSame }) {
                return match.appExtensionURL
            }
            return discovered.first?.appExtensionURL
        }
        return nil
    }

    func applyPermissions(for extensionID: String) {
        guard let loaded = loadedByID[extensionID],
              let record = appModel?.state.installedExtensions.first(where: { $0.id == extensionID }) else {
            return
        }
        configurePermissions(on: loaded.context, webExtension: loaded.webExtension, record: record)
    }

    private func configurePermissions(
        on context: WKWebExtensionContext,
        webExtension: WKWebExtension,
        record: InstalledExtension
    ) {
        let grantedSet = Set(record.grantedPermissions)
        let deniedSet = Set(record.deniedPermissions)

        // 1. API Permissions
        var allKnownPerms = webExtension.requestedPermissions.union(webExtension.optionalPermissions)
        for p in record.grantedPermissions {
            allKnownPerms.insert(WKWebExtension.Permission(rawValue: p))
        }
        for p in record.deniedPermissions {
            allKnownPerms.insert(WKWebExtension.Permission(rawValue: p))
        }

        for perm in allKnownPerms {
            if deniedSet.contains(perm.rawValue) {
                context.setPermissionStatus(.deniedExplicitly, for: perm)
            } else if grantedSet.contains(perm.rawValue) || webExtension.requestedPermissions.contains(perm) {
                context.setPermissionStatus(.grantedExplicitly, for: perm)
            } else {
                context.setPermissionStatus(.unknown, for: perm)
            }
        }

        // 2. Website Match Patterns
        switch record.websiteAccessMode {
        case .allWebsites:
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
            for raw in record.grantedMatchPatterns {
                if let mp = try? WKWebExtension.MatchPattern(string: raw) {
                    context.setPermissionStatus(.grantedExplicitly, for: mp)
                }
            }

        case .ask:
            context.setPermissionStatus(.unknown, for: WKWebExtension.MatchPattern.allURLs())
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.unknown, for: pattern)
            }
            for raw in record.deniedMatchPatterns {
                if let mp = try? WKWebExtension.MatchPattern(string: raw) {
                    context.setPermissionStatus(.deniedExplicitly, for: mp)
                }
            }

        case .specificSites:
            context.setPermissionStatus(.deniedExplicitly, for: WKWebExtension.MatchPattern.allURLs())
            let allowedPatterns = Set(record.grantedMatchPatterns)
            for pattern in webExtension.allRequestedMatchPatterns {
                if allowedPatterns.contains(pattern.string) {
                    context.setPermissionStatus(.grantedExplicitly, for: pattern)
                } else {
                    context.setPermissionStatus(.deniedExplicitly, for: pattern)
                }
            }
            for raw in record.grantedMatchPatterns where raw != "<all_urls>" && raw != "*://*/*" {
                if let mp = try? WKWebExtension.MatchPattern(string: raw) {
                    context.setPermissionStatus(.grantedExplicitly, for: mp)
                }
            }
        }
    }

    func unloadAndClearData(for extensionID: String) async {
        guard let loaded = loadedByID.removeValue(forKey: extensionID) else { return }
        let context = loaded.context
        let dataTypes = WKWebExtensionController.allExtensionDataTypes

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            controller.fetchDataRecord(ofTypes: dataTypes, for: context) { [weak self] record in
                guard let self, let record else {
                    cont.resume()
                    return
                }
                self.controller.removeData(ofTypes: dataTypes, from: [record]) {
                    cont.resume()
                }
            }
        }
        try? controller.unload(context)
        loadErrorsByID.removeValue(forKey: extensionID)
        loadNoticesByID.removeValue(forKey: extensionID)
    }

    // MARK: - WebView Configuration

    func prepareWebViewConfiguration(
        baseConfiguration: WKWebViewConfiguration,
        initialURL: URL
    ) -> WKWebViewConfiguration {
        if initialURL.scheme?.lowercased() == "webkit-extension" {
            if let extContext = controller.extensionContext(for: initialURL),
               let extConfig = extContext.webViewConfiguration {
                return extConfig
            }
            if let host = initialURL.host?.lowercased(),
               let matching = loadedByID.values.first(where: { $0.context.uniqueIdentifier.lowercased() == host || $0.context.baseURL.host?.lowercased() == host }),
               let extConfig = matching.context.webViewConfiguration {
                return extConfig
            }
        }
        baseConfiguration.webExtensionController = controller
        return baseConfiguration
    }

    // MARK: - Tabs & Window Sync

    func syncTabsWithWorkspace(previousSelectedPadID: UUID? = nil) {
        guard let model = appModel else { return }
        let openPads = model.state.pads.filter { !$0.isHibernated }
        let openIDs = Set(openPads.map(\.id))

        // Close removed or newly hibernated tabs
        for (padID, tab) in Array(tabsByPadID) where !openIDs.contains(padID) {
            tabsByPadID.removeValue(forKey: padID)
            controller.didCloseTab(tab, windowIsClosing: false)
        }

        // Open newly created or woken tabs in order
        for pad in openPads where tabsByPadID[pad.id] == nil {
            let tab = VeypaneExtensionTab(padID: pad.id, runtime: self)
            tabsByPadID[pad.id] = tab
            controller.didOpenTab(tab)
        }

        // Activate selected tab if changed
        let currentSelectedID = model.state.selectedPadID
        if currentSelectedID != lastActivePadID {
            let prevID = previousSelectedPadID ?? lastActivePadID
            let prevTab = prevID.flatMap { tabsByPadID[$0] }
            if let newID = currentSelectedID, let newTab = tabsByPadID[newID] {
                controller.didActivateTab(newTab, previousActiveTab: prevTab)
            }
            lastActivePadID = currentSelectedID
        }
    }

    func setOverrideWebView(_ webView: WKWebView?, for padID: UUID) {
        syncTabsWithWorkspace()
        tabsByPadID[padID]?.overrideWebView = webView
        if let tab = tabsByPadID[padID] {
            controller.didActivateTab(tab, previousActiveTab: nil)
            controller.didFocusWindow(extensionWindow)
        }
    }

    func notifyTabMoved(padID: UUID, from oldIndex: Int) {
        guard let tab = tabsByPadID[padID] else { return }
        controller.didMoveTab(tab, from: oldIndex, in: extensionWindow)
    }

    func notifyTabPropertiesChanged(
        padID: UUID,
        loading: Bool,
        title: Bool,
        url: Bool,
        muted: Bool,
        zoom: Bool,
        size: Bool
    ) {
        guard let tab = tabsByPadID[padID] else { return }
        var props: WKWebExtension.TabChangedProperties = []
        if loading { props.insert(.loading) }
        if title { props.insert(.title) }
        if url { props.insert(.URL) }
        if muted { props.insert(.muted) }
        if zoom { props.insert(.zoomFactor) }
        if size { props.insert(.size) }
        guard !props.isEmpty else { return }
        controller.didChangeTabProperties(props, for: tab)
    }

    func notifyWindowFocused() {
        controller.didFocusWindow(extensionWindow)
        if let active = activeExtensionTab {
            controller.didActivateTab(active, previousActiveTab: nil)
        }
    }

    // MARK: - Commands, Menus, Toolbar & Settings Projections

    func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard let model = appModel else { return false }
        for record in model.state.installedExtensions where record.enabled {
            if let loaded = loadedByID[record.id],
               loaded.context.performCommand(for: event) {
                return true
            }
        }
        return false
    }

    func contextMenuItems(for padID: UUID) -> [NSMenuItem] {
        guard let model = appModel,
              let tab = tabsByPadID[padID] else {
            return []
        }
        var result: [NSMenuItem] = []
        for record in model.state.installedExtensions where record.enabled {
            if let loaded = loadedByID[record.id] {
                let items = loaded.context.menuItems(for: tab)
                result.append(contentsOf: items)
            }
        }
        return result
    }

    func toolbarItems(for padID: UUID?) -> [ExtensionToolbarItem] {
        guard let model = appModel else { return [] }
        let tab = padID.flatMap { tabsByPadID[$0] } ?? activeExtensionTab
        var items: [ExtensionToolbarItem] = []

        for record in model.state.installedExtensions where record.enabled {
            guard let loaded = loadedByID[record.id] else { continue }
            let action = loaded.context.action(for: tab)
            let icon = action?.icon(for: CGSize(width: 18, height: 18))
                ?? loaded.webExtension.icon(for: CGSize(width: 18, height: 18))
            let label = (action?.label.isEmpty == false) ? action!.label : record.displayName
            let badge = action?.badgeText ?? ""
            items.append(
                ExtensionToolbarItem(
                    id: record.id,
                    title: record.displayName,
                    tooltip: label,
                    icon: icon,
                    badgeText: badge,
                    isPinned: record.pinnedToToolbar
                )
            )
        }
        return items
    }

    func settingsItems(installed: [InstalledExtension]) -> [ExtensionSettingsItem] {
        installed.map { record in
            let loaded = loadedByID[record.id]
            let icon = loaded?.webExtension.icon(for: CGSize(width: 32, height: 32))
                ?? loadFallbackManifestIcon(for: record)
            let hasOptions = (loaded?.context.optionsPageURL != nil)

            var allPerms = Set(record.grantedPermissions).union(record.deniedPermissions)
            if let ext = loaded?.webExtension {
                for p in ext.requestedPermissions { allPerms.insert(p.rawValue) }
                for p in ext.optionalPermissions { allPerms.insert(p.rawValue) }
            }

            var errors: [String] = []
            if let loadErr = loadErrorsByID[record.id] {
                errors.append(loadErr)
            }
            if let notice = loadNoticesByID[record.id] {
                errors.append(notice)
            }
            if let extErrors = loaded?.webExtension.errors {
                errors.append(contentsOf: extErrors.map(\.localizedDescription))
            }
            if let ctxErrors = loaded?.context.errors {
                errors.append(contentsOf: ctxErrors.map(\.localizedDescription))
            }
            // Deduplicate while keeping order
            var seen = Set<String>()
            let uniqueErrors = errors.filter { err in
                guard !err.isEmpty, !seen.contains(err) else { return false }
                seen.insert(err)
                return true
            }

            return ExtensionSettingsItem(
                id: record.id,
                displayName: record.displayName,
                version: record.version,
                icon: icon,
                enabled: record.enabled,
                isLoaded: loaded != nil,
                pinnedToToolbar: record.pinnedToToolbar,
                hasOptionsPage: hasOptions,
                websiteAccessMode: record.websiteAccessMode,
                grantedMatchPatterns: record.grantedMatchPatterns,
                allPermissions: allPerms.sorted(),
                grantedPermissions: Set(record.grantedPermissions),
                errors: uniqueErrors,
                sourceKind: record.sourceKind,
                sourceAppDisplayName: record.sourceAppPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent },
                sourceAppVersion: record.sourceAppVersion,
                loadMode: loaded?.loadMode
            )
        }
    }

    private func loadFallbackManifestIcon(for record: InstalledExtension) -> NSImage? {
        guard let model = appModel else { return nil }
        let extRoot: URL
        switch record.sourceKind {
        case .copiedPackage:
            extRoot = model.store.extensionsDirectoryURL.appendingPathComponent(record.folderName, isDirectory: true)
        case .safariAppExtension:
            guard let appexURL = resolveSafariAppExtensionURL(for: record) else { return nil }
            extRoot = appexURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
        }
        let manifestURL = extRoot.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let icons = json["icons"] as? [String: String] else {
            return nil
        }
        let preferredKeys = ["128", "64", "48", "32", "16"]
        for key in preferredKeys {
            if let rel = icons[key] {
                let iconURL = extRoot.appendingPathComponent(rel)
                if let img = NSImage(contentsOf: iconURL) {
                    return img
                }
            }
        }
        if let firstRel = icons.values.first,
           let img = NSImage(contentsOf: extRoot.appendingPathComponent(firstRel)) {
            return img
        }
        return nil
    }

    func performToolbarAction(for extensionID: String) {
        guard let loaded = loadedByID[extensionID] else { return }
        let tab = activeExtensionTab
        loaded.context.performAction(for: tab)
    }

    func openOptionsPage(id: String) {
        guard let loaded = loadedByID[id],
              let optionsURL = loaded.context.optionsPageURL else {
            return
        }
        openOrFocusPad(url: optionsURL, title: "\(loaded.webExtension.displayName ?? "Extension") Options")
    }

    private func openOrFocusPad(url: URL, title: String?) {
        guard let model = appModel else { return }
        if let existing = model.state.pads.first(where: { $0.url == url }) {
            model.selectPad(id: existing.id)
            model.showPanel()
            return
        }
        model.addPad(url: url, title: title)
        model.showPanel()
    }

    func listAutomationSummaries(installed: [InstalledExtension]) -> [AutomationExtensionSummary] {
        installed.map { record in
            let loaded = loadedByID[record.id]
            var errors: [String] = []
            if let loadErr = loadErrorsByID[record.id] {
                errors.append(loadErr)
            }
            if let extErrors = loaded?.webExtension.errors {
                errors.append(contentsOf: extErrors.map(\.localizedDescription))
            }
            if let ctxErrors = loaded?.context.errors {
                errors.append(contentsOf: ctxErrors.map(\.localizedDescription))
            }

            let commands: [AutomationExtensionCommand] = (loaded?.context.commands ?? []).map { cmd in
                AutomationExtensionCommand(
                    id: cmd.id,
                    title: cmd.title,
                    shortcut: cmd.activationKey
                )
            }

            return AutomationExtensionSummary(
                id: record.id,
                name: record.displayName,
                version: record.version,
                enabled: record.enabled,
                loaded: loaded != nil,
                errors: errors,
                commands: commands
            )
        }
    }

    func performAutomationCommand(
        extensionQuery: String,
        commandID: String,
        padQuery: String?
    ) throws -> AutomationExtensionCommandResult {
        guard let model = appModel else {
            throw AutomationBridgeError.extensionNotFound(extensionQuery)
        }

        if let padQuery, !padQuery.isEmpty {
            guard let targetPad = PadWorkspaceEngine.findPad(matching: padQuery, in: model.state.pads) else {
                throw AutomationBridgeError.padNotFound(padQuery)
            }
            model.selectPad(id: targetPad.id)
            syncTabsWithWorkspace()
        }

        let lower = extensionQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchedRecord = model.state.installedExtensions.first {
            $0.id.lowercased() == lower || $0.folderName.lowercased() == lower
        } ?? model.state.installedExtensions.first {
            $0.displayName.lowercased() == lower
        } ?? model.state.installedExtensions.first {
            $0.displayName.lowercased().contains(lower) || $0.id.lowercased().contains(lower)
        }

        guard let record = matchedRecord,
              let loaded = loadedByID[record.id] else {
            throw AutomationBridgeError.extensionNotFound(extensionQuery)
        }

        let cmdLower = commandID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let command = loaded.context.commands.first(where: {
            $0.id.lowercased() == cmdLower || $0.title.lowercased() == cmdLower
        }) else {
            throw AutomationBridgeError.extensionCommandNotFound(commandID)
        }

        loaded.context.performCommand(command)
        return AutomationExtensionCommandResult(
            ok: true,
            extensionID: record.id,
            commandID: command.id
        )
    }

    private func extensionID(for context: WKWebExtensionContext) -> String? {
        loadedByID.first(where: { $0.value.context === context })?.key
    }

    // MARK: - WKWebExtensionControllerDelegate

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        [extensionWindow]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        extensionWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let model = appModel else {
            completionHandler(nil, nil)
            return
        }
        let targetURL = configuration.url ?? URL(string: "https://www.google.com")!
        model.addPad(url: targetURL, title: nil)
        if !configuration.shouldBeActive, let prevID = lastActivePadID {
            model.selectPad(id: prevID)
        }
        syncTabsWithWorkspace()
        let createdTab = model.state.pads.last.flatMap { tabsByPadID[$0.id] } ?? activeExtensionTab
        completionHandler(createdTab, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        guard let model = appModel else {
            completionHandler(nil, nil)
            return
        }
        let urls = configuration.tabURLs
        if urls.isEmpty {
            model.addPad(url: URL(string: "https://www.google.com")!, title: nil)
        } else {
            for url in urls {
                model.addPad(url: url, title: nil)
            }
        }
        if configuration.shouldBeFocused {
            model.showPanel()
        }
        syncTabsWithWorkspace()
        completionHandler(extensionWindow, nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let optionsURL = extensionContext.optionsPageURL {
            openOrFocusPad(
                url: optionsURL,
                title: "\(extensionContext.webExtension.displayName ?? "Extension") Options"
            )
            completionHandler(nil)
        } else {
            let err = NSError(
                domain: "com.veypane.extensions",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Extension has no options page."]
            )
            completionHandler(err)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        guard owner?.allowInteractivePrompts == true else {
            completionHandler(permissions, nil)
            return
        }

        let extName = extensionContext.webExtension.displayName ?? "Extension"
        let items = permissions.map(\.rawValue).sorted()
        let approved = runPermissionSheet(
            title: L10n.format("extension.prompt.permissions_title", extName),
            items: items
        )

        if let extID = extensionID(for: extensionContext),
           let model = appModel,
           let idx = model.state.installedExtensions.firstIndex(where: { $0.id == extID }) {
            for raw in items {
                if approved {
                    if !model.state.installedExtensions[idx].grantedPermissions.contains(raw) {
                        model.state.installedExtensions[idx].grantedPermissions.append(raw)
                    }
                    model.state.installedExtensions[idx].deniedPermissions.removeAll { $0 == raw }
                } else {
                    model.state.installedExtensions[idx].grantedPermissions.removeAll { $0 == raw }
                    if !model.state.installedExtensions[idx].deniedPermissions.contains(raw) {
                        model.state.installedExtensions[idx].deniedPermissions.append(raw)
                    }
                }
            }
            model.persist()
            owner?.bumpRevision()
        }

        completionHandler(approved ? permissions : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        guard owner?.allowInteractivePrompts == true else {
            completionHandler(matchPatterns, nil)
            return
        }

        if let extID = extensionID(for: extensionContext),
           let record = appModel?.state.installedExtensions.first(where: { $0.id == extID }),
           record.websiteAccessMode == .allWebsites {
            completionHandler(matchPatterns, nil)
            return
        }

        let extName = extensionContext.webExtension.displayName ?? "Extension"
        let items = matchPatterns.map(\.string).sorted()
        let approved = runPermissionSheet(
            title: L10n.format("extension.prompt.sites_title", extName),
            items: items
        )

        if let extID = extensionID(for: extensionContext),
           let model = appModel,
           let idx = model.state.installedExtensions.firstIndex(where: { $0.id == extID }) {
            for raw in items {
                if approved {
                    if !model.state.installedExtensions[idx].grantedMatchPatterns.contains(raw) {
                        model.state.installedExtensions[idx].grantedMatchPatterns.append(raw)
                    }
                    model.state.installedExtensions[idx].deniedMatchPatterns.removeAll { $0 == raw }
                } else if !model.state.installedExtensions[idx].deniedMatchPatterns.contains(raw) {
                    model.state.installedExtensions[idx].deniedMatchPatterns.append(raw)
                }
            }
            model.persist()
            owner?.bumpRevision()
        }

        completionHandler(approved ? matchPatterns : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        guard owner?.allowInteractivePrompts == true else {
            completionHandler(urls, nil)
            return
        }

        if let extID = extensionID(for: extensionContext),
           let record = appModel?.state.installedExtensions.first(where: { $0.id == extID }),
           record.websiteAccessMode == .allWebsites {
            completionHandler(urls, nil)
            return
        }

        let extName = extensionContext.webExtension.displayName ?? "Extension"
        let items = urls.compactMap { $0.host ?? $0.absoluteString }.sorted()
        let approved = runPermissionSheet(
            title: L10n.format("extension.prompt.sites_title", extName),
            items: items
        )

        if approved,
           let extID = extensionID(for: extensionContext),
           let model = appModel,
           let idx = model.state.installedExtensions.firstIndex(where: { $0.id == extID }) {
            for url in urls {
                if let host = url.host {
                    let pat = "*://\(host)/*"
                    if !model.state.installedExtensions[idx].grantedMatchPatterns.contains(pat) {
                        model.state.installedExtensions[idx].grantedMatchPatterns.append(pat)
                    }
                }
            }
            model.persist()
            owner?.bumpRevision()
        }

        completionHandler(approved ? urls : [], nil)
    }

    private func runPermissionSheet(title: String, items: [String]) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = items.map { "• \($0)" }.joined(separator: "\n")
        alert.addButton(withTitle: L10n.string("extension.prompt.allow"))
        alert.addButton(withTitle: L10n.string("extension.prompt.deny"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext context: WKWebExtensionContext
    ) {
        owner?.bumpRevision()
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard action.presentsPopup else {
            completionHandler(nil)
            return
        }

        let extID = extensionID(for: context) ?? ""
        appModel?.showPanel()

        guard let anchorView = owner?.bestAnchorView(for: extID),
              anchorView.window != nil else {
            let err = NSError(
                domain: "com.veypane.extensions",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No visible anchor view for extension popup."]
            )
            completionHandler(err)
            return
        }

        action.hasUnreadBadgeText = false
        owner?.bumpRevision()

        if let popover = action.popupPopover {
            popover.behavior = .transient
            popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
            completionHandler(nil)
            return
        }

        if let popupWebView = action.popupWebView {
            fallbackPopover?.close()
            let vc = NSViewController()
            let preferred = popupWebView.fittingSize
            let size = NSSize(
                width: max(320, min(preferred.width > 10 ? preferred.width : 380, 640)),
                height: max(240, min(preferred.height > 10 ? preferred.height : 480, 720))
            )
            popupWebView.frame = NSRect(origin: .zero, size: size)
            vc.view = popupWebView
            vc.preferredContentSize = size

            let pop = NSPopover()
            pop.contentViewController = vc
            pop.contentSize = size
            pop.behavior = .transient
            fallbackPopover = pop
            pop.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
            completionHandler(nil)
            return
        }

        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        let err = NSError(
            domain: "com.veypane.nativeMessaging",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Native messaging is not supported."]
        )
        replyHandler(nil, err)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let err = NSError(
            domain: "com.veypane.nativeMessaging",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Native messaging is not supported."]
        )
        completionHandler(err)
    }
}
