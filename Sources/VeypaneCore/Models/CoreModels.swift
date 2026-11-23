import Foundation
import CoreGraphics

// MARK: - Settings Pane Identifier

public enum SettingsPaneID: String, Codable, CaseIterable, Sendable, Identifiable {
    case general = "general"
    case trigger = "trigger"
    case appearance = "appearance"
    case padsProfiles = "pads-profiles"
    case extensions = "extensions"
    case privacyBlocking = "privacy-blocking"
    case automation = "automation"
    case about = "about"

    public var id: String { rawValue }

    public var localizedTitle: String {
        switch self {
        case .general: L10n.string("settings.pane.general")
        case .trigger: L10n.string("settings.pane.trigger")
        case .appearance: L10n.string("settings.pane.appearance")
        case .padsProfiles: L10n.string("settings.pane.pads_profiles")
        case .extensions: L10n.string("settings.pane.extensions")
        case .privacyBlocking: L10n.string("settings.pane.privacy")
        case .automation: L10n.string("settings.pane.automation")
        case .about: L10n.string("settings.pane.about")
        }
    }

    public var symbolName: String {
        switch self {
        case .general: "gearshape"
        case .trigger: "sparkles.rectangle.stack"
        case .appearance: "paintbrush"
        case .padsProfiles: "person.2.crop.square.stack"
        case .extensions: "puzzlepiece.extension"
        case .privacyBlocking: "hand.raised"
        case .automation: "terminal"
        case .about: "info.circle"
        }
    }

    public static func resolve(_ raw: String?) -> SettingsPaneID? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        if let exact = SettingsPaneID(rawValue: raw) { return exact }
        switch raw {
        case "pads", "profiles", "padsandprofiles", "pads_profiles": return .padsProfiles
        case "extension", "extensions", "ext", "addons": return .extensions
        case "privacy", "blocking", "rules", "privacyandblocking", "privacy_blocking": return .privacyBlocking
        default: return nil
        }
    }
}

// MARK: - Live UI State Snapshot (V2 / V3)

public struct UIStateSnapshot: Codable, Equatable, Sendable {
    public var appName: String
    public var bundleIdentifier: String
    public var statusItem: Bool
    public var statusItemVisible: Bool
    public var panelVisible: Bool
    public var panelFrame: String
    public var selectedPad: String
    public var selectedPadLoading: Bool
    public var settingsVisible: Bool
    public var welcomeVisible: Bool
    public var diagnostics: RuntimeDiagnosticsCounters
    public var pid: Int32
    public var updatedAt: Date

    public init(
        appName: String = AppBrandIdentity.productName,
        bundleIdentifier: String = AppBrandIdentity.bundleIdentifier,
        statusItem: Bool,
        statusItemVisible: Bool,
        panelVisible: Bool,
        panelFrame: String,
        selectedPad: String,
        selectedPadLoading: Bool,
        settingsVisible: Bool,
        welcomeVisible: Bool,
        diagnostics: RuntimeDiagnosticsCounters = RuntimeDiagnosticsCounters(),
        pid: Int32 = ProcessInfo.processInfo.processIdentifier,
        updatedAt: Date = Date()
    ) {
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.statusItem = statusItem
        self.statusItemVisible = statusItemVisible
        self.panelVisible = panelVisible
        self.panelFrame = panelFrame
        self.selectedPad = selectedPad
        self.selectedPadLoading = selectedPadLoading
        self.settingsVisible = settingsVisible
        self.welcomeVisible = welcomeVisible
        self.diagnostics = diagnostics
        self.pid = pid
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case appName, bundleIdentifier
        case statusItem, statusItemVisible, panelVisible, panelFrame
        case selectedPad, selectedPadLoading, settingsVisible, welcomeVisible
        case diagnostics, pid, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.appName = try c.decodeIfPresent(String.self, forKey: .appName) ?? AppBrandIdentity.productName
        self.bundleIdentifier = try c.decodeIfPresent(String.self, forKey: .bundleIdentifier) ?? AppBrandIdentity.bundleIdentifier
        self.statusItem = try c.decodeIfPresent(Bool.self, forKey: .statusItem) ?? false
        self.statusItemVisible = try c.decodeIfPresent(Bool.self, forKey: .statusItemVisible) ?? false
        self.panelVisible = try c.decodeIfPresent(Bool.self, forKey: .panelVisible) ?? false
        self.panelFrame = try c.decodeIfPresent(String.self, forKey: .panelFrame) ?? ""
        self.selectedPad = try c.decodeIfPresent(String.self, forKey: .selectedPad) ?? ""
        self.selectedPadLoading = try c.decodeIfPresent(Bool.self, forKey: .selectedPadLoading) ?? false
        self.settingsVisible = try c.decodeIfPresent(Bool.self, forKey: .settingsVisible) ?? false
        self.welcomeVisible = try c.decodeIfPresent(Bool.self, forKey: .welcomeVisible) ?? false
        self.diagnostics = try c.decodeIfPresent(RuntimeDiagnosticsCounters.self, forKey: .diagnostics) ?? RuntimeDiagnosticsCounters()
        self.pid = try c.decodeIfPresent(Int32.self, forKey: .pid) ?? 0
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }
}

// MARK: - Panel Anchor & Sizing

