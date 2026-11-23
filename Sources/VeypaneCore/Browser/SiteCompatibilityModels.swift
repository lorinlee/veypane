import Foundation

public enum SiteCompatibilityIssueKind: String, Codable, Equatable, Sendable {
    case none
    case verificationRouteObserved
    case subframeOrWidgetLoadIssue
    case explicitBrowserBlockEvidence
    case navigationError

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        if raw == "verificationChallenge" {
            self = .verificationRouteObserved
        } else if let parsed = SiteCompatibilityIssueKind(rawValue: raw) {
            self = parsed
        } else {
            self = .none
        }
    }
}

public enum SiteLocationCategory: String, Codable, Equatable, Sendable {
    case normal
    case googleSorryVerificationRoute
}

public enum SampledDiagnosticStatus: String, Codable, Equatable, Sendable {
    case pending
    case measured
    case unavailable
}

public struct SampledNavigatorUADiagnostic: Codable, Equatable, Sendable {
    public var status: SampledDiagnosticStatus
    public var value: String?
    public var elapsedMilliseconds: Int?
    public var detail: String?

    public init(
        status: SampledDiagnosticStatus,
        value: String? = nil,
        elapsedMilliseconds: Int? = nil,
        detail: String? = nil
    ) {
        let trimmed = SiteCompatibilityInspector.nonEmptyTrimmed(value)
        if status == .measured, let trimmed {
            self.status = .measured
            self.value = trimmed
        } else if status == .measured {
            self.status = .unavailable
            self.value = nil
        } else {
            self.status = status
            self.value = nil
        }
        self.elapsedMilliseconds = elapsedMilliseconds
        self.detail = SiteCompatibilityInspector.nonEmptyTrimmed(detail)
    }

    public static func pending(detail: String = "navigation in progress or sample not yet completed") -> Self {
        Self(status: .pending, detail: detail)
    }

    public static func measured(_ ua: String, elapsedMilliseconds: Int? = nil) -> Self {
        let timing = elapsedMilliseconds.map { "sampled in \($0) ms" } ?? "sampled via navigator.userAgent"
        return Self(status: .measured, value: ua, elapsedMilliseconds: elapsedMilliseconds, detail: timing)
    }

    public static func unavailable(reason: String) -> Self {
        Self(status: .unavailable, detail: SiteCompatibilityInspector.sanitizeText(reason))
    }

    public var formattedSummary: String {
        switch status {
        case .measured:
            let val = value ?? "unavailable"
            if let detail {
                return "\(val) (\(detail))"
            }
            return val
        case .pending:
            return "pending (\(detail ?? "awaiting page load"))"
        case .unavailable:
            return "unavailable (\(detail ?? "not sampled"))"
        }
    }
}

public enum ObservedHeaderStatus: String, Codable, Equatable, Sendable {
    case measured
    case notObserved
}

public struct ObservedHTTPHeaderUADiagnostic: Codable, Equatable, Sendable {
    public var status: ObservedHeaderStatus
    public var value: String?
    public var source: String

    public init(status: ObservedHeaderStatus, value: String? = nil, source: String) {
        let trimmed = SiteCompatibilityInspector.nonEmptyTrimmed(value)
        if status == .measured, let trimmed {
            self.status = .measured
            self.value = trimmed
        } else {
            self.status = .notObserved
            self.value = nil
        }
        self.source = SiteCompatibilityInspector.nonEmptyTrimmed(source)
            ?? "not exposed on WKNavigationAction in UI process; WebKit populates default User-Agent in NetworkProcess"
    }

    public static func notObserved(
        reason: String = "not exposed on WKNavigationAction in UI process; WebKit populates default User-Agent in NetworkProcess"
    ) -> Self {
        Self(status: .notObserved, value: nil, source: reason)
    }

    public static func measured(_ headerValue: String, source: String) -> Self {
        Self(status: .measured, value: headerValue, source: source)
    }

    public var formattedSummary: String {
        switch status {
        case .measured:
            return "\(value ?? "unknown") (observed via \(source))"
        case .notObserved:
            return "not observed (\(source))"
        }
    }
}

public struct UserAgentDiagnostics: Codable, Equatable, Sendable {
    public var configuredPreset: String
    public var usesNativeWebKitDefault: Bool
    public var configuredCustomOverride: String?
    public var applicationNameForUserAgent: String?
    public var configuredSummary: String
    public var sampledNavigatorUserAgent: SampledNavigatorUADiagnostic
    public var observedHTTPRequestUserAgent: ObservedHTTPHeaderUADiagnostic

    public init(
        configuredPreset: String,
        usesNativeWebKitDefault: Bool,
        configuredCustomOverride: String?,
        applicationNameForUserAgent: String?,
        configuredSummary: String,
        sampledNavigatorUserAgent: SampledNavigatorUADiagnostic,
        observedHTTPRequestUserAgent: ObservedHTTPHeaderUADiagnostic
    ) {
        self.configuredPreset = configuredPreset
        self.usesNativeWebKitDefault = usesNativeWebKitDefault
        self.configuredCustomOverride = SiteCompatibilityInspector.nonEmptyTrimmed(configuredCustomOverride)
        self.applicationNameForUserAgent = SiteCompatibilityInspector.nonEmptyTrimmed(applicationNameForUserAgent)
        self.configuredSummary = configuredSummary
        self.sampledNavigatorUserAgent = sampledNavigatorUserAgent
        self.observedHTTPRequestUserAgent = observedHTTPRequestUserAgent
    }

