import AppKit
import WebKit
import VeypaneCore

@MainActor
public final class VeypaneWebView: WKWebView {
    public var onOpenInNewPad: ((URL) -> Void)?
    public var onOpenInDefaultBrowser: ((URL) -> Void)?
    public var onCopyPageURL: (() -> Void)?
    public var extensionMenuItemsProvider: (() -> [NSMenuItem])?

    public override func swipe(with event: NSEvent) {
        if allowsBackForwardNavigationGestures {
            if event.deltaX > 0.1, canGoBack {
                goBack()
                return
            }
            if event.deltaX < -0.1, canGoForward {
                goForward()
                return
            }
        }
        super.swipe(with: event)
    }

    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)

        if let extItems = extensionMenuItemsProvider?(), !extItems.isEmpty {
            menu.addItem(.separator())
            for item in extItems {
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        if let currentURL = self.url {
            let newPadItem = NSMenuItem(
                title: "Duplicate Page in New Pad",
                action: #selector(handleDuplicateInNewPad(_:)),
                keyEquivalent: ""
            )
            newPadItem.target = self
            newPadItem.representedObject = currentURL
            menu.addItem(newPadItem)

            let openExternal = NSMenuItem(
                title: "Open Page in Default Browser",
                action: #selector(handleOpenExternal(_:)),
                keyEquivalent: ""
            )
            openExternal.target = self
            openExternal.representedObject = currentURL
            menu.addItem(openExternal)

            let copyItem = NSMenuItem(
                title: "Copy Page URL",
                action: #selector(handleCopyURL(_:)),
                keyEquivalent: ""
            )
            copyItem.target = self
            menu.addItem(copyItem)
        }
    }

    @objc private func handleDuplicateInNewPad(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            onOpenInNewPad?(url)
        }
    }

    @objc private func handleOpenExternal(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            onOpenInDefaultBrowser?(url)
        }
    }

    @objc private func handleCopyURL(_ sender: NSMenuItem) {
        onCopyPageURL?()
    }
}