public enum AnchorPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .left: L10n.string("anchor.left")
        case .right: L10n.string("anchor.right")
        case .topLeft: L10n.string("anchor.topLeft")
        case .topRight: L10n.string("anchor.topRight")
        case .bottomLeft: L10n.string("anchor.bottomLeft")
        case .bottomRight: L10n.string("anchor.bottomRight")
        }
    }

    public var isLeftAligned: Bool {
        switch self {
        case .left, .topLeft, .bottomLeft: true
        case .right, .topRight, .bottomRight: false
        }
    }

    public var isCorner: Bool {
        switch self {
        case .left, .right: false
        case .topLeft, .topRight, .bottomLeft, .bottomRight: true
        }
    }

    public var isTopCorner: Bool {
        self == .topLeft || self == .topRight
    }

    public var isBottomCorner: Bool {
        self == .bottomLeft || self == .bottomRight
    }

    /// Offscreen horizontal direction in AppKit screen coordinates (`-1` off left edge, `+1` off right edge).
    public var offscreenHorizontalSign: CGFloat {
        isLeftAligned ? -1.0 : 1.0
    }

    /// Offscreen vertical direction in AppKit screen coordinates (`+1` above top edge, `-1` below bottom edge, `0` for side edges).
    public var offscreenVerticalSign: CGFloat {
        switch self {
        case .left, .right: 0.0
        case .topLeft, .topRight: 1.0
        case .bottomLeft, .bottomRight: -1.0
        }
    }

    /// Flips horizontal alignment while preserving corner vs full-edge vertical placement.
    public func withHorizontalSide(left placeLeft: Bool) -> AnchorPosition {
        switch self {
        case .left, .right:
            return placeLeft ? .left : .right
        case .topLeft, .topRight:
            return placeLeft ? .topLeft : .topRight
        case .bottomLeft, .bottomRight:
            return placeLeft ? .bottomLeft : .bottomRight
        }
    }
}

public struct PanelSizeOverride: Codable, Equatable, Sendable {
    public var widthPercent: Double?
    public var heightPercent: Double?
    public var fixedWidth: Double?
    public var fixedHeight: Double?

    public init(
        widthPercent: Double? = nil,
        heightPercent: Double? = nil,
        fixedWidth: Double? = nil,
        fixedHeight: Double? = nil
    ) {
        self.widthPercent = widthPercent
        self.heightPercent = heightPercent
        self.fixedWidth = fixedWidth
        self.fixedHeight = fixedHeight
    }

    public var isEmpty: Bool {
        widthPercent == nil && heightPercent == nil && fixedWidth == nil && fixedHeight == nil
    }
}

public struct SiteSizeRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var hostPattern: String
    public var sizeOverride: PanelSizeOverride
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        hostPattern: String,
        sizeOverride: PanelSizeOverride,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.hostPattern = hostPattern
        self.sizeOverride = sizeOverride
        self.isEnabled = isEnabled
    }
}

// MARK: - User Agent Presets

public enum UserAgentPreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case desktopSafari
    case iPhoneSafari
    case iPadSafari
    case defaultWebKit
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .desktopSafari: L10n.string("ua.desktopSafari")
        case .iPhoneSafari: L10n.string("ua.iPhoneSafari")
        case .iPadSafari: L10n.string("ua.iPadSafari")
        case .defaultWebKit: L10n.string("ua.defaultWebKit")
        case .custom: L10n.string("ua.custom")
        }
    }

    public var symbolName: String {
        switch self {
        case .desktopSafari: "desktopcomputer"
        case .iPhoneSafari: "iphone"
        case .iPadSafari: "ipad"
        case .defaultWebKit: "globe"
        case .custom: "wrench.and.screwdriver"
        }
    }

    public var isMobile: Bool {
        self == .iPhoneSafari || self == .iPadSafari
    }

    public static var hostSafariVersionToken: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        if os.majorVersion >= 26 {
            return "\(os.majorVersion).\(max(0, os.minorVersion))"
        }
        return "18.4"
    }

    public static var desktopSafariApplicationName: String {
        "Version/\(hostSafariVersionToken) Safari/605.1.15"
    }

    public func resolvedUserAgent(customValue: String? = nil) -> String? {
        switch self {
        case .defaultWebKit:
            return nil
        case .desktopSafari:
            // Standard frozen macOS WebKit token (`Intel Mac OS X 10_15_7`), never impersonating Chrome
            // and never sending non-standard OS version tokens that trigger anti-bot UA anomalies.
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) \(Self.desktopSafariApplicationName)"
        case .iPhoneSafari:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1"
        case .iPadSafari:
            return "Mozilla/5.0 (iPad; CPU OS 18_4 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.4 Mobile/15E148 Safari/604.1"
        case .custom:
            let trimmed = customValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

// MARK: - Search Engines & New Window Behavior

public enum SearchEnginePreset: String, Codable, CaseIterable, Sendable, Identifiable {
    case duckDuckGo
    case google
    case bing
    case brave
    case ecosia
    case kagi
    case custom

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        case .brave: "Brave Search"
        case .ecosia: "Ecosia"
        case .kagi: "Kagi"
        case .custom: L10n.string("ua.custom")
        }
    }

    public func urlTemplate(customTemplate: String? = nil) -> String {
        switch self {
        case .duckDuckGo:
            return "https://duckduckgo.com/?q=%s"
        case .google:
            return "https://www.google.com/search?q=%s"
        case .bing:
            return "https://www.bing.com/search?q=%s"
        case .brave:
            return "https://search.brave.com/search?q=%s"
        case .ecosia:
            return "https://www.ecosia.org/search?q=%s"
        case .kagi:
            return "https://kagi.com/search?q=%s"
        case .custom:
            let trimmed = customTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? "https://duckduckgo.com/?q=%s" : trimmed
        }
    }
}

public enum NewWindowBehavior: String, Codable, CaseIterable, Sendable, Identifiable {
    case openInNewPad
    case openInCurrentPad
    case openInDefaultBrowser

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .openInNewPad: L10n.string("newwin.openInNewPad")
        case .openInCurrentPad: L10n.string("newwin.openInCurrentPad")
        case .openInDefaultBrowser: L10n.string("newwin.openInDefaultBrowser")
        }
    }
}

// MARK: - Pads, Profiles, History, and Favorites