    /// Resolves User-Agent diagnostics without ever conflating `nil`/`""` `WKWebView.customUserAgent`
    /// with an empty HTTP header, and without guessing unobserved request headers.
    public static func resolve(
        preset: UserAgentPreset,
        padCustomUserAgent: String?,
        liveWebViewCustomUserAgent: String?,
        applicationNameForUserAgent: String?,
        sampledNavigatorUA: SampledNavigatorUADiagnostic,
        observedHTTPRequestUA: ObservedHTTPHeaderUADiagnostic
    ) -> UserAgentDiagnostics {
        // WebKit's `WKWebView.customUserAgent` can return `""` (empty non-nil NSString) when no override is set.
        // Both `nil` and whitespace-empty `""` mean "no customUserAgent override; native WebKit UA active".
        let liveOverride = SiteCompatibilityInspector.nonEmptyTrimmed(liveWebViewCustomUserAgent)
        let padExplicitCustom = SiteCompatibilityInspector.nonEmptyTrimmed(padCustomUserAgent)
        let presetExplicitOverride: String? = switch preset {
        case .desktopSafari, .defaultWebKit:
            nil
        case .iPhoneSafari, .iPadSafari:
            preset.resolvedUserAgent()
        case .custom:
            padExplicitCustom
        }

        let effectiveOverride = liveOverride ?? presetExplicitOverride
        let appName = SiteCompatibilityInspector.nonEmptyTrimmed(applicationNameForUserAgent)
        let usesNative = (effectiveOverride == nil)

        let summary: String
        if let effectiveOverride {
            summary = "custom override active (preset=\(preset.rawValue)): \(effectiveOverride)"
        } else if preset == .custom && padExplicitCustom == nil {
            summary = "native WebKit default (preset=custom has empty override; customUserAgent unset, applicationNameForUserAgent=\(appName ?? "none"))"
        } else {
            summary = "native WebKit default (customUserAgent unset; preset=\(preset.rawValue), applicationNameForUserAgent=\(appName ?? "none"))"
        }

        return UserAgentDiagnostics(
            configuredPreset: preset.rawValue,
            usesNativeWebKitDefault: usesNative,
            configuredCustomOverride: effectiveOverride,
            applicationNameForUserAgent: appName,
            configuredSummary: summary,
            sampledNavigatorUserAgent: sampledNavigatorUA,
            observedHTTPRequestUserAgent: observedHTTPRequestUA
        )
    }
}

public struct ExtensionScopeDiagnostic: Codable, Equatable, Sendable {
    public var name: String
    public var version: String
    public var websiteAccessScope: String

    public init(name: String, version: String, websiteAccessScope: String) {
        self.name = name
        self.version = version
        self.websiteAccessScope = websiteAccessScope
    }
}

public struct ArchivedNavigationFailureDiagnostic: Codable, Equatable, Sendable {
    public var navigationID: UInt64
    public var origin: String
    public var redirectChainOrigins: [String]
    public var sanitizedError: String
    public var recordedAtISO8601: String
    public var wasLateSupersededCallback: Bool

    public init(
        navigationID: UInt64,
        origin: String,
        redirectChainOrigins: [String] = [],
        sanitizedError: String,
        recordedAtISO8601: String,
        wasLateSupersededCallback: Bool = false
    ) {
        self.navigationID = navigationID
        self.origin = origin
        self.redirectChainOrigins = Array(redirectChainOrigins.prefix(6))
        self.sanitizedError = SiteCompatibilityInspector.sanitizeText(sanitizedError)
        self.recordedAtISO8601 = recordedAtISO8601
        self.wasLateSupersededCallback = wasLateSupersededCallback
    }
}

public struct TopLevelNavigationDiagnostic: Codable, Equatable, Sendable {
    public var navigationID: UInt64
    public var startedAtISO8601: String?
    public var redirectChainOrigins: [String]
    public var lastPolicyDecision: String
    public var lastHTTPStatusCode: Int?
    public var lastNavigationError: String?
    public var webContentProcessTerminations: Int
    public var previousNavigationFailure: ArchivedNavigationFailureDiagnostic?

    public init(
        navigationID: UInt64 = 0,
        startedAtISO8601: String? = nil,
        redirectChainOrigins: [String] = [],
        lastPolicyDecision: String = "not-recorded",
        lastHTTPStatusCode: Int? = nil,
        lastNavigationError: String? = nil,
        webContentProcessTerminations: Int = 0,
        previousNavigationFailure: ArchivedNavigationFailureDiagnostic? = nil
    ) {
        self.navigationID = navigationID
        self.startedAtISO8601 = SiteCompatibilityInspector.nonEmptyTrimmed(startedAtISO8601)
        self.redirectChainOrigins = Array(redirectChainOrigins.prefix(6))
        self.lastPolicyDecision = lastPolicyDecision
        self.lastHTTPStatusCode = lastHTTPStatusCode
        self.lastNavigationError = SiteCompatibilityInspector.nonEmptyTrimmed(lastNavigationError)
        self.webContentProcessTerminations = webContentProcessTerminations
        self.previousNavigationFailure = previousNavigationFailure
    }
}

public struct SubframeNavigationDiagnostic: Codable, Equatable, Sendable {
    public var frameOrigin: String
    public var policyDecision: String
    public var httpStatusCode: Int?
    public var errorSummary: String?

    public init(
        frameOrigin: String,
        policyDecision: String,
        httpStatusCode: Int? = nil,
        errorSummary: String? = nil
    ) {
        self.frameOrigin = frameOrigin
        self.policyDecision = policyDecision
        self.httpStatusCode = httpStatusCode
        self.errorSummary = SiteCompatibilityInspector.nonEmptyTrimmed(errorSummary)
    }
}

