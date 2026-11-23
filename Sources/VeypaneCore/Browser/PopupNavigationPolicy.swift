import Foundation

public enum PopupCreationDisposition: Equatable, Sendable {
    /// Host in an ephemeral child popup window created with WebKit's supplied `WKWebViewConfiguration`
    /// (preserving `window.opener`, `postMessage`, named-window reuse, `websiteDataStore`, and `webViewDidClose`
    /// without adding persistent blank/auth pads to the sidebar).
    case ephemeralPopupWindow

    /// Create a new workspace pad whose `WKWebView` is initialized with WebKit's supplied `WKWebViewConfiguration`
    /// (without issuing a duplicate manual `load`, since WebKit loads the request automatically).
    case newPadWithSuppliedConfiguration(URL)

    /// Navigate the opener pad in place and return `nil` from `createWebViewWith`.
    case navigateCurrentPadAndReturnNil(URL)

    /// Hand off to `NSWorkspace.shared.open` and return `nil` from `createWebViewWith`.
    case openExternallyAndReturnNil(URL)

    /// Block / ignore unsolicited or unsupported popup creation.
    case reject
}

public enum PopupNavigationPolicy {
    public static func isStandardWebDocumentScheme(_ scheme: String?) -> Bool {
        guard let lower = scheme?.lowercased(), !lower.isEmpty else {
            return true // nil URL on initial `window.open("", "name")` is treated as `about:blank`
        }
        switch lower {
        case "http", "https", "about", "file", "data", "blob":
            return true
        default:
            return false
        }
    }

    /// Determines how `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)` should handle a request.
    /// - Scripted `window.open` (`!isLinkActivated`), `about:blank` / empty URLs, and feature-sized dialog requests
    ///   use `.ephemeralPopupWindow` so OAuth/SSO popups keep `window.opener` and `postMessage` without creating
    ///   duplicate or blank persistent sidebar pads.
    /// - Ordinary user-clicked `<a href="..." target="_blank">` links follow `newWindowBehavior`, using the supplied
    ///   `WKWebViewConfiguration` when opening in a new pad.
    public static func classifyCreateWebView(
        requestURL: URL?,
        isLinkActivated: Bool,
        hasExplicitPopupWindowFeatures: Bool,
        newWindowBehavior: NewWindowBehavior
    ) -> PopupCreationDisposition {
        if let url = requestURL, let scheme = url.scheme?.lowercased(), !scheme.isEmpty {
            if AppBrandIdentity.isSupportedURLScheme(scheme) || !isStandardWebDocumentScheme(scheme) {
                return .openExternallyAndReturnNil(url)
            }
        }

        let isBlankOrAbout: Bool = {
            guard let url = requestURL else { return true }
            let abs = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
            if abs.isEmpty { return true }
            return url.scheme?.lowercased() == "about"
        }()

        if isBlankOrAbout || hasExplicitPopupWindowFeatures || !isLinkActivated {
            return .ephemeralPopupWindow
        }

        guard let targetURL = requestURL else {
            return .ephemeralPopupWindow
        }

        switch newWindowBehavior {
        case .openInNewPad:
            return .newPadWithSuppliedConfiguration(targetURL)
        case .openInCurrentPad:
            return .navigateCurrentPadAndReturnNil(targetURL)
        case .openInDefaultBrowser:
            return .openExternallyAndReturnNil(targetURL)
        }
    }
}