public struct BrowserProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var symbolName: String
    public var colorHex: String
    public var dataStoreIdentifier: UUID

    public init(
        id: UUID = UUID(),
        name: String,
        symbolName: String = "person.crop.circle",
        colorHex: String = "#3B82F6",
        dataStoreIdentifier: UUID = UUID()
    ) {
        self.id = id
        self.name = name
        self.symbolName = symbolName
        self.colorHex = colorHex
        self.dataStoreIdentifier = dataStoreIdentifier
    }

    public static func defaultProfiles() -> [BrowserProfile] {
        [
            BrowserProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                name: "Personal",
                symbolName: "person.crop.circle",
                colorHex: "#3B82F6",
                dataStoreIdentifier: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
            ),
            BrowserProfile(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                name: "Work",
                symbolName: "briefcase.fill",
                colorHex: "#10B981",
                dataStoreIdentifier: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!
            )
        ]
    }
}

public struct Pad: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    /// `true` only when the user explicitly renamed this pad (`Rename…`), preserving custom titles across navigations.
    public var hasCustomTitle: Bool
    public var url: URL
    public var faviconURL: URL?
    public var symbolName: String
    public var profileID: UUID?
    public var userAgentPreset: UserAgentPreset
    public var customUserAgent: String?
    public var sizeOverride: PanelSizeOverride?
    public var isMuted: Bool
    public var isInspectable: Bool
    public var isHibernated: Bool
    /// Explicit per-pad user opt-in to pause custom CSS/JS rules, content blocker, and JS shims without disabling browser security.
    public var pauseCustomModifications: Bool
    public var badgeCount: Int?
    public var hasUnreadDot: Bool
    public var pageZoom: Double
    public var lastActiveAt: Date
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        hasCustomTitle: Bool = false,
        url: URL,
        faviconURL: URL? = nil,
        symbolName: String = "globe",
        profileID: UUID? = nil,
        userAgentPreset: UserAgentPreset = .desktopSafari,
        customUserAgent: String? = nil,
        sizeOverride: PanelSizeOverride? = nil,
        isMuted: Bool = false,
        isInspectable: Bool = false,
        isHibernated: Bool = false,
        pauseCustomModifications: Bool = false,
        badgeCount: Int? = nil,
        hasUnreadDot: Bool = false,
        pageZoom: Double = 1.0,
        lastActiveAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.url = url
        self.faviconURL = faviconURL
        self.symbolName = symbolName
        self.profileID = profileID
        self.userAgentPreset = userAgentPreset
        self.customUserAgent = customUserAgent
        self.sizeOverride = sizeOverride
        self.isMuted = isMuted
        self.isInspectable = isInspectable
        self.isHibernated = isHibernated
        self.pauseCustomModifications = pauseCustomModifications
        self.badgeCount = badgeCount
        self.hasUnreadDot = hasUnreadDot
        self.pageZoom = pageZoom
        self.lastActiveAt = lastActiveAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, hasCustomTitle, url, faviconURL, symbolName, profileID
        case userAgentPreset, customUserAgent, sizeOverride
        case isMuted, isInspectable, isHibernated, pauseCustomModifications
        case badgeCount, hasUnreadDot, pageZoom, lastActiveAt, createdAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        let decodedURL = try c.decode(URL.self, forKey: .url)
        self.url = decodedURL
        let decodedTitle = try c.decodeIfPresent(String.self, forKey: .title) ?? (decodedURL.host ?? decodedURL.absoluteString)
        self.title = decodedTitle
        self.hasCustomTitle = try c.decodeIfPresent(Bool.self, forKey: .hasCustomTitle) ?? false
        self.faviconURL = try c.decodeIfPresent(URL.self, forKey: .faviconURL)
        self.symbolName = try c.decodeIfPresent(String.self, forKey: .symbolName) ?? "globe"
        self.profileID = try c.decodeIfPresent(UUID.self, forKey: .profileID)
        self.userAgentPreset = try c.decodeIfPresent(UserAgentPreset.self, forKey: .userAgentPreset) ?? .desktopSafari
        self.customUserAgent = try c.decodeIfPresent(String.self, forKey: .customUserAgent)
        self.sizeOverride = try c.decodeIfPresent(PanelSizeOverride.self, forKey: .sizeOverride)
        self.isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        self.isInspectable = try c.decodeIfPresent(Bool.self, forKey: .isInspectable) ?? false
        self.isHibernated = try c.decodeIfPresent(Bool.self, forKey: .isHibernated) ?? false
        self.pauseCustomModifications = try c.decodeIfPresent(Bool.self, forKey: .pauseCustomModifications) ?? false
        self.badgeCount = try c.decodeIfPresent(Int.self, forKey: .badgeCount)
        self.hasUnreadDot = try c.decodeIfPresent(Bool.self, forKey: .hasUnreadDot) ?? false
        self.pageZoom = try c.decodeIfPresent(Double.self, forKey: .pageZoom) ?? 1.0
        self.lastActiveAt = try c.decodeIfPresent(Date.self, forKey: .lastActiveAt) ?? Date()
        self.createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Updates badge state and live page title from an observed `WKWebView` / SPA `document.title`,
    /// never overwriting an explicit user-assigned custom title (`hasCustomTitle == true`).
    @discardableResult
    public mutating func applyObservedPageTitle(_ rawPageTitle: String) -> ParsedBadge {
        let parsed = BadgeParser.parse(pageTitle: rawPageTitle)
        badgeCount = parsed.count
        hasUnreadDot = parsed.hasUnreadDot
        let clean = parsed.cleanTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !hasCustomTitle && !clean.isEmpty {
            title = clean
        }
        return parsed
    }

    public var formattedBadge: String? {
        if let count = badgeCount, count > 0 {
            return count > 99 ? "99+" : "\(count)"
        }
        return hasUnreadDot ? "•" : nil
    }

    public var effectiveUserAgent: String? {
        userAgentPreset.resolvedUserAgent(customValue: customUserAgent)
    }

    public var fallbackInitial: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.first(where: { $0.isLetter || $0.isNumber }) {
            return String(first).uppercased()
        }
        if let hostFirst = url.host?.replacingOccurrences(of: "www.", with: "").first {
            return String(hostFirst).uppercased()
        }
        return "W"
    }
}