public struct PassiveIframeDiagnosticSummary: Codable, Equatable, Sendable {
    public var sampled: Bool
    public var totalIframeCount: Int
    public var verificationIframeCount: Int
    public var sizedVerificationIframeCount: Int
    public var collapsedVerificationIframeCount: Int
    public var brokenImageCount: Int
    public var observedIframeOrigins: [String]
    public var scopeNote: String

    public init(
        sampled: Bool = false,
        totalIframeCount: Int = 0,
        verificationIframeCount: Int = 0,
        sizedVerificationIframeCount: Int = 0,
        collapsedVerificationIframeCount: Int = 0,
        brokenImageCount: Int = 0,
        observedIframeOrigins: [String] = [],
        scopeNote: String = "Main-frame passive bounds & src-origin check only; cross-origin frame DOM/CSP internals are unreadable under Same-Origin Policy."
    ) {
        self.sampled = sampled
        self.totalIframeCount = totalIframeCount
        self.verificationIframeCount = verificationIframeCount
        self.sizedVerificationIframeCount = sizedVerificationIframeCount
        self.collapsedVerificationIframeCount = collapsedVerificationIframeCount
        self.brokenImageCount = brokenImageCount
        self.observedIframeOrigins = Array(observedIframeOrigins.prefix(6))
        self.scopeNote = scopeNote
    }
}

public struct PassiveFailureCategoryDiagnostic: Codable, Equatable, Sendable {
    public var category: String
    public var origin: String
    public var detail: String

    public init(category: String, origin: String, detail: String) {
        self.category = category
        self.origin = origin
        self.detail = SiteCompatibilityInspector.sanitizeText(detail)
    }
}

/// Safe, privacy-preserving, evidence-based site compatibility diagnostics report (Feedback A `t264u`).
/// Strictly origin-only; never includes page text, cookies, auth tokens, query strings, paths, IP literals, or cross-origin frame contents.
public struct SiteDiagnosticsReport: Codable, Equatable, Sendable {
    public static let pauseModificationsScopeStatement =
        "Pauses \(AppBrandIdentity.productName) custom CSS/JS rules, content blocker rules, and Web Notification shim for this pad only; does NOT disable loaded WKWebExtensions."

    public var appName: String
    public var bundleIdentifier: String
    public var macOSVersion: String
    public var webKitVersion: String
    public var topLevelOrigin: String
    public var locationCategory: SiteLocationCategory
    public var userAgent: UserAgentDiagnostics
    public var javaScriptEnabled: Bool
    public var customModificationsPaused: Bool
    public var pauseModificationsScope: String
    public var contentBlockerEnabled: Bool
    public var blockedDomainCount: Int
    public var matchingInjectionRuleCount: Int
    public var loadedExtensions: [ExtensionScopeDiagnostic]
    public var topLevelNavigation: TopLevelNavigationDiagnostic
    public var subframeObservations: [SubframeNavigationDiagnostic]
    public var iframeDiagnostics: PassiveIframeDiagnosticSummary
    public var failureCategories: [PassiveFailureCategoryDiagnostic]
    public var issueKind: SiteCompatibilityIssueKind
    public var issueSummary: String?

    public var lastNavigationError: String? {
        topLevelNavigation.lastNavigationError
    }

    public init(
        appName: String = AppBrandIdentity.productName,
        bundleIdentifier: String = AppBrandIdentity.bundleIdentifier,
        macOSVersion: String,
        webKitVersion: String,
        topLevelOrigin: String,
        locationCategory: SiteLocationCategory = .normal,
        userAgent: UserAgentDiagnostics,
        javaScriptEnabled: Bool,
        customModificationsPaused: Bool,
        pauseModificationsScope: String = SiteDiagnosticsReport.pauseModificationsScopeStatement,
        contentBlockerEnabled: Bool,
        blockedDomainCount: Int,
        matchingInjectionRuleCount: Int,
        loadedExtensions: [ExtensionScopeDiagnostic],
        topLevelNavigation: TopLevelNavigationDiagnostic = TopLevelNavigationDiagnostic(),
        subframeObservations: [SubframeNavigationDiagnostic] = [],
        iframeDiagnostics: PassiveIframeDiagnosticSummary = PassiveIframeDiagnosticSummary(),
        failureCategories: [PassiveFailureCategoryDiagnostic] = [],
        issueKind: SiteCompatibilityIssueKind = .none,
        issueSummary: String? = nil
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.macOSVersion = macOSVersion
        self.webKitVersion = webKitVersion
        self.topLevelOrigin = topLevelOrigin
        self.locationCategory = locationCategory
        self.userAgent = userAgent
        self.javaScriptEnabled = javaScriptEnabled
        self.customModificationsPaused = customModificationsPaused
        self.pauseModificationsScope = pauseModificationsScope
        self.contentBlockerEnabled = contentBlockerEnabled
        self.blockedDomainCount = blockedDomainCount
        self.matchingInjectionRuleCount = matchingInjectionRuleCount
        self.loadedExtensions = loadedExtensions
        self.topLevelNavigation = topLevelNavigation
        self.subframeObservations = Array(subframeObservations.prefix(8))
        self.iframeDiagnostics = iframeDiagnostics
        self.failureCategories = Array(failureCategories.prefix(8))
        self.issueKind = issueKind
        self.issueSummary = SiteCompatibilityInspector.nonEmptyTrimmed(issueSummary)
    }