@MainActor
private final class WeakScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var delegate: (any WKScriptMessageHandler)?

    init(delegate: any WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
public final class PadWebController: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate, WebPageContentSession {
    public let padID: UUID
    public let initialTargetURL: URL
    public let profileDataStoreID: UUID?
    public private(set) var isPresentingOpenPanel: Bool = false
    public let webView: VeypaneWebView
    private let notificationBridge = WebNotificationBridge()

    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var loadingObservation: NSKeyValueObservation?
    private var progressObservation: NSKeyValueObservation?
    private var backObservation: NSKeyValueObservation?
    private var forwardObservation: NSKeyValueObservation?

    public private(set) var canGoBack: Bool = false
    public private(set) var canGoForward: Bool = false
    public private(set) var isLoading: Bool = false
    public private(set) var hasCompletedNavigation: Bool = false
    public private(set) var estimatedProgress: Double = 0.0
    public private(set) var lastDownloadStatus: String?
    public private(set) var diagnosticsTracker = NavigationDiagnosticsTracker<ObjectIdentifier>()
    public var compatibilityIssue: SiteCompatibilityIssueKind { diagnosticsTracker.issueKind }
    public var compatibilitySummary: String? { diagnosticsTracker.issueSummary }
    public var lastNavigationError: String? { diagnosticsTracker.currentNavigationError }
    public var sampledNavigatorUserAgent: SampledNavigatorUADiagnostic { diagnosticsTracker.sampledNavigatorUserAgent }
    public var observedHTTPRequestUserAgent: ObservedHTTPHeaderUADiagnostic { diagnosticsTracker.observedHTTPRequestUserAgent }
    public var subframeObservations: [SubframeNavigationDiagnostic] { diagnosticsTracker.subframeObservations }
    public var iframeDiagnostics: PassiveIframeDiagnosticSummary { diagnosticsTracker.iframeDiagnostics }
    public var failureCategories: [PassiveFailureCategoryDiagnostic] { diagnosticsTracker.failureCategories }
    public var isCompatibilityBannerDismissed: Bool = false

    public var onPadStateChanged: (() -> Void)?
    public var onTitleAndBadgeUpdated: ((String, ParsedBadge) -> Void)?
    public var onURLCommitted: ((URL) -> Void)?
    public var onFaviconDetected: ((URL) -> Void)?
    public var onFaviconCandidatesDetected: (([FaviconCandidate]) -> Void)?
    public var onNewWindowRequested: ((URL) -> Void)?
    public var onCreatePopupWebView: ((WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures) -> WKWebView?)?
    public var onWebViewDidClose: (() -> Void)?
    public var onDownloadStatusChanged: ((String?) -> Void)?
    public var onLoadRequested: (() -> Void)?
    public var onReloadRequested: (() -> Void)?

    private struct AppliedScriptSignature: Equatable {
        var paused: Bool
        var muted: Bool
        var hasContentRuleList: Bool
        var matchingRuleIDs: [UUID]
    }

    private var activeRules: [InjectionRule] = []
    private var activeContentRuleList: WKContentRuleList?
    private var isEffectivelyMuted: Bool = false
    public private(set) var isCustomModificationsPaused: Bool = false
    public private(set) var processRecoveryState = WebContentRecoveryState()
    public var onWebContentProcessTerminated: (() -> Void)?
    private var lastAppliedScriptSignature: AppliedScriptSignature?
    private var lastReportedProgress: Double = 0.0
    private let isExtensionInternalPage: Bool

    public init(
        pad: Pad,
        profileDataStoreID: UUID?,
        useNonPersistentDataStore: Bool = false,
        suppliedConfiguration: WKWebViewConfiguration? = nil,
        injectionRules: [InjectionRule],
        compiledContentRuleList: WKContentRuleList?,
        globalMuted: Bool,
        onInitialLoadIssued: (() -> Void)? = nil
    ) {
        self.padID = pad.id
        self.initialTargetURL = pad.url
        self.profileDataStoreID = profileDataStoreID
        self.activeRules = injectionRules
        self.activeContentRuleList = compiledContentRuleList
        self.isCustomModificationsPaused = pad.pauseCustomModifications
        self.isExtensionInternalPage = ExtensionManager.shared.isExtensionInternalURL(pad.url)

        let finalConfig: WKWebViewConfiguration
        if let suppliedConfiguration {
            // WKUIDelegate `createWebViewWith` contract: use the EXACT configuration supplied by WebKit
            // so `window.opener`, `postMessage`, named-window group, and `websiteDataStore` remain intact.
            finalConfig = suppliedConfiguration
        } else {
            let baseConfig = WKWebViewConfiguration()
            if useNonPersistentDataStore {
                baseConfig.websiteDataStore = .nonPersistent()
            } else if let profileDataStoreID {
                baseConfig.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileDataStoreID)
            } else {
                baseConfig.websiteDataStore = .default()
            }
            baseConfig.defaultWebpagePreferences.allowsContentJavaScript = true
            baseConfig.preferences.javaScriptCanOpenWindowsAutomatically = false
            baseConfig.preferences.isElementFullscreenEnabled = true
            baseConfig.mediaTypesRequiringUserActionForPlayback = []
            if pad.userAgentPreset != .defaultWebKit {
                baseConfig.applicationNameForUserAgent = UserAgentPreset.desktopSafariApplicationName
            }

            if !isExtensionInternalPage {
                let userContent = WKUserContentController()
                userContent.add(WeakScriptMessageProxy(delegate: notificationBridge), name: WebNotificationBridge.handlerName)
                baseConfig.userContentController = userContent
            }

            finalConfig = ExtensionManager.shared.prepareWebViewConfiguration(
                baseConfiguration: baseConfig,
                initialURL: pad.url
            )
        }

        self.webView = VeypaneWebView(frame: NSRect(x: 0, y: 0, width: 1020, height: 700), configuration: finalConfig)
        super.init()

        let capturedPadID = pad.id
        webView.extensionMenuItemsProvider = {
            ExtensionManager.shared.contextMenuItems(for: capturedPadID)
        }

        let capturedTitle = pad.title
        notificationBridge.padTitleProvider = { capturedTitle }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.pageZoom = pad.pageZoom
        if !isExtensionInternalPage && suppliedConfiguration == nil {
            // Use native WebKit + applicationNameForUserAgent for desktopSafari so main frame, iframes,
            // and workers share genuine WebKit UA headers; set customUserAgent only for mobile/custom overrides.
            if pad.userAgentPreset == .desktopSafari || pad.userAgentPreset == .defaultWebKit {
                webView.customUserAgent = nil
            } else {
                webView.customUserAgent = pad.effectiveUserAgent
            }
        }
        webView.isInspectable = pad.isInspectable

        if !isExtensionInternalPage && suppliedConfiguration == nil {
            rebuildUserScripts(
                for: pad.url,
                muted: pad.isMuted || globalMuted,
                paused: pad.pauseCustomModifications
            )
        }
        setupObservations()
        if pad.isMuted || globalMuted {
            applyMute(true)
        }
        diagnosticsTracker.prepareExplicitMainNavigation(targetURL: pad.url)
        onInitialLoadIssued?()
        if suppliedConfiguration == nil {
            // When `suppliedConfiguration != nil` (`createWebViewWith`), WebKit automatically loads the request.
            webView.load(URLRequest(url: pad.url))
        }
    }

    public func buildTopLevelNavigationDiagnostic() -> TopLevelNavigationDiagnostic {
        diagnosticsTracker.buildTopLevelDiagnostic()
    }

    public func navigate(to url: URL) {
        hasCompletedNavigation = false
        isCompatibilityBannerDismissed = false
        processRecoveryState.clearPendingRecovery()
        diagnosticsTracker.prepareExplicitMainNavigation(targetURL: url)
        rebuildUserScripts(for: url, muted: isEffectivelyMuted, paused: isCustomModificationsPaused)
        onLoadRequested?()
        webView.load(URLRequest(url: url))
    }

    public func reload() {
        isCompatibilityBannerDismissed = false
        processRecoveryState.clearPendingRecovery()
        diagnosticsTracker.prepareExplicitMainNavigation(targetURL: webView.url ?? initialTargetURL)
        onReloadRequested?()
        webView.reload()
    }

    /// Evaluates loop-guarded recovery after `webViewWebContentProcessDidTerminate`.
    /// When `.autoReload` is returned, triggers a single `reload()` on this existing `WKWebView`
    /// without recreating a new web view or discarding cookies/navigation history.
    @discardableResult
    public func recoverIfNeededAfterProcessTermination(now: Date = Date()) -> WebContentRecoveryDecision {
        let decision = processRecoveryState.consumeAutoRecoveryIfAllowed(now: now)
        if decision == .autoReload {
            diagnosticsTracker.prepareExplicitMainNavigation(targetURL: webView.url ?? initialTargetURL)
            onReloadRequested?()
            webView.reload()
        }
        return decision
    }

    /// Deterministic test seam for verifying renderer-termination degradation without killing live OS processes.
    public func handleWebContentProcessTermination(now: Date = Date()) {
        diagnosticsTracker.recordWebContentProcessTermination(currentURL: webView.url ?? initialTargetURL)
        processRecoveryState.recordTermination(now: now)
        onWebContentProcessTerminated?()
        onPadStateChanged?()
    }

    public func stopLoading() {
        webView.stopLoading()
    }

    public func goBack() {
        if webView.canGoBack {
            diagnosticsTracker.prepareExplicitMainNavigation(targetURL: webView.backForwardList.backItem?.url)
            webView.goBack()
        }
    }

    public func goForward() {
        if webView.canGoForward {
            diagnosticsTracker.prepareExplicitMainNavigation(targetURL: webView.backForwardList.forwardItem?.url)
            webView.goForward()
        }
    }

    public func applyUserAgentPreset(_ preset: UserAgentPreset, customValue: String?) {
        guard !isExtensionInternalPage else { return }
        let desiredCustomUA: String? = switch preset {
        case .desktopSafari, .defaultWebKit:
            nil
        case .iPhoneSafari, .iPadSafari, .custom:
            SiteCompatibilityInspector.nonEmptyTrimmed(preset.resolvedUserAgent(customValue: customValue))
        }
        let currentCustomUA = SiteCompatibilityInspector.nonEmptyTrimmed(webView.customUserAgent)
        guard currentCustomUA != desiredCustomUA else { return }
        webView.customUserAgent = desiredCustomUA
        diagnosticsTracker.prepareExplicitMainNavigation(targetURL: webView.url ?? initialTargetURL)
        onReloadRequested?()
        webView.reload()
    }

    public func applyUserAgent(_ userAgent: String?) {
        let normalized = SiteCompatibilityInspector.nonEmptyTrimmed(userAgent)
        let currentCustomUA = SiteCompatibilityInspector.nonEmptyTrimmed(webView.customUserAgent)
        guard currentCustomUA != normalized else { return }
        webView.customUserAgent = normalized
        diagnosticsTracker.prepareExplicitMainNavigation(targetURL: webView.url ?? initialTargetURL)
        onReloadRequested?()
        webView.reload()
    }

    public func applyPauseCustomModifications(_ paused: Bool) {
        guard isCustomModificationsPaused != paused else { return }
        isCustomModificationsPaused = paused
        isCompatibilityBannerDismissed = false
        let current = webView.url ?? initialTargetURL
        diagnosticsTracker.prepareExplicitMainNavigation(targetURL: current)
        rebuildUserScripts(for: current, muted: isEffectivelyMuted, paused: paused, force: true)
        onReloadRequested?()
        webView.reload()
    }

    public func applyZoom(_ zoom: Double) {
        webView.pageZoom = min(max(zoom, 0.5), 3.0)
    }

    public func applyInspectable(_ inspectable: Bool) {
        webView.isInspectable = inspectable
    }

    public func applyMute(_ muted: Bool) {
        isEffectivelyMuted = muted
        webView.setAllMediaPlaybackSuspended(muted)
        let js = """
        (function() {
            var m = \(muted ? "true" : "false");
            window.__veypaneMuted = m;
            document.querySelectorAll('audio, video').forEach(function(el) { el.muted = m; });
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    public func updateRules(
        injectionRules: [InjectionRule],
        compiledContentRuleList: WKContentRuleList?
    ) {
        self.activeRules = injectionRules
        self.activeContentRuleList = compiledContentRuleList
        rebuildUserScripts(
            for: webView.url ?? initialTargetURL,
            muted: isEffectivelyMuted,
            paused: isCustomModificationsPaused,
            force: true
        )
    }

    public func findInPage(_ query: String, forward: Bool = true, completion: (@Sendable (Bool) -> Void)? = nil) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(false)
            return
        }
        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = false
        config.wraps = true
        webView.find(trimmed, configuration: config) { result in
            completion?(result.matchFound)
        }
    }

    // MARK: - WebPageContentSession Conformance (S2)

    public func ensureLoadedAndWaitUntilReady(timeoutSeconds: TimeInterval) async -> Bool {
        if webView.url == nil && !webView.isLoading {
            hasCompletedNavigation = false
            webView.load(URLRequest(url: initialTargetURL))
        }

        let deadline = Date().addingTimeInterval(max(0.2, timeoutSeconds))
        while Date() < deadline {
            if !webView.isLoading {
                let state = await evaluateReadyState()
                if hasCompletedNavigation || state == "complete" || (state == "interactive" && webView.url != nil) {
                    // Brief layout settle if just finished
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    public func currentTitle() async -> String? {
        webView.title
    }

    public func currentURL() async -> URL? {
        webView.url
    }

    public func extractBodyInnerText() async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.body ? (document.body.innerText || '') : ''") { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    public func extractDocumentTextContent() async -> String? {
        let js = """
        (function() {
            var root = document.body || document.documentElement;
            if (!root) return '';
            return (root.textContent || '').replace(/\\s+/g, ' ').trim();
        })()
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    private func evaluateReadyState() async -> String {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.readyState") { value, _ in
                continuation.resume(returning: (value as? String) ?? "")
            }
        }
    }

    public func evaluateLimitedScript(_ script: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error {
                    continuation.resume(throwing: AutomationBridgeError.evaluationFailed(error.localizedDescription))
                } else if let value {
                    continuation.resume(returning: String(describing: value))
                } else {
                    continuation.resume(returning: "undefined")
                }
            }
        }
    }

    private func rebuildUserScripts(
        for targetURL: URL,
        muted: Bool,
        paused: Bool,
        force: Bool = false
    ) {
        guard !isExtensionInternalPage else { return }
        let matching = paused ? [] : ContentRulesEngine.matchingInjectionRules(for: targetURL, from: activeRules)
        let signature = AppliedScriptSignature(
            paused: paused,
            muted: muted,
            hasContentRuleList: (!paused && activeContentRuleList != nil),
            matchingRuleIDs: matching.map(\.id)
        )
        if !force, lastAppliedScriptSignature == signature {
            return
        }
        lastAppliedScriptSignature = signature

        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        controller.removeAllContentRuleLists()

        guard !paused else { return }

        if let ruleList = activeContentRuleList {
            controller.add(ruleList)
        }

        // 1. Top-frame-only Web Notifications bridge (never injected into subframes / verification iframes)
        let isGoogleSorryGate = ((targetURL.host ?? "").lowercased().contains("google.") && targetURL.path.lowercased().hasPrefix("/sorry"))
        if !isGoogleSorryGate {
            controller.addUserScript(
                WKUserScript(
                    source: WebNotificationBridge.bootstrapJavaScript,
                    injectionTime: .atDocumentStart,
                    forMainFrameOnly: true
                )
            )
        }

        // 2. Persistent media mute observer when muted (main frame only)
        if muted {
            let muteObserverJS = """
            (function() {
                function muteAll() {
                    document.querySelectorAll('audio, video').forEach(function(el) { el.muted = true; });
                }
                document.addEventListener('DOMContentLoaded', muteAll);
                new MutationObserver(muteAll).observe(document.documentElement || document, { childList: true, subtree: true });
            })();
            """
            controller.addUserScript(
                WKUserScript(source: muteObserverJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
            )
        }

        // 3. Matching custom CSS/JS rules
        for rule in matching {
            let wkTime: WKUserScriptInjectionTime = (rule.injectionTime == .atDocumentStart)
                ? .atDocumentStart
                : .atDocumentEnd
            if let cssScript = ContentRulesEngine.makeCSSInjectionScript(css: rule.css, ruleID: rule.id) {
                controller.addUserScript(WKUserScript(source: cssScript, injectionTime: wkTime, forMainFrameOnly: true))
            }
            let jsTrimmed = rule.javascript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !jsTrimmed.isEmpty {
                controller.addUserScript(WKUserScript(source: jsTrimmed, injectionTime: wkTime, forMainFrameOnly: true))
            }
        }
    }

    private func setupObservations() {
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.emitObservedTitle(self?.webView.title)
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, let newURL = self.webView.url else { return }
                self.onURLCommitted?(newURL)
                ExtensionManager.shared.notifyTabPropertiesChanged(padID: self.padID, url: true)
            }
        }
        loadingObservation = webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = self.webView.isLoading
                self.onPadStateChanged?()
                ExtensionManager.shared.notifyTabPropertiesChanged(padID: self.padID, loading: true)
            }
        }
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let next = self.webView.estimatedProgress
                self.estimatedProgress = next
                if abs(next - self.lastReportedProgress) >= 0.05 || next >= 1.0 || next <= 0.01 {
                    self.lastReportedProgress = next
                    self.onPadStateChanged?()
                }
            }
        }
        backObservation = webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canGoBack = self.webView.canGoBack
                self.onPadStateChanged?()
            }
        }
        forwardObservation = webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.canGoForward = self.webView.canGoForward
                self.onPadStateChanged?()
            }
        }
    }

    private func emitObservedTitle(_ rawCandidate: String?) {
        let rawTitle = (rawCandidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawTitle.isEmpty else { return }
        let badge = BadgeParser.parse(pageTitle: rawTitle)
        notificationBridge.padTitleProvider = { badge.cleanTitle }
        onTitleAndBadgeUpdated?(rawTitle, badge)
        ExtensionManager.shared.notifyTabPropertiesChanged(padID: padID, title: true)
    }

    // MARK: - WKNavigationDelegate

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping @MainActor (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        let reqURL = navigationAction.request.url
        let rawReqUA = SiteCompatibilityInspector.nonEmptyTrimmed(
            navigationAction.request.value(forHTTPHeaderField: "User-Agent")
        )

        // 1. Handle custom app scheme or non-web external OS schemes (e.g. veypane://, mailto:, tel:)
        if let url = reqURL, let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            if AppBrandIdentity.isSupportedURLScheme(scheme) || !PopupNavigationPolicy.isStandardWebDocumentScheme(scheme) {
                if navigationAction.targetFrame?.isMainFrame == true {
                    diagnosticsTracker.recordMainFramePolicy(
                        url: reqURL,
                        policyDecision: "cancel",
                        observedRequestUA: rawReqUA
                    )
                } else if navigationAction.targetFrame != nil {
                    diagnosticsTracker.recordSubframePolicy(url: reqURL, policyDecision: "cancel")
                }
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel, preferences)
                return
            }
        }

        // 2. `targetFrame == nil` indicates a new-window / popup navigation (`target="_blank"` or `window.open`):
        //    do NOT preempt `createWebViewWith`, do NOT create a duplicate pad here, and do NOT mutate opener state.
        guard let targetFrame = navigationAction.targetFrame else {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
            } else {
                decisionHandler(.allow, preferences)
            }
            return
        }

        let isMainFrame = targetFrame.isMainFrame
        if let url = reqURL {
            if !isExtensionInternalPage,
               ExtensionManager.shared.isExtensionInternalURL(url),
               isMainFrame {
                diagnosticsTracker.recordMainFramePolicy(
                    url: reqURL,
                    policyDecision: "cancel",
                    observedRequestUA: rawReqUA
                )
                onNewWindowRequested?(url)
                decisionHandler(.cancel, preferences)
                return
            }
            if isMainFrame {
                rebuildUserScripts(for: url, muted: isEffectivelyMuted, paused: isCustomModificationsPaused)
            }
        }
        if navigationAction.shouldPerformDownload {
            if isMainFrame {
                diagnosticsTracker.recordMainFramePolicy(
                    url: reqURL,
                    policyDecision: "download",
                    observedRequestUA: rawReqUA
                )
            } else {
                diagnosticsTracker.recordSubframePolicy(url: reqURL, policyDecision: "download")
            }
            decisionHandler(.download, preferences)
            return
        }
        if isMainFrame {
            diagnosticsTracker.recordMainFramePolicy(
                url: reqURL,
                policyDecision: "allow",
                observedRequestUA: rawReqUA
            )
        } else {
            diagnosticsTracker.recordSubframePolicy(url: reqURL, policyDecision: "allow")
        }
        decisionHandler(.allow, preferences)
    }

    public func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        let http = navigationResponse.response as? HTTPURLResponse
        let respURL = http?.url ?? navigationResponse.response.url

        if navigationResponse.isForMainFrame {
            diagnosticsTracker.recordMainFrameResponse(url: respURL, statusCode: http?.statusCode)
            onPadStateChanged?()
        } else {
            diagnosticsTracker.recordSubframeResponse(url: respURL, statusCode: http?.statusCode)
            onPadStateChanged?()
        }

        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let token = navigation.map { ObjectIdentifier($0) }
        _ = diagnosticsTracker.didStartProvisionalNavigation(token: token, currentURL: webView.url)
        onPadStateChanged?()
    }

    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        let token = navigation.map { ObjectIdentifier($0) }
        diagnosticsTracker.didReceiveServerRedirect(token: token, redirectedURL: webView.url)
        onPadStateChanged?()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let token = navigation.map { ObjectIdentifier($0) }
        if diagnosticsTracker.didCommit(token: token, committedURL: webView.url) {
            onPadStateChanged?()
        }
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        recordNavigationFailure(navigation: navigation, error: error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        recordNavigationFailure(navigation: navigation, error: error)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        handleWebContentProcessTermination()
    }

    private func recordNavigationFailure(navigation: WKNavigation?, error: any Error) {
        let nsError = error as NSError
        let token = navigation.map { ObjectIdentifier($0) }
        let recorded = diagnosticsTracker.recordNavigationFailure(
            token: token,
            domain: nsError.domain,
            code: nsError.code,
            localizedDescription: nsError.localizedDescription,
            fallbackURL: webView.url ?? initialTargetURL
        )
        if recorded {
            onPadStateChanged?()
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let token = navigation.map { ObjectIdentifier($0) }
        guard let finishedNavID = diagnosticsTracker.didFinish(token: token, finalURL: webView.url) else {
            return
        }
        hasCompletedNavigation = true
        processRecoveryState.recordSuccessfulNavigation()
        if isEffectivelyMuted {
            applyMute(true)
        }

        // 1. Ensure title is synced immediately on navigation completion (guarded by `finishedNavID`)
        if let currentTitle = webView.title, !currentTitle.isEmpty {
            emitObservedTitle(currentTitle)
        } else {
            webView.evaluateJavaScript("document.title || ''") { [weak self] res, _ in
                if let docTitle = res as? String, !docTitle.isEmpty {
                    Task { @MainActor [weak self] in
                        guard let self, self.diagnosticsTracker.currentNavigationID == finishedNavID else { return }
                        self.emitObservedTitle(docTitle)
                    }
                }
            }
        }

        // 2. Passive, strictly read-only inspection scoped to `finishedNavID` so late callbacks cannot poison newer loads.
        Task { @MainActor [weak self] in
            await self?.refreshPassiveDiagnosticsSample(includeFavicons: true, expectedNavigationID: finishedNavID)
        }
        onPadStateChanged?()
    }

    /// Passively samples `navigator.userAgent` and main-frame iframe/resource metadata without altering the page
    /// or touching cross-origin iframe contents. Guarded by `expectedNavigationID` against stale overwrites.
    public func refreshPassiveDiagnosticsSample(
        includeFavicons: Bool = false,
        expectedNavigationID: UInt64? = nil
    ) async {
        let targetNavID = expectedNavigationID ?? diagnosticsTracker.currentNavigationID
        let sampleStartedAt = Date()
        let pageURL = webView.url ?? initialTargetURL

        let passivePostLoadJS = """
        (function() {
            var navUA = (typeof navigator !== "undefined" && navigator.userAgent) ? String(navigator.userAgent) : "";
            var links = \(includeFavicons ? """
            Array.from(document.querySelectorAll("link[rel]")).filter(function(el) {
                var r = (el.getAttribute("rel") || "").toLowerCase();
                return r.indexOf("icon") !== -1;
            }).map(function(el) {
                return {
                    href: el.href || el.getAttribute("href") || "",
                    rel: el.getAttribute("rel") || "icon",
                    sizes: el.getAttribute("sizes") || "",
                    mimeType: el.getAttribute("type") || ""
                };
            })
            """ : "[]");
            var allFrames = Array.from(document.querySelectorAll("iframe"));
            var frameSrcs = [];
            var verifTotal = 0;
            var verifSized = 0;
            var verifCollapsed = 0;
            for (var i = 0; i < allFrames.length; i++) {
                var f = allFrames[i];
                var rawSrc = f.getAttribute("src") || "";
                if (rawSrc && frameSrcs.length < 6) {
                    try {
                        frameSrcs.push(new URL(rawSrc, document.baseURI).href);
                    } catch (_) {}
                }
                var hint = (rawSrc + " " + (f.getAttribute("title") || "")).toLowerCase();
                var isVerif = hint.indexOf("recaptcha") !== -1 || hint.indexOf("challenge") !== -1 || hint.indexOf("hcaptcha") !== -1 || hint.indexOf("turnstile") !== -1;
                if (isVerif) {
                    verifTotal += 1;
                    var rect = f.getBoundingClientRect();
                    var cs = window.getComputedStyle ? window.getComputedStyle(f) : null;
                    var hiddenStyle = cs && (cs.display === "none" || cs.visibility === "hidden");
                    if (!hiddenStyle && rect.width >= 10 && rect.height >= 10) {
                        verifSized += 1;
                    } else {
                        verifCollapsed += 1;
                    }
                }
            }
            var brokenImgs = Array.from(document.querySelectorAll("img")).filter(function(img) {
                return img.complete && img.naturalWidth === 0 && !!(img.getAttribute("src") || "");
            }).length;
            return JSON.stringify({
                navigatorUA: navUA,
                icons: links,
                totalIframes: allFrames.length,
                verifTotal: verifTotal,
                verifSized: verifSized,
                verifCollapsed: verifCollapsed,
                brokenImages: brokenImgs,
                frameHrefs: frameSrcs
            });
        })()
        """

        let evalOutcome: Result<String?, any Error> = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(passivePostLoadJS) { result, error in
                if let error {
                    continuation.resume(returning: .failure(error))
                } else {
                    continuation.resume(returning: .success(result as? String))
                }
            }
        }

        // Generation guard: discard late JS completion if a newer navigation has started on this pad!
        guard targetNavID == diagnosticsTracker.currentNavigationID else { return }

        let elapsedMs = max(0, Int((Date().timeIntervalSince(sampleStartedAt) * 1000.0).rounded()))

        switch evalOutcome {
        case .failure(let error):
            let nsErr = error as NSError
            let sanitized = SiteCompatibilityInspector.sanitizeNavigationError(
                domain: nsErr.domain,
                code: nsErr.code,
                localizedDescription: nsErr.localizedDescription
            )
            _ = diagnosticsTracker.applyPassiveSample(
                forNavigationID: targetNavID,
                currentURL: webView.url ?? pageURL,
                sampledUA: .unavailable(reason: sanitized),
                iframeSummary: diagnosticsTracker.iframeDiagnostics,
                jsEvaluationErrorDetail: "\(nsErr.domain) (\(nsErr.code))"
            )
            onPadStateChanged?()

        case .success(let rawString):
            guard let jsonStr = rawString,
                  let data = jsonStr.data(using: .utf8),
                  let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                _ = diagnosticsTracker.applyPassiveSample(
                    forNavigationID: targetNavID,
                    currentURL: webView.url ?? pageURL,
                    sampledUA: .unavailable(reason: "unexpected evaluation payload"),
                    iframeSummary: diagnosticsTracker.iframeDiagnostics
                )
                onPadStateChanged?()
                return
            }

            let sampledUA: SampledNavigatorUADiagnostic
            if let navUA = SiteCompatibilityInspector.nonEmptyTrimmed(dict["navigatorUA"] as? String) {
                sampledUA = .measured(navUA, elapsedMilliseconds: elapsedMs)
            } else {
                sampledUA = .unavailable(reason: "navigator.userAgent returned empty string")
            }

            if includeFavicons, let iconDicts = dict["icons"] as? [[String: Any]] {
                let rawLinks = iconDicts.map { item in
                    RawFaviconLink(
                        href: (item["href"] as? String) ?? "",
                        rel: (item["rel"] as? String) ?? "icon",
                        sizes: (item["sizes"] as? String) ?? "",
                        mimeType: (item["mimeType"] as? String) ?? ""
                    )
                }
                let ranked = FaviconCandidateSelector.rankCandidates(from: rawLinks, pageURL: webView.url ?? pageURL)
                if let best = ranked.first {
                    onFaviconDetected?(best.url)
                }
                onFaviconCandidatesDetected?(ranked)
            }

            let rawHrefs = (dict["frameHrefs"] as? [String]) ?? []
            var uniqueOrigins: [String] = []
            for href in rawHrefs {
                if let parsed = URL(string: href) {
                    let sanitized = SiteCompatibilityInspector.sanitizedOrigin(for: parsed)
                    if !uniqueOrigins.contains(sanitized) {
                        uniqueOrigins.append(sanitized)
                    }
                }
            }

            let iframeSummary = PassiveIframeDiagnosticSummary(
                sampled: true,
                totalIframeCount: (dict["totalIframes"] as? Int) ?? 0,
                verificationIframeCount: (dict["verifTotal"] as? Int) ?? 0,
                sizedVerificationIframeCount: (dict["verifSized"] as? Int) ?? 0,
                collapsedVerificationIframeCount: (dict["verifCollapsed"] as? Int) ?? 0,
                brokenImageCount: (dict["brokenImages"] as? Int) ?? 0,
                observedIframeOrigins: uniqueOrigins
            )

            _ = diagnosticsTracker.applyPassiveSample(
                forNavigationID: targetNavID,
                currentURL: webView.url ?? pageURL,
                sampledUA: sampledUA,
                iframeSummary: iframeSummary
            )
            onPadStateChanged?()
        }
    }

    // MARK: - WKDownloadDelegate (`~/Downloads`)

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping @MainActor (URL?) -> Void
    ) {
        let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)

        let safeName = suggestedFilename.isEmpty ? "download" : suggestedFilename
        var candidate = downloadsDir.appendingPathComponent(safeName)
        let baseName = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var counter = 1

        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(baseName) (\(counter))" : "\(baseName) (\(counter)).\(ext)"
            candidate = downloadsDir.appendingPathComponent(numbered)
            counter += 1
        }

        lastDownloadStatus = "Downloading \(candidate.lastPathComponent)…"
        onDownloadStatusChanged?(lastDownloadStatus)
        completionHandler(candidate)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        lastDownloadStatus = "Saved to ~/Downloads"
        onDownloadStatusChanged?(lastDownloadStatus)
    }

    public func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        lastDownloadStatus = "Download failed: \(error.localizedDescription)"
        onDownloadStatusChanged?(lastDownloadStatus)
    }

    // MARK: - WKUIDelegate (New windows, File uploads, JS alerts)

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let createHandler = onCreatePopupWebView {
            return createHandler(configuration, navigationAction, windowFeatures)
        }
        if let targetURL = navigationAction.request.url {
            onNewWindowRequested?(targetURL)
        }
        return nil
    }

    public func webViewDidClose(_ webView: WKWebView) {
        onWebViewDidClose?()
    }

    public func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        isPresentingOpenPanel = true
        panel.begin { [weak self] response in
            Task { @MainActor [weak self] in
                self?.isPresentingOpenPanel = false
                if response == .OK {
                    completionHandler(panel.urls)
                } else {
                    completionHandler(nil)
                }
            }
        }
    }

}

extension PadWebController {
    public func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Page Alert"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
        completionHandler()
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Confirm"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn)
    }

    public func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = prompt
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        input.stringValue = defaultText ?? ""
        alert.accessoryView = input
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        completionHandler(response == .alertFirstButtonReturn ? input.stringValue : nil)
    }
}