public struct ClosedPadRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var pad: Pad
    public var closedIndex: Int
    public var closedAt: Date

    public init(id: UUID = UUID(), pad: Pad, closedIndex: Int, closedAt: Date = Date()) {
        self.id = id
        self.pad = pad
        self.closedIndex = closedIndex
        self.closedAt = closedAt
    }
}

public struct RecentHistoryEntry: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var visitedAt: Date

    public init(id: UUID = UUID(), title: String, url: URL, visitedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.url = url
        self.visitedAt = visitedAt
    }
}

public struct FavoriteItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var category: String
    public var symbolName: String
    public var suggestedUserAgent: UserAgentPreset

    public init(
        id: UUID = UUID(),
        title: String,
        url: URL,
        category: String = "General",
        symbolName: String = "star.fill",
        suggestedUserAgent: UserAgentPreset = .desktopSafari
    ) {
        self.id = id
        self.title = title
        self.url = url
        self.category = category
        self.symbolName = symbolName
        self.suggestedUserAgent = suggestedUserAgent
    }

    public static func builtInPresets() -> [FavoriteItem] {
        [
            FavoriteItem(title: "ChatGPT", url: URL(string: "https://chatgpt.com")!, category: "AI", symbolName: "sparkles"),
            FavoriteItem(title: "Claude", url: URL(string: "https://claude.ai")!, category: "AI", symbolName: "bubble.left.and.bubble.right"),
            FavoriteItem(title: "Gmail", url: URL(string: "https://mail.google.com")!, category: "Mail & Calendar", symbolName: "envelope"),
            FavoriteItem(title: "Calendar", url: URL(string: "https://calendar.google.com")!, category: "Mail & Calendar", symbolName: "calendar"),
            FavoriteItem(title: "Slack", url: URL(string: "https://app.slack.com")!, category: "Communication", symbolName: "number.square"),
            FavoriteItem(title: "Notion", url: URL(string: "https://www.notion.so")!, category: "Notes & Docs", symbolName: "doc.text"),
            FavoriteItem(title: "GitHub", url: URL(string: "https://github.com")!, category: "Developer", symbolName: "chevron.left.forwardslash.chevron.right"),
            FavoriteItem(title: "Wikipedia", url: URL(string: "https://www.wikipedia.org")!, category: "Reference", symbolName: "book"),
            FavoriteItem(title: "Hacker News", url: URL(string: "https://news.ycombinator.com")!, category: "News", symbolName: "newspaper")
        ]
    }
}

// MARK: - Content Rules & CSS/JS Injection

public enum ScriptInjectionTime: String, Codable, CaseIterable, Sendable, Identifiable {
    case atDocumentStart
    case atDocumentEnd

    public var id: String { rawValue }
}

public struct InjectionRule: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var urlPattern: String
    public var css: String
    public var javascript: String
    public var injectionTime: ScriptInjectionTime
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        urlPattern: String = "*://*/*",
        css: String = "",
        javascript: String = "",
        injectionTime: ScriptInjectionTime = .atDocumentEnd,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.urlPattern = urlPattern
        self.css = css
        self.javascript = javascript
        self.injectionTime = injectionTime
        self.isEnabled = isEnabled
    }
}

public struct ContentBlockerSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var useBuiltInAdBlockRules: Bool
    public var blockedDomains: [String]
    public var customRuleListJSON: String

    public init(
        isEnabled: Bool = false,
        useBuiltInAdBlockRules: Bool = true,
        blockedDomains: [String] = [],
        customRuleListJSON: String = ""
    ) {
        self.isEnabled = isEnabled
        self.useBuiltInAdBlockRules = useBuiltInAdBlockRules
        self.blockedDomains = blockedDomains
        self.customRuleListJSON = customRuleListJSON
    }
}

// MARK: - Display, Appearance & Automation Settings

public enum DisplayTargetMode: Codable, Equatable, Sendable {
    case followMouse
    case pinnedDisplay(displayID: UInt32, name: String?)

    public var isFollowMouse: Bool {
        if case .followMouse = self { return true }
        return false
    }
}

public enum AppThemePreference: String, Codable, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: L10n.string("theme.system")
        case .light: L10n.string("theme.light")
        case .dark: L10n.string("theme.dark")
        }
    }
}

public struct AppearanceSettings: Codable, Equatable, Sendable {
    public var theme: AppThemePreference
    public var vibrancySidebar: Bool
    public var cornerRadius: Double
    public var hasShadow: Bool
    public var compactSidebar: Bool
    public var sidebarWidthRegular: Double?
    public var sidebarIconSizeRegular: Double?
    public var sidebarWidthCompact: Double?
    public var sidebarIconSizeCompact: Double?
    public var launchAtLogin: Bool
    public var showMenuBarIcon: Bool

    public init(
        theme: AppThemePreference = .system,
        vibrancySidebar: Bool = true,
        cornerRadius: Double = 12.0,
        hasShadow: Bool = true,
        compactSidebar: Bool = false,
        sidebarWidthRegular: Double? = nil,
        sidebarIconSizeRegular: Double? = nil,
        sidebarWidthCompact: Double? = nil,
        sidebarIconSizeCompact: Double? = nil,
        launchAtLogin: Bool = false,
        showMenuBarIcon: Bool = true
    ) {
        self.theme = theme
        self.vibrancySidebar = vibrancySidebar
        self.cornerRadius = cornerRadius
        self.hasShadow = hasShadow
        self.compactSidebar = compactSidebar
        self.sidebarWidthRegular = Self.sanitizedWidthOverride(sidebarWidthRegular)
        self.sidebarIconSizeRegular = Self.sanitizedIconOverride(
            sidebarIconSizeRegular,
            widthOverride: self.sidebarWidthRegular,
            compactSidebar: false
        )
        self.sidebarWidthCompact = Self.sanitizedWidthOverride(sidebarWidthCompact)
        self.sidebarIconSizeCompact = Self.sanitizedIconOverride(
            sidebarIconSizeCompact,
            widthOverride: self.sidebarWidthCompact,
            compactSidebar: true
        )
        self.launchAtLogin = launchAtLogin
        self.showMenuBarIcon = showMenuBarIcon
    }