    public func formattedPlainText() -> String {
        var lines: [String] = [
            "\(appName) Site Compatibility Diagnostics",
            "Bundle ID: \(bundleIdentifier)",
            "macOS: \(macOSVersion)",
            "WebKit: \(webKitVersion)",
            "Origin: \(topLevelOrigin)",
            "Location Category: \(locationCategory.rawValue)",
            "Configured User-Agent: \(userAgent.configuredSummary)",
            "Sampled navigator.userAgent: \(userAgent.sampledNavigatorUserAgent.formattedSummary)",
            "Observed HTTP User-Agent Header: \(userAgent.observedHTTPRequestUserAgent.formattedSummary)",
            "JavaScript Enabled: \(javaScriptEnabled)",
            "Custom Page Modifications Paused: \(customModificationsPaused) (\(pauseModificationsScope))",
            "Content Blocker Enabled: \(contentBlockerEnabled) (blocked domains: \(blockedDomainCount))",
            "Matching CSS/JS Rules: \(matchingInjectionRuleCount)"
        ]

        if loadedExtensions.isEmpty {
            lines.append("Loaded Extensions: none")
        } else {
            let extSummary = loadedExtensions
                .map { "\($0.name) v\($0.version) [\($0.websiteAccessScope)]" }
                .joined(separator: ", ")
            lines.append("Loaded Extensions (\(loadedExtensions.count)): \(extSummary)")
        }

        let httpStatusText = topLevelNavigation.lastHTTPStatusCode.map(String.init) ?? "not-observed"
        let startedText = topLevelNavigation.startedAtISO8601 ?? "not-recorded"
        lines.append(
            "Top-Level Navigation: navID=\(topLevelNavigation.navigationID), startedAt=\(startedText), policy=\(topLevelNavigation.lastPolicyDecision), httpStatus=\(httpStatusText), contentProcessTerminations=\(topLevelNavigation.webContentProcessTerminations)"
        )
        if !topLevelNavigation.redirectChainOrigins.isEmpty {
            lines.append("Navigation Origin Chain: \(topLevelNavigation.redirectChainOrigins.joined(separator: " -> "))")
        }
        if let navErr = topLevelNavigation.lastNavigationError, !navErr.isEmpty {
            lines.append("Current Navigation Error: \(navErr)")
        } else {
            lines.append("Current Navigation Error: none")
        }
        if let prev = topLevelNavigation.previousNavigationFailure {
            let lateNote = prev.wasLateSupersededCallback ? ", lateSupersededCallback=true" : ""
            lines.append(
                "Previous Navigation Failure (Archived): navID=\(prev.navigationID), origin=\(prev.origin), at=\(prev.recordedAtISO8601)\(lateNote) — \(prev.sanitizedError)"
            )
        } else {
            lines.append("Previous Navigation Failure (Archived): none")
        }

        if subframeObservations.isEmpty {
            lines.append("Subframe Navigations Observed: none")
        } else {
            let subText = subframeObservations.map { sub in
                let st = sub.httpStatusCode.map { "http=\($0)" } ?? "http=n/a"
                let err = sub.errorSummary.map { ", err=\($0)" } ?? ""
                return "\(sub.frameOrigin) [policy=\(sub.policyDecision), \(st)\(err)]"
            }.joined(separator: "; ")
            lines.append("Subframe Navigations Observed (\(subframeObservations.count)): \(subText)")
        }

        if iframeDiagnostics.sampled {
            let originsText = iframeDiagnostics.observedIframeOrigins.isEmpty
                ? "none"
                : iframeDiagnostics.observedIframeOrigins.joined(separator: ", ")
            lines.append(
                "Passive Iframe Summary: total=\(iframeDiagnostics.totalIframeCount), verificationFrames=\(iframeDiagnostics.verificationIframeCount) (sized=\(iframeDiagnostics.sizedVerificationIframeCount), collapsed=\(iframeDiagnostics.collapsedVerificationIframeCount)), brokenImages=\(iframeDiagnostics.brokenImageCount), srcOrigins=[\(originsText)]"
            )
            lines.append("Iframe Scope Note: \(iframeDiagnostics.scopeNote)")
        } else {
            lines.append("Passive Iframe Summary: not yet sampled")
        }

        if failureCategories.isEmpty {
            lines.append("Observed Failure Categories: none")
        } else {
            let failText = failureCategories
                .map { "\($0.category)@\($0.origin): \($0.detail)" }
                .joined(separator: "; ")
            lines.append("Observed Failure Categories (\(failureCategories.count)): \(failText)")
        }

        lines.append("Diagnostic Status: \(issueKind.rawValue)")
        if let issueSummary, !issueSummary.isEmpty {
            lines.append("Observation Summary: \(issueSummary)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum SiteCompatibilityInspector {
    public static func nonEmptyTrimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public static func isIPLiteralHost(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if trimmed.contains(":") {
            return true // IPv6 literal
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4 && parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return true // IPv4 literal
        }
        return false
    }

    /// Extracts strictly `scheme://host[:port]` with NO path, query parameters, fragments, credentials, or raw IP literals.
    public static func sanitizedOrigin(for url: URL?) -> String {
        guard let url, let scheme = url.scheme?.lowercased() else {
            return "unknown"
        }
        if scheme == "about" || scheme == "data" || scheme == "file" || scheme == "blob" {
            return "\(scheme)://"
        }
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            return "\(scheme)://"
        }
        if isIPLiteralHost(host) {
            return "\(scheme)://<ip-redacted>"
        }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    /// Classifies top-level URL route category ONLY, without inferring why the remote server routed there.
    public static func classifyLocation(url: URL?) -> SiteLocationCategory {
        guard let url else { return .normal }
        let host = (url.host ?? "").lowercased()
        let path = url.path.lowercased()
        if (host == "www.google.com" || host.hasSuffix(".google.com")) && path.hasPrefix("/sorry") {
            return .googleSorryVerificationRoute
        }
        return .normal
    }

    /// Evaluates factual, non-speculative observation status from route, HTTP status, subframe observations, and passive iframe bounds.
    /// NEVER infers that Google or a verification service rejected `WKWebView` or browser extensions solely from `/sorry`.
    public static func evaluatePassiveObservation(
        url: URL?,
        topLevelHTTPStatus: Int? = nil,
        iframeSummary: PassiveIframeDiagnosticSummary = PassiveIframeDiagnosticSummary(),
        subframeObservations: [SubframeNavigationDiagnostic] = []
    ) -> (issueKind: SiteCompatibilityIssueKind, locationCategory: SiteLocationCategory, summary: String?) {
        let location = classifyLocation(url: url)
        let origin = sanitizedOrigin(for: url)

        let subframeFailureObserved = subframeObservations.contains { sub in
            sub.policyDecision == "cancel"
                || (sub.httpStatusCode ?? 0) >= 400
                || sub.errorSummary != nil
        }

        if iframeSummary.verificationIframeCount > 0 &&
            (iframeSummary.sizedVerificationIframeCount == 0 || subframeFailureObserved) {
            var details: [String] = []
            if iframeSummary.sizedVerificationIframeCount == 0 {
                details.append("verification iframe bounding box remained <10x10 pt")
            }
            if subframeFailureObserved {
                details.append("subframe HTTP/navigation error observed")
            }
            let detailStr = details.joined(separator: "; ")
            return (
                .subframeOrWidgetLoadIssue,
                location,
                "Verification iframe issue observed on \(origin) (\(detailStr)). Cross-origin frame internals are unreadable under SOP; see Diagnostics or open in your default browser."
            )
        }

        if location == .googleSorryVerificationRoute {
            let statusPart = topLevelHTTPStatus.map { " (HTTP \($0))" } ?? ""
            return (
                .verificationRouteObserved,
                location,
                "Verification route (/sorry) observed on \(origin)\(statusPart). Route location alone does not indicate WKWebView or extension rejection."
            )
        }

        if let status = topLevelHTTPStatus, status == 429 || status == 503 {
            return (
                .verificationRouteObserved,
                location,
                "HTTP \(status) rate-limit or verification status received from \(origin)."
            )
        }

        return (.none, location, nil)
    }

    /// Backward-compatible helper retained for callers/tests; strictly factual and non-speculative.
    public static func detectPassiveVerificationGate(
        url: URL?,
        hasChallengeIframe: Bool,
        challengeIframeLookedBlankOrBlocked: Bool
    ) -> (detected: Bool, summary: String?) {
        let iframeSummary = PassiveIframeDiagnosticSummary(
            sampled: true,
            totalIframeCount: hasChallengeIframe ? 1 : 0,
            verificationIframeCount: hasChallengeIframe ? 1 : 0,
            sizedVerificationIframeCount: (hasChallengeIframe && !challengeIframeLookedBlankOrBlocked) ? 1 : 0,
            collapsedVerificationIframeCount: (hasChallengeIframe && challengeIframeLookedBlankOrBlocked) ? 1 : 0
        )
        let evaluated = evaluatePassiveObservation(url: url, iframeSummary: iframeSummary)
        return (evaluated.issueKind != .none, evaluated.summary)
    }

    public static func sanitizeText(_ raw: String) -> String {
        var out = raw
        out = out.replacingOccurrences(
            of: #"https?://[^\s"'),]+"#,
            with: "<redacted-url>",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"file://[^\s"'),]+"#,
            with: "<redacted-file-url>",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"\[[0-9a-fA-F:]+\](?::\d+)?"#,
            with: "<redacted-ip>",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"#,
            with: "<redacted-ip>",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"(?i)\b(token|key|auth|session|cookie|sig|password|secret|bearer)\s*[=:]\s*[^\s&"'),]+"#,
            with: "$1=<redacted>",
            options: .regularExpression
        )
        let collapsed = out.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count > 200 {
            return String(collapsed.prefix(200)) + "…"
        }
        return collapsed
    }

    public static func sanitizeNavigationError(domain: String, code: Int, localizedDescription: String) -> String {
        let redacted = sanitizeText(localizedDescription)
        return "\(domain) (\(code)): \(redacted)"
    }

    public static func iso8601Timestamp(_ date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

/// Per-pad, navigation-generation-scoped diagnostics state machine (`B t268u`).
/// Separates current navigation observations from archived prior/superseded navigation errors,
/// tracks bounded origin-only redirect chains, and rejects stale async/failure callbacks from older navigations.
public struct NavigationDiagnosticsTracker<Token: Hashable & Sendable>: Sendable {
    public enum Phase: String, Codable, Equatable, Sendable {
        case idle
        case pendingIntent
        case provisional
        case committed
        case finished
        case failed
    }

    private struct StagedMainAction: Sendable {
        var origin: String
        var policyDecision: String
        var observedRequestUA: String?
        var timestamp: Date
    }

    public private(set) var currentNavigationID: UInt64 = 0
    public private(set) var phase: Phase = .idle
    public private(set) var startedAtISO8601: String?
    public private(set) var redirectChainOrigins: [String] = []
    public private(set) var lastPolicyDecision: String = "not-recorded"
    public private(set) var lastHTTPStatusCode: Int?
    public private(set) var currentNavigationError: String?
    public private(set) var webContentProcessTerminations: Int = 0
    public private(set) var previousNavigationFailure: ArchivedNavigationFailureDiagnostic?

    public private(set) var sampledNavigatorUserAgent: SampledNavigatorUADiagnostic = .pending()
    public private(set) var observedHTTPRequestUserAgent: ObservedHTTPHeaderUADiagnostic = .notObserved()
    public private(set) var subframeObservations: [SubframeNavigationDiagnostic] = []
    public private(set) var iframeDiagnostics = PassiveIframeDiagnosticSummary()
    public private(set) var failureCategories: [PassiveFailureCategoryDiagnostic] = []
    public private(set) var issueKind: SiteCompatibilityIssueKind = .none
    public private(set) var issueSummary: String?

    private var awaitingProvisionalTokenForCurrentID: Bool = false
    private var stagedMainAction: StagedMainAction?
    private var tokenToNavigationID: [Token: UInt64] = [:]
    private var navOriginsByID: [UInt64: [String]] = [:]

    public init() {}

    private mutating func archiveCurrentErrorIfPresent(now: Date) {
        guard let existingErr = currentNavigationError, currentNavigationID > 0 else { return }
        let origin = redirectChainOrigins.last ?? "unknown"
        previousNavigationFailure = ArchivedNavigationFailureDiagnostic(
            navigationID: currentNavigationID,
            origin: origin,
            redirectChainOrigins: redirectChainOrigins,
            sanitizedError: existingErr,
            recordedAtISO8601: SiteCompatibilityInspector.iso8601Timestamp(now),
            wasLateSupersededCallback: false
        )
    }

    private mutating func resetCurrentNavigationFields(initialOrigin: String?, startedAt: Date) {
        startedAtISO8601 = SiteCompatibilityInspector.iso8601Timestamp(startedAt)
        redirectChainOrigins.removeAll(keepingCapacity: true)
        if let initialOrigin, initialOrigin != "unknown" {
            redirectChainOrigins.append(initialOrigin)
        }
        navOriginsByID[currentNavigationID] = redirectChainOrigins
        pruneHistoryMaps()

        lastPolicyDecision = "not-recorded"
        lastHTTPStatusCode = nil
        currentNavigationError = nil
        sampledNavigatorUserAgent = .pending(detail: "navigation in progress")
        observedHTTPRequestUserAgent = .notObserved()
        subframeObservations.removeAll(keepingCapacity: true)
        iframeDiagnostics = PassiveIframeDiagnosticSummary()
        failureCategories.removeAll(keepingCapacity: true)
        issueKind = .none
        issueSummary = nil
    }

    private mutating func pruneHistoryMaps() {
        guard currentNavigationID > 16 else { return }
        let minKeep = currentNavigationID - 16
        tokenToNavigationID = tokenToNavigationID.filter { $0.value >= minKeep }
        navOriginsByID = navOriginsByID.filter { $0.key >= minKeep }
    }

    private mutating func appendRedirectOrigin(_ origin: String, for navID: UInt64) {
        guard origin != "unknown" else { return }
        if navID == currentNavigationID {
            if redirectChainOrigins.last != origin && redirectChainOrigins.count < 6 {
                redirectChainOrigins.append(origin)
            }
            navOriginsByID[navID] = redirectChainOrigins
        } else {
            var chain = navOriginsByID[navID] ?? []
            if chain.last != origin && chain.count < 6 {
                chain.append(origin)
                navOriginsByID[navID] = chain
            }
        }
    }

    public mutating func appendFailureCategory(category: String, origin: String, detail: String) {
        guard failureCategories.count < 8 else { return }
        let entry = PassiveFailureCategoryDiagnostic(category: category, origin: origin, detail: detail)
        if !failureCategories.contains(entry) {
            failureCategories.append(entry)
        }
    }

    /// Called when the app explicitly issues `load`, `reload`, or `applyUserAgent` on this pad,
    /// immediately advancing `currentNavigationID` so any abort/timeout callback from a superseded load
    /// is recognized as `< currentNavigationID` even before `didStartProvisionalNavigation` fires.
    @discardableResult
    public mutating func prepareExplicitMainNavigation(targetURL: URL?, now: Date = Date()) -> UInt64 {
        archiveCurrentErrorIfPresent(now: now)
        currentNavigationID &+= 1
        awaitingProvisionalTokenForCurrentID = true
        stagedMainAction = nil
        phase = .pendingIntent
        let origin = targetURL.map { SiteCompatibilityInspector.sanitizedOrigin(for: $0) }
        resetCurrentNavigationFields(initialOrigin: origin, startedAt: now)
        return currentNavigationID
    }

    /// Records `decidePolicyFor navigationAction` on the main frame.
    /// Does not blindly wipe redirect history during provisional redirects; stages metadata until
    /// WebKit confirms either `didReceiveServerRedirect` (same token) or `didStartProvisionalNavigation` (new token).
    public mutating func recordMainFramePolicy(
        url: URL?,
        policyDecision: String,
        observedRequestUA: String?,
        isDefinitelyNewNavigation: Bool = false,
        now: Date = Date()
    ) {
        let origin = SiteCompatibilityInspector.sanitizedOrigin(for: url)
        let cleanUA = SiteCompatibilityInspector.nonEmptyTrimmed(observedRequestUA)

        if policyDecision == "cancel" {
            // Do not wipe a healthy committed page's diagnostics when an external scheme/popup link is cancelled.
            if phase == .idle || phase == .pendingIntent {
                if currentNavigationID == 0 {
                    currentNavigationID = 1
                }
                lastPolicyDecision = "cancel"
                appendRedirectOrigin(origin, for: currentNavigationID)
            }
            return
        }

        if awaitingProvisionalTokenForCurrentID {
            lastPolicyDecision = policyDecision
            appendRedirectOrigin(origin, for: currentNavigationID)
            if let cleanUA {
                observedHTTPRequestUserAgent = .measured(cleanUA, source: "WKNavigationAction.request")
            }
        }

        stagedMainAction = StagedMainAction(
            origin: origin,
            policyDecision: policyDecision,
            observedRequestUA: cleanUA,
            timestamp: now
        )
    }

    @discardableResult
    public mutating func didStartProvisionalNavigation(
        token: Token?,
        currentURL: URL?,
        now: Date = Date()
    ) -> UInt64 {
        if !awaitingProvisionalTokenForCurrentID {
            archiveCurrentErrorIfPresent(now: now)
            currentNavigationID &+= 1
            let startOrigin = stagedMainAction?.origin ?? SiteCompatibilityInspector.sanitizedOrigin(for: currentURL)
            resetCurrentNavigationFields(
                initialOrigin: startOrigin,
                startedAt: stagedMainAction?.timestamp ?? now
            )
        }

        awaitingProvisionalTokenForCurrentID = false
        phase = .provisional
        if let token {
            // Always bind fresh provisional navigation token (never early-returning a recycled pointer address).
            tokenToNavigationID[token] = currentNavigationID
        }

        if let staged = stagedMainAction {
            lastPolicyDecision = staged.policyDecision
            appendRedirectOrigin(staged.origin, for: currentNavigationID)
            if let ua = staged.observedRequestUA {
                observedHTTPRequestUserAgent = .measured(ua, source: "WKNavigationAction.request")
            }
            stagedMainAction = nil
        } else if let currentURL {
            appendRedirectOrigin(SiteCompatibilityInspector.sanitizedOrigin(for: currentURL), for: currentNavigationID)
        }

        pruneHistoryMaps()
        return currentNavigationID
    }

    public mutating func didReceiveServerRedirect(token: Token?, redirectedURL: URL?) {
        let navID = token.flatMap { tokenToNavigationID[$0] } ?? currentNavigationID
        let origin = stagedMainAction?.origin ?? SiteCompatibilityInspector.sanitizedOrigin(for: redirectedURL)
        appendRedirectOrigin(origin, for: navID)
        guard navID == currentNavigationID else {
            stagedMainAction = nil
            return
        }
        if let staged = stagedMainAction {
            lastPolicyDecision = staged.policyDecision
            if let ua = staged.observedRequestUA {
                observedHTTPRequestUserAgent = .measured(ua, source: "WKNavigationAction.request")
            }
            stagedMainAction = nil
        }
    }

    public mutating func recordMainFrameResponse(url: URL?, statusCode: Int?) {
        let respOrigin = SiteCompatibilityInspector.sanitizedOrigin(for: url)
        appendRedirectOrigin(respOrigin, for: currentNavigationID)
        lastHTTPStatusCode = statusCode
        if let code = statusCode {
            if code >= 400 {
                appendFailureCategory(category: "mainFrameHTTPError", origin: respOrigin, detail: "HTTP \(code)")
            }
            if code == 429 || code == 503 {
                let evaluated = SiteCompatibilityInspector.evaluatePassiveObservation(
                    url: url,
                    topLevelHTTPStatus: code,
                    iframeSummary: iframeDiagnostics,
                    subframeObservations: subframeObservations
                )
                issueKind = evaluated.issueKind
                issueSummary = evaluated.summary
            }
        }
    }

    public mutating func recordSubframePolicy(url: URL?, policyDecision: String) {
        let origin = SiteCompatibilityInspector.sanitizedOrigin(for: url)
        if subframeObservations.count < 8 {
            subframeObservations.append(SubframeNavigationDiagnostic(frameOrigin: origin, policyDecision: policyDecision))
        }
        if policyDecision == "cancel" {
            appendFailureCategory(category: "subframeNavigationBlocked", origin: origin, detail: "policy=cancel")
        }
    }

    public mutating func recordSubframeResponse(url: URL?, statusCode: Int?) {
        let origin = SiteCompatibilityInspector.sanitizedOrigin(for: url)
        if let idx = subframeObservations.lastIndex(where: { $0.frameOrigin == origin && $0.httpStatusCode == nil }) {
            subframeObservations[idx].httpStatusCode = statusCode
        } else if subframeObservations.count < 8 {
            subframeObservations.append(
                SubframeNavigationDiagnostic(frameOrigin: origin, policyDecision: "allow", httpStatusCode: statusCode)
            )
        }
        if let code = statusCode, code >= 400 {
            appendFailureCategory(category: "subframeHTTPError", origin: origin, detail: "HTTP \(code)")
        }
    }

    @discardableResult
    public mutating func didCommit(token: Token?, committedURL: URL?) -> Bool {
        let navID = token.flatMap { tokenToNavigationID[$0] } ?? currentNavigationID
        guard navID == currentNavigationID else { return false }
        phase = .committed
        currentNavigationError = nil
        if issueKind == .navigationError {
            issueKind = .none
            issueSummary = nil
        }
        if let committedURL {
            appendRedirectOrigin(SiteCompatibilityInspector.sanitizedOrigin(for: committedURL), for: navID)
        }
        return true
    }

    public mutating func didFinish(token: Token?, finalURL: URL?) -> UInt64? {
        let navID = token.flatMap { tokenToNavigationID[$0] } ?? currentNavigationID
        if let token {
            tokenToNavigationID.removeValue(forKey: token)
        }
        guard navID == currentNavigationID else { return nil }
        phase = .finished
        currentNavigationError = nil
        if issueKind == .navigationError {
            issueKind = .none
            issueSummary = nil
        }
        if let finalURL {
            appendRedirectOrigin(SiteCompatibilityInspector.sanitizedOrigin(for: finalURL), for: navID)
        }
        return navID
    }

    @discardableResult
    public mutating func applyPassiveSample(
        forNavigationID expectedNavID: UInt64,
        currentURL: URL?,
        sampledUA: SampledNavigatorUADiagnostic,
        iframeSummary: PassiveIframeDiagnosticSummary,
        jsEvaluationErrorDetail: String? = nil
    ) -> Bool {
        guard expectedNavID == currentNavigationID else { return false }
        let pageOrigin = SiteCompatibilityInspector.sanitizedOrigin(for: currentURL)
        sampledNavigatorUserAgent = sampledUA
        iframeDiagnostics = iframeSummary

        if let jsErr = jsEvaluationErrorDetail {
            appendFailureCategory(category: "jsEvaluationError", origin: pageOrigin, detail: jsErr)
        }
        if iframeSummary.collapsedVerificationIframeCount > 0 && iframeSummary.sizedVerificationIframeCount == 0 {
            appendFailureCategory(
                category: "collapsedIframeBounds",
                origin: pageOrigin,
                detail: "collapsedVerificationIframes=\(iframeSummary.collapsedVerificationIframeCount)"
            )
        }
        if iframeSummary.brokenImageCount > 0 {
            appendFailureCategory(
                category: "brokenImageResource",
                origin: pageOrigin,
                detail: "brokenImages=\(iframeSummary.brokenImageCount)"
            )
        }

        if currentNavigationError == nil {
            let evaluated = SiteCompatibilityInspector.evaluatePassiveObservation(
                url: currentURL,
                topLevelHTTPStatus: lastHTTPStatusCode,
                iframeSummary: iframeSummary,
                subframeObservations: subframeObservations
            )
            issueKind = evaluated.issueKind
            issueSummary = evaluated.summary
        }
        return true
    }

    /// Records a main-frame navigation failure (`didFail` / `didFailProvisionalNavigation`).
    /// Returns `false` for benign cancellations (`-999` / WebKit `102`).
    /// If `token` belongs to a superseded older navigation (`failedNavID < currentNavigationID`),
    /// archives the failure in `previousNavigationFailure` WITHOUT poisoning the current page's state!
    @discardableResult
    public mutating func recordNavigationFailure(
        token: Token?,
        domain: String,
        code: Int,
        localizedDescription: String,
        fallbackURL: URL?,
        now: Date = Date()
    ) -> Bool {
        if domain == NSURLErrorDomain && code == NSURLErrorCancelled {
            return false
        }
        if domain == "WebKitErrorDomain" && code == 102 {
            return false
        }

        let sanitized = SiteCompatibilityInspector.sanitizeNavigationError(
            domain: domain,
            code: code,
            localizedDescription: localizedDescription
        )
        let resolvedID: UInt64
        if let token, let mapped = tokenToNavigationID.removeValue(forKey: token) {
            resolvedID = mapped
        } else {
            if currentNavigationID == 0 {
                currentNavigationID = 1
                startedAtISO8601 = SiteCompatibilityInspector.iso8601Timestamp(now)
            }
            resolvedID = currentNavigationID
        }

        let chain = navOriginsByID[resolvedID] ?? (resolvedID == currentNavigationID ? redirectChainOrigins : [])
        let failedOrigin = chain.last
            ?? stagedMainAction?.origin
            ?? SiteCompatibilityInspector.sanitizedOrigin(for: fallbackURL)

        if resolvedID < currentNavigationID {
            previousNavigationFailure = ArchivedNavigationFailureDiagnostic(
                navigationID: resolvedID,
                origin: failedOrigin,
                redirectChainOrigins: chain,
                sanitizedError: sanitized,
                recordedAtISO8601: SiteCompatibilityInspector.iso8601Timestamp(now),
                wasLateSupersededCallback: true
            )
            return true
        }

        awaitingProvisionalTokenForCurrentID = false
        phase = .failed
        appendRedirectOrigin(failedOrigin, for: resolvedID)
        currentNavigationError = sanitized
        appendFailureCategory(
            category: "mainFrameNavigationError",
            origin: failedOrigin,
            detail: "\(domain) (\(code))"
        )
        issueKind = .navigationError
        issueSummary = sanitized
        return true
    }

    public mutating func recordWebContentProcessTermination(currentURL: URL?) {
        webContentProcessTerminations &+= 1
        let origin = SiteCompatibilityInspector.sanitizedOrigin(for: currentURL)
        appendFailureCategory(
            category: "webContentProcessTerminated",
            origin: origin,
            detail: "count=\(webContentProcessTerminations)"
        )
    }

    public func buildTopLevelDiagnostic() -> TopLevelNavigationDiagnostic {
        TopLevelNavigationDiagnostic(
            navigationID: currentNavigationID,
            startedAtISO8601: startedAtISO8601,
            redirectChainOrigins: redirectChainOrigins,
            lastPolicyDecision: lastPolicyDecision,
            lastHTTPStatusCode: lastHTTPStatusCode,
            lastNavigationError: currentNavigationError,
            webContentProcessTerminations: webContentProcessTerminations,
            previousNavigationFailure: previousNavigationFailure
        )
    }
}
