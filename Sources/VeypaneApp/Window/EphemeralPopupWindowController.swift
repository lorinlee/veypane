import AppKit
import WebKit
import VeypaneCore

/// Retains and hosts an ephemeral child popup `WKWebView` created with WebKit's supplied `WKWebViewConfiguration`
/// (`T269`), preserving `window.opener`, `postMessage`, named-window reuse, shared `websiteDataStore`,
/// navigation-scoped diagnostics, and deterministic `webViewDidClose` / `windowWillClose` cleanup.
@MainActor
public final class EphemeralPopupWindowController: NSObject, WKNavigationDelegate, WKUIDelegate, NSWindowDelegate {
    public let id: UUID = UUID()
    public let openerPadID: UUID
    public let webView: VeypaneWebView
    public let panel: NSPanel
    public private(set) var diagnosticsTracker = NavigationDiagnosticsTracker<ObjectIdentifier>()
    public private(set) var isClosed: Bool = false
    public private(set) var focusCount: Int = 0

    public var onClosed: ((UUID) -> Void)?
    public var onCreateNestedPopup: ((WKWebViewConfiguration, WKNavigationAction, WKWindowFeatures) -> WKWebView?)?

    private var titleObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private let presentOffscreenOnly: Bool

    public init(
        openerPadID: UUID,
        suppliedConfiguration: WKWebViewConfiguration,
        windowFeatures: WKWindowFeatures,
        openerWindowLevel: NSWindow.Level = .floating,
        presentOffscreenOnly: Bool = false
    ) {
        self.openerPadID = openerPadID
        self.presentOffscreenOnly = presentOffscreenOnly

        let requestedWidth = windowFeatures.width?.doubleValue ?? 520.0
        let requestedHeight = windowFeatures.height?.doubleValue ?? 640.0
        let clampedWidth = min(max(requestedWidth, 340.0), 1040.0)
        let clampedHeight = min(max(requestedHeight, 300.0), 880.0)

        let origin: NSPoint = presentOffscreenOnly
            ? NSPoint(x: -15500, y: -15500)
            : NSPoint(x: 180, y: 160)
        let contentRect = NSRect(origin: origin, size: NSSize(width: clampedWidth, height: clampedHeight))

        let popupPanel = NSPanel(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        popupPanel.isFloatingPanel = !presentOffscreenOnly
        popupPanel.level = presentOffscreenOnly ? .normal : openerWindowLevel
        popupPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        popupPanel.hidesOnDeactivate = false
        popupPanel.isReleasedWhenClosed = false
        popupPanel.minSize = NSSize(width: 300, height: 240)
        popupPanel.title = AppBrandIdentity.productName

        // CRITICAL WKUIDelegate contract: initialize the returned WKWebView with the EXACT supplied configuration
        // and NEVER call `webView.load(...)` manually — WebKit loads the navigationAction into this view automatically.
        let childWebView = VeypaneWebView(
            frame: NSRect(origin: .zero, size: contentRect.size),
            configuration: suppliedConfiguration
        )
        childWebView.autoresizingMask = [.width, .height]

        self.panel = popupPanel
        self.webView = childWebView
        super.init()

        popupPanel.delegate = self
        childWebView.navigationDelegate = self
        childWebView.uiDelegate = self
        childWebView.allowsBackForwardNavigationGestures = true

        let container = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        container.autoresizingMask = [.width, .height]
        container.addSubview(childWebView)
        popupPanel.contentView = container

        setupWindowTitleObservations()

        if presentOffscreenOnly {
            popupPanel.alphaValue = 0.01
            popupPanel.ignoresMouseEvents = true
            popupPanel.orderBack(nil)
        } else {
            if windowFeatures.x == nil && windowFeatures.y == nil {
                popupPanel.center()
            }
            popupPanel.makeKeyAndOrderFront(nil)
        }
        _ = popupPanel.makeFirstResponder(childWebView)
    }

    private func setupWindowTitleObservations() {
        titleObservation = webView.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.syncWindowTitle()
            }
        }
        urlObservation = webView.observe(\.url, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.syncWindowTitle()
            }
        }
    }

    private func syncWindowTitle() {
        guard !isClosed else { return }
        let origin = SiteCompatibilityInspector.sanitizedOrigin(for: webView.url)
        let rawTitle = (webView.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawTitle.isEmpty && origin != "unknown" && origin != "about://" {
            panel.title = "\(rawTitle) — \(origin)"
        } else if !rawTitle.isEmpty {
            panel.title = rawTitle
        } else if origin != "unknown" && origin != "about://" {
            panel.title = origin
        } else {
            panel.title = AppBrandIdentity.productName
        }
    }

    public func focusPopupWindow() {
        guard !isClosed else { return }
        focusCount &+= 1
        if presentOffscreenOnly {
            panel.orderBack(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        _ = panel.makeFirstResponder(webView)
    }

    public func closePopup(fromWindowWillClose: Bool = false) {
        guard !isClosed else { return }
        isClosed = true

        titleObservation?.invalidate()
        titleObservation = nil
        urlObservation?.invalidate()
        urlObservation = nil

        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        webView.removeFromSuperview()

        panel.delegate = nil
        panel.orderOut(nil)
        if !fromWindowWillClose {
            panel.close()
        }

        let closedID = id
        onClosed?(closedID)
    }

    public func windowWillClose(_ notification: Notification) {
        closePopup(fromWindowWillClose: true)
    }

    // MARK: - WKUIDelegate

    public func webViewDidClose(_ webView: WKWebView) {
        closePopup(fromWindowWillClose: false)
    }

    public func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        onCreateNestedPopup?(configuration, navigationAction, windowFeatures)
    }

    // MARK: - WKNavigationDelegate (Normal scheme policy + navigation-scoped diagnostics)

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

        // Check custom/external URL schemes first
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

        // targetFrame == nil is a new-window navigation: allow without mutating this popup's main-frame tracker
        guard let targetFrame = navigationAction.targetFrame else {
            if navigationAction.shouldPerformDownload {
                decisionHandler(.download, preferences)
            } else {
                decisionHandler(.allow, preferences)
            }
            return
        }

        if navigationAction.shouldPerformDownload {
            if targetFrame.isMainFrame {
                diagnosticsTracker.recordMainFramePolicy(url: reqURL, policyDecision: "download", observedRequestUA: rawReqUA)
            } else {
                diagnosticsTracker.recordSubframePolicy(url: reqURL, policyDecision: "download")
            }
            decisionHandler(.download, preferences)
            return
        }

        if targetFrame.isMainFrame {
            diagnosticsTracker.recordMainFramePolicy(url: reqURL, policyDecision: "allow", observedRequestUA: rawReqUA)
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
        } else {
            diagnosticsTracker.recordSubframeResponse(url: respURL, statusCode: http?.statusCode)
        }
        if !navigationResponse.canShowMIMEType {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    public func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let token = navigation.map { ObjectIdentifier($0) }
        _ = diagnosticsTracker.didStartProvisionalNavigation(token: token, currentURL: webView.url)
        syncWindowTitle()
    }

    public func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        let token = navigation.map { ObjectIdentifier($0) }
        diagnosticsTracker.didReceiveServerRedirect(token: token, redirectedURL: webView.url)
        syncWindowTitle()
    }

    public func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let token = navigation.map { ObjectIdentifier($0) }
        _ = diagnosticsTracker.didCommit(token: token, committedURL: webView.url)
        syncWindowTitle()
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let token = navigation.map { ObjectIdentifier($0) }
        _ = diagnosticsTracker.didFinish(token: token, finalURL: webView.url)
        syncWindowTitle()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        let nsError = error as NSError
        _ = diagnosticsTracker.recordNavigationFailure(
            token: navigation.map { ObjectIdentifier($0) },
            domain: nsError.domain,
            code: nsError.code,
            localizedDescription: nsError.localizedDescription,
            fallbackURL: webView.url
        )
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        let nsError = error as NSError
        _ = diagnosticsTracker.recordNavigationFailure(
            token: navigation.map { ObjectIdentifier($0) },
            domain: nsError.domain,
            code: nsError.code,
            localizedDescription: nsError.localizedDescription,
            fallbackURL: webView.url
        )
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        diagnosticsTracker.recordWebContentProcessTermination(currentURL: webView.url)
    }
}