    private enum CodingKeys: String, CodingKey {
        case theme
        case vibrancySidebar
        case cornerRadius
        case hasShadow
        case compactSidebar
        case sidebarWidthRegular
        case sidebarIconSizeRegular
        case sidebarWidthCompact
        case sidebarIconSizeCompact
        case launchAtLogin
        case showMenuBarIcon
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let theme = try c.decodeIfPresent(AppThemePreference.self, forKey: .theme) ?? .system
        let vibrancySidebar = try c.decodeIfPresent(Bool.self, forKey: .vibrancySidebar) ?? true
        let cornerRadius = try c.decodeIfPresent(Double.self, forKey: .cornerRadius) ?? 12.0
        let hasShadow = try c.decodeIfPresent(Bool.self, forKey: .hasShadow) ?? true
        let compactSidebar = try c.decodeIfPresent(Bool.self, forKey: .compactSidebar) ?? false
        let widthReg = try c.decodeIfPresent(Double.self, forKey: .sidebarWidthRegular)
        let iconReg = try c.decodeIfPresent(Double.self, forKey: .sidebarIconSizeRegular)
        let widthCmp = try c.decodeIfPresent(Double.self, forKey: .sidebarWidthCompact)
        let iconCmp = try c.decodeIfPresent(Double.self, forKey: .sidebarIconSizeCompact)
        let launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        let showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true

        self.init(
            theme: theme,
            vibrancySidebar: vibrancySidebar,
            cornerRadius: cornerRadius,
            hasShadow: hasShadow,
            compactSidebar: compactSidebar,
            sidebarWidthRegular: widthReg,
            sidebarIconSizeRegular: iconReg,
            sidebarWidthCompact: widthCmp,
            sidebarIconSizeCompact: iconCmp,
            launchAtLogin: launchAtLogin,
            showMenuBarIcon: showMenuBarIcon
        )
    }

    public var activeSidebarWidthOverride: Double? {
        compactSidebar ? sidebarWidthCompact : sidebarWidthRegular
    }

    public var activeSidebarIconSizeOverride: Double? {
        compactSidebar ? sidebarIconSizeCompact : sidebarIconSizeRegular
    }

    public var isActiveSidebarSizingCustomized: Bool {
        activeSidebarWidthOverride != nil || activeSidebarIconSizeOverride != nil
    }

    public mutating func setActiveSidebarWidth(_ rawWidth: Double) {
        let clampedW = Double(PanelChromeMetrics.clampedSidebarWidth(rawWidth, compactSidebar: compactSidebar))
        let maxIcon = Double(PanelChromeMetrics.maxIconSize(forSidebarWidth: CGFloat(clampedW)))
        if compactSidebar {
            sidebarWidthCompact = clampedW
            if let curIcon = sidebarIconSizeCompact, curIcon > maxIcon {
                sidebarIconSizeCompact = maxIcon
            }
        } else {
            sidebarWidthRegular = clampedW
            if let curIcon = sidebarIconSizeRegular, curIcon > maxIcon {
                sidebarIconSizeRegular = maxIcon
            }
        }
    }

    public mutating func setActiveSidebarIconSize(_ rawIconSize: Double) {
        let effectiveW = PanelChromeMetrics.clampedSidebarWidth(activeSidebarWidthOverride, compactSidebar: compactSidebar)
        let clampedIcon = Double(PanelChromeMetrics.clampedIconSize(rawIconSize, forSidebarWidth: effectiveW, compactSidebar: compactSidebar))
        if compactSidebar {
            sidebarIconSizeCompact = clampedIcon
        } else {
            sidebarIconSizeRegular = clampedIcon
        }
    }

    public mutating func resetActiveSidebarSizingToDefault() {
        if compactSidebar {
            sidebarWidthCompact = nil
            sidebarIconSizeCompact = nil
        } else {
            sidebarWidthRegular = nil
            sidebarIconSizeRegular = nil
        }
    }

    private static func sanitizedWidthOverride(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        return Double(min(max(CGFloat(raw.rounded()), PanelChromeMetrics.minSidebarWidth), PanelChromeMetrics.maxSidebarWidth))
    }

    private static func sanitizedIconOverride(_ raw: Double?, widthOverride: Double?, compactSidebar: Bool) -> Double? {
        guard let raw, raw.isFinite else { return nil }
        let effectiveW = PanelChromeMetrics.clampedSidebarWidth(widthOverride, compactSidebar: compactSidebar)
        return Double(PanelChromeMetrics.clampedIconSize(raw, forSidebarWidth: effectiveW, compactSidebar: compactSidebar))
    }
}

public struct EdgeTriggerSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var dwellMilliseconds: Int
    public var triggerThickness: Double
    public var cornerSpan: Double
    public var dismissGraceMilliseconds: Int
    public var requiredModifiers: HotkeyModifiers
    public var ignoreWhileDragging: Bool
    public var ignoreInFullScreenApps: Bool

    public init(
        isEnabled: Bool = true,
        dwellMilliseconds: Int = 160,
        triggerThickness: Double = 4.0,
        cornerSpan: Double = 48.0,
        dismissGraceMilliseconds: Int = 400,
        requiredModifiers: HotkeyModifiers = [],
        ignoreWhileDragging: Bool = true,
        ignoreInFullScreenApps: Bool = true
    ) {
        self.isEnabled = isEnabled
        self.dwellMilliseconds = dwellMilliseconds
        self.triggerThickness = triggerThickness
        self.cornerSpan = cornerSpan
        self.dismissGraceMilliseconds = dismissGraceMilliseconds
        self.requiredModifiers = requiredModifiers
        self.ignoreWhileDragging = ignoreWhileDragging
        self.ignoreInFullScreenApps = ignoreInFullScreenApps
    }
}

public struct AutomationSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var port: UInt16
    public var authToken: String
    public var allowLimitedJS: Bool

    public init(
        isEnabled: Bool = false,
        port: UInt16 = 48721,
        authToken: String = Self.generateToken(),
        allowLimitedJS: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.port = port
        self.authToken = authToken
        self.allowLimitedJS = allowLimitedJS
    }

    public static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let defaultWidthPercent: Double = 66.0
    public static let defaultHeightPercent: Double = 76.0
    public static let defaultEdgeInset: Double = 14.0
    public static let defaultAnimationDuration: Double = 0.22
    public static let defaultAutoHibernateMinutes: Int = 120
    public static let maxAutoHibernateMinutes: Int = 1440
    public static let autoHibernatePresetMinutes: [Int] = [30, 60, 120, 240, 720, 1440, 0]
    public static let defaultMaxLivePads: Int = 0
    public static let maxLivePadsUpperBound: Int = 64
    public static let maxLivePadPresets: [Int] = [0, 6, 10, 16, 24]

    public static func sanitizedAutoHibernateMinutes(_ raw: Int) -> Int {
        min(max(raw, 0), maxAutoHibernateMinutes)
    }

    public static func sanitizedMaxLivePads(_ raw: Int) -> Int {
        min(max(raw, 0), maxLivePadsUpperBound)
    }

    public var anchor: AnchorPosition
    public var widthPercent: Double
    public var heightPercent: Double
    public var edgeInset: Double
    public var animationDuration: Double
    public var disableAnimations: Bool
    public var edgeTrigger: EdgeTriggerSettings
    public var toggleHotkey: HotkeyBinding
    public var searchEngine: SearchEnginePreset
    public var customSearchTemplate: String
    public var newWindowBehavior: NewWindowBehavior
    public var displayTarget: DisplayTargetMode
    public var isPinnedOpen: Bool
    public var isAlwaysOnTop: Bool
    public var isGlobalMuted: Bool
    public var commandWHidesPanel: Bool
    public var enableTrackpadGestures: Bool
    public var autoHibernateMinutes: Int
    public var maxLivePads: Int
    public var syncFolderPath: String?
    public var appearance: AppearanceSettings
    public var contentBlocker: ContentBlockerSettings
    public var automation: AutomationSettings
    public var hasCompletedOnboarding: Bool
    public var selectedSettingsPane: SettingsPaneID
    public var panelSizeUserCustomized: Bool

    public init(
        anchor: AnchorPosition = .right,
        widthPercent: Double = Self.defaultWidthPercent,
        heightPercent: Double = Self.defaultHeightPercent,
        edgeInset: Double = Self.defaultEdgeInset,
        animationDuration: Double = Self.defaultAnimationDuration,
        disableAnimations: Bool = false,
        edgeTrigger: EdgeTriggerSettings = EdgeTriggerSettings(),
        toggleHotkey: HotkeyBinding = .defaultToggle,
        searchEngine: SearchEnginePreset = .duckDuckGo,
        customSearchTemplate: String = "",
        newWindowBehavior: NewWindowBehavior = .openInNewPad,
        displayTarget: DisplayTargetMode = .followMouse,
        isPinnedOpen: Bool = false,
        isAlwaysOnTop: Bool = false,
        isGlobalMuted: Bool = false,
        commandWHidesPanel: Bool = true,
        enableTrackpadGestures: Bool = true,
        autoHibernateMinutes: Int = Self.defaultAutoHibernateMinutes,
        maxLivePads: Int = Self.defaultMaxLivePads,
        syncFolderPath: String? = nil,
        appearance: AppearanceSettings = AppearanceSettings(),
        contentBlocker: ContentBlockerSettings = ContentBlockerSettings(),
        automation: AutomationSettings = AutomationSettings(),
        hasCompletedOnboarding: Bool = false,
        selectedSettingsPane: SettingsPaneID = .general,
        panelSizeUserCustomized: Bool = false
    ) {
        self.anchor = anchor
        self.widthPercent = widthPercent
        self.heightPercent = heightPercent
        self.edgeInset = edgeInset
        self.animationDuration = animationDuration
        self.disableAnimations = disableAnimations
        self.edgeTrigger = edgeTrigger
        self.toggleHotkey = toggleHotkey
        self.searchEngine = searchEngine
        self.customSearchTemplate = customSearchTemplate
        self.newWindowBehavior = newWindowBehavior
        self.displayTarget = displayTarget
        self.isPinnedOpen = isPinnedOpen
        self.isAlwaysOnTop = isAlwaysOnTop
        self.isGlobalMuted = isGlobalMuted
        self.commandWHidesPanel = commandWHidesPanel
        self.enableTrackpadGestures = enableTrackpadGestures
        self.autoHibernateMinutes = Self.sanitizedAutoHibernateMinutes(autoHibernateMinutes)
        self.maxLivePads = Self.sanitizedMaxLivePads(maxLivePads)
        self.syncFolderPath = syncFolderPath
        self.appearance = appearance
        self.contentBlocker = contentBlocker
        self.automation = automation
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.selectedSettingsPane = selectedSettingsPane
        self.panelSizeUserCustomized = panelSizeUserCustomized
    }

    public static func isLegacyDefaultWidthPercent(_ value: Double) -> Bool {
        abs(value - 34.0) < 0.01 || abs(value - 35.0) < 0.01
    }

    public static func isLegacyDefaultFixedWidth(_ value: Double) -> Bool {
        abs(value - 653.0) <= 1.5
    }

    /// Migrates older default panel dimensions (e.g. 34% / 94% or fixed 653 pt) to 66% × 76%
    /// when `panelSizeUserCustomized` is false.
    @discardableResult
    public mutating func migrateLegacyPanelSizeIfNeeded(legacyFixedWidth: Double? = nil) -> Bool {
        guard !panelSizeUserCustomized else { return false }
        let matchedFixed = legacyFixedWidth.map { Self.isLegacyDefaultFixedWidth($0) } ?? false
        let matchedPercent = Self.isLegacyDefaultWidthPercent(widthPercent)
        guard matchedFixed || matchedPercent else { return false }
        widthPercent = Self.defaultWidthPercent
        heightPercent = Self.defaultHeightPercent
        if edgeInset < 12.0 {
            edgeInset = Self.defaultEdgeInset
        }
        return true
    }

    private enum CodingKeys: String, CodingKey {
        case anchor, widthPercent, heightPercent, edgeInset, animationDuration, disableAnimations
        case edgeTrigger, toggleHotkey, searchEngine, customSearchTemplate, newWindowBehavior
        case displayTarget, isPinnedOpen, isAlwaysOnTop, isGlobalMuted, commandWHidesPanel
        case enableTrackpadGestures, autoHibernateMinutes, maxLivePads, syncFolderPath
        case appearance, contentBlocker, automation
        case hasCompletedOnboarding, selectedSettingsPane, panelSizeUserCustomized
        case fixedWidth
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.anchor = try c.decodeIfPresent(AnchorPosition.self, forKey: .anchor) ?? .right
        self.widthPercent = try c.decodeIfPresent(Double.self, forKey: .widthPercent) ?? Self.defaultWidthPercent
        self.heightPercent = try c.decodeIfPresent(Double.self, forKey: .heightPercent) ?? Self.defaultHeightPercent
        self.edgeInset = try c.decodeIfPresent(Double.self, forKey: .edgeInset) ?? Self.defaultEdgeInset
        self.animationDuration = try c.decodeIfPresent(Double.self, forKey: .animationDuration) ?? Self.defaultAnimationDuration
        self.disableAnimations = try c.decodeIfPresent(Bool.self, forKey: .disableAnimations) ?? false
        self.edgeTrigger = try c.decodeIfPresent(EdgeTriggerSettings.self, forKey: .edgeTrigger) ?? EdgeTriggerSettings()
        self.toggleHotkey = try c.decodeIfPresent(HotkeyBinding.self, forKey: .toggleHotkey) ?? .defaultToggle
        self.searchEngine = try c.decodeIfPresent(SearchEnginePreset.self, forKey: .searchEngine) ?? .duckDuckGo
        self.customSearchTemplate = try c.decodeIfPresent(String.self, forKey: .customSearchTemplate) ?? ""
        self.newWindowBehavior = try c.decodeIfPresent(NewWindowBehavior.self, forKey: .newWindowBehavior) ?? .openInNewPad
        self.displayTarget = try c.decodeIfPresent(DisplayTargetMode.self, forKey: .displayTarget) ?? .followMouse
        self.isPinnedOpen = try c.decodeIfPresent(Bool.self, forKey: .isPinnedOpen) ?? false
        self.isAlwaysOnTop = try c.decodeIfPresent(Bool.self, forKey: .isAlwaysOnTop) ?? false
        self.isGlobalMuted = try c.decodeIfPresent(Bool.self, forKey: .isGlobalMuted) ?? false
        self.commandWHidesPanel = try c.decodeIfPresent(Bool.self, forKey: .commandWHidesPanel) ?? true
        self.enableTrackpadGestures = try c.decodeIfPresent(Bool.self, forKey: .enableTrackpadGestures) ?? true
        let rawHibernate = try c.decodeIfPresent(Int.self, forKey: .autoHibernateMinutes) ?? Self.defaultAutoHibernateMinutes
        self.autoHibernateMinutes = Self.sanitizedAutoHibernateMinutes(rawHibernate)
        let rawMaxLive = try c.decodeIfPresent(Int.self, forKey: .maxLivePads) ?? Self.defaultMaxLivePads
        self.maxLivePads = Self.sanitizedMaxLivePads(rawMaxLive)
        self.syncFolderPath = try c.decodeIfPresent(String.self, forKey: .syncFolderPath)
        self.appearance = try c.decodeIfPresent(AppearanceSettings.self, forKey: .appearance) ?? AppearanceSettings()
        self.contentBlocker = try c.decodeIfPresent(ContentBlockerSettings.self, forKey: .contentBlocker) ?? ContentBlockerSettings()
        self.automation = try c.decodeIfPresent(AutomationSettings.self, forKey: .automation) ?? AutomationSettings()
        self.hasCompletedOnboarding = try c.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        self.selectedSettingsPane = try c.decodeIfPresent(SettingsPaneID.self, forKey: .selectedSettingsPane) ?? .general
        self.panelSizeUserCustomized = try c.decodeIfPresent(Bool.self, forKey: .panelSizeUserCustomized) ?? false
        let legacyFixed = try c.decodeIfPresent(Double.self, forKey: .fixedWidth)
        self.migrateLegacyPanelSizeIfNeeded(legacyFixedWidth: legacyFixed)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(widthPercent, forKey: .widthPercent)
        try c.encode(heightPercent, forKey: .heightPercent)
        try c.encode(edgeInset, forKey: .edgeInset)
        try c.encode(animationDuration, forKey: .animationDuration)
        try c.encode(disableAnimations, forKey: .disableAnimations)
        try c.encode(edgeTrigger, forKey: .edgeTrigger)
        try c.encode(toggleHotkey, forKey: .toggleHotkey)
        try c.encode(searchEngine, forKey: .searchEngine)
        try c.encode(customSearchTemplate, forKey: .customSearchTemplate)
        try c.encode(newWindowBehavior, forKey: .newWindowBehavior)
        try c.encode(displayTarget, forKey: .displayTarget)
        try c.encode(isPinnedOpen, forKey: .isPinnedOpen)
        try c.encode(isAlwaysOnTop, forKey: .isAlwaysOnTop)
        try c.encode(isGlobalMuted, forKey: .isGlobalMuted)
        try c.encode(commandWHidesPanel, forKey: .commandWHidesPanel)
        try c.encode(enableTrackpadGestures, forKey: .enableTrackpadGestures)
        try c.encode(Self.sanitizedAutoHibernateMinutes(autoHibernateMinutes), forKey: .autoHibernateMinutes)
        try c.encode(Self.sanitizedMaxLivePads(maxLivePads), forKey: .maxLivePads)
        try c.encodeIfPresent(syncFolderPath, forKey: .syncFolderPath)
        try c.encode(appearance, forKey: .appearance)
        try c.encode(contentBlocker, forKey: .contentBlocker)
        try c.encode(automation, forKey: .automation)
        try c.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try c.encode(selectedSettingsPane, forKey: .selectedSettingsPane)
        try c.encode(panelSizeUserCustomized, forKey: .panelSizeUserCustomized)
    }
}

public struct WorkspaceState: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 6

    public var schemaVersion: Int
    public var pads: [Pad]
    public var selectedPadID: UUID?
    public var activeProfileID: UUID?
    public var profiles: [BrowserProfile]
    public var favorites: [FavoriteItem]
    public var recentHistory: [RecentHistoryEntry]
    public var siteSizeRules: [SiteSizeRule]
    public var injectionRules: [InjectionRule]
    public var installedExtensions: [InstalledExtension]
    public var webExtensionControllerID: UUID
    public var closedPads: [ClosedPadRecord]
    public var settings: AppSettings
    public var updatedAt: Date

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        pads: [Pad],
        selectedPadID: UUID? = nil,
        activeProfileID: UUID? = nil,
        profiles: [BrowserProfile] = BrowserProfile.defaultProfiles(),
        favorites: [FavoriteItem] = FavoriteItem.builtInPresets(),
        recentHistory: [RecentHistoryEntry] = [],
        siteSizeRules: [SiteSizeRule] = [],
        injectionRules: [InjectionRule] = [],
        installedExtensions: [InstalledExtension] = [],
        webExtensionControllerID: UUID = UUID(),
        closedPads: [ClosedPadRecord] = [],
        settings: AppSettings = AppSettings(),
        updatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.pads = pads
        self.selectedPadID = selectedPadID ?? pads.first?.id
        self.activeProfileID = activeProfileID ?? profiles.first?.id
        self.profiles = profiles
        self.favorites = favorites
        self.recentHistory = recentHistory
        self.siteSizeRules = siteSizeRules
        self.injectionRules = injectionRules
        self.installedExtensions = installedExtensions
        self.webExtensionControllerID = webExtensionControllerID
        self.closedPads = closedPads
        self.settings = settings
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, pads, selectedPadID, activeProfileID, profiles
        case favorites, recentHistory, siteSizeRules, injectionRules
        case installedExtensions, webExtensionControllerID, closedPads
        case settings, updatedAt
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedPads = try c.decodeIfPresent([Pad].self, forKey: .pads) ?? []
        let decodedProfiles = try c.decodeIfPresent([BrowserProfile].self, forKey: .profiles) ?? BrowserProfile.defaultProfiles()
        self.schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        self.pads = decodedPads
        self.selectedPadID = try c.decodeIfPresent(UUID.self, forKey: .selectedPadID) ?? decodedPads.first?.id
        self.profiles = decodedProfiles.isEmpty ? BrowserProfile.defaultProfiles() : decodedProfiles
        self.activeProfileID = try c.decodeIfPresent(UUID.self, forKey: .activeProfileID) ?? self.profiles.first?.id
        self.favorites = try c.decodeIfPresent([FavoriteItem].self, forKey: .favorites) ?? FavoriteItem.builtInPresets()
        self.recentHistory = try c.decodeIfPresent([RecentHistoryEntry].self, forKey: .recentHistory) ?? []
        self.siteSizeRules = try c.decodeIfPresent([SiteSizeRule].self, forKey: .siteSizeRules) ?? []
        self.injectionRules = try c.decodeIfPresent([InjectionRule].self, forKey: .injectionRules) ?? []
        self.installedExtensions = try c.decodeIfPresent([InstalledExtension].self, forKey: .installedExtensions) ?? []
        self.webExtensionControllerID = try c.decodeIfPresent(UUID.self, forKey: .webExtensionControllerID) ?? UUID()
        self.closedPads = try c.decodeIfPresent([ClosedPadRecord].self, forKey: .closedPads) ?? []
        self.settings = try c.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        self.updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
    }

    public static func makeDefault() -> WorkspaceState {
        let profiles = BrowserProfile.defaultProfiles()
        let defaultPads = [
            Pad(
                title: "Search",
                url: URL(string: "https://duckduckgo.com")!,
                symbolName: "magnifyingglass",
                profileID: profiles.first?.id
            ),
            Pad(
                title: "Wikipedia",
                url: URL(string: "https://www.wikipedia.org")!,
                symbolName: "book",
                profileID: profiles.first?.id
            )
        ]
        return WorkspaceState(
            pads: defaultPads,
            selectedPadID: defaultPads.first?.id,
            activeProfileID: profiles.first?.id,
            profiles: profiles
        )
    }
}
