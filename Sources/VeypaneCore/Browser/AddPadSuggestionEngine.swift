import Foundation

public enum AddPadSuggestionSource: String, Codable, Equatable, Sendable {
    case directAction
    case existingPad
    case recentHistory
    case favorite

    public var badgeLabel: String {
        switch self {
        case .directAction: ""
        case .existingPad: L10n.string("add_pad.source.open_pad")
        case .recentHistory: L10n.string("add_pad.source.history")
        case .favorite: L10n.string("add_pad.source.favorite")
        }
    }
}

public struct AddPadSuggestion: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var url: URL
    public var symbolName: String
    public var source: AddPadSuggestionSource
    public var existingPadID: UUID?
    public var score: Int

    public init(
        id: String,
        title: String,
        subtitle: String,
        url: URL,
        symbolName: String = "globe",
        source: AddPadSuggestionSource,
        existingPadID: UUID? = nil,
        score: Int
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.url = url
        self.symbolName = symbolName
        self.source = source
        self.existingPadID = existingPadID
        self.score = score
    }
}

public enum AddPadSuggestionEngine {
    public static func rankSuggestions(
        query: String,
        favorites: [FavoriteItem],
        recentHistory: [RecentHistoryEntry],
        existingPads: [Pad],
        searchEngine: SearchEnginePreset = .duckDuckGo,
        customSearchTemplate: String? = nil,
        limit: Int = 8
    ) -> [AddPadSuggestion] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        var candidates: [AddPadSuggestion] = []
        var seenNormalizedURLs: Set<String> = []

        func normalizedKey(_ url: URL) -> String {
            var str = url.absoluteString.lowercased()
            while str.hasSuffix("/") && str.count > 8 {
                str.removeLast()
            }
            return str
        }

        // 1. Existing pads
        for pad in existingPads {
            guard let score = matchScore(query: lowered, title: pad.title, url: pad.url, baseScore: 60) else {
                continue
            }
            let key = normalizedKey(pad.url)
            guard seenNormalizedURLs.insert(key).inserted else { continue }
            candidates.append(
                AddPadSuggestion(
                    id: "pad-\(pad.id.uuidString)",
                    title: pad.title,
                    subtitle: pad.url.host ?? pad.url.absoluteString,
                    url: pad.url,
                    symbolName: pad.symbolName,
                    source: .existingPad,
                    existingPadID: pad.id,
                    score: score
                )
            )
        }

        // 2. Recent history (most recent first)
        for (idx, entry) in recentHistory.enumerated() {
            let recencyBonus = max(0, 15 - idx)
            guard let score = matchScore(query: lowered, title: entry.title, url: entry.url, baseScore: 50 + recencyBonus) else {
                continue
            }
            let key = normalizedKey(entry.url)
            guard seenNormalizedURLs.insert(key).inserted else { continue }
            candidates.append(
                AddPadSuggestion(
                    id: "hist-\(entry.id.uuidString)",
                    title: entry.title,
                    subtitle: entry.url.host ?? entry.url.absoluteString,
                    url: entry.url,
                    symbolName: "clock.arrow.circlepath",
                    source: .recentHistory,
                    score: score
                )
            )
        }

        // 3. Favorites & built-in presets
        for (idx, fav) in favorites.enumerated() {
            let orderBonus = max(0, 12 - idx)
            guard let score = matchScore(query: lowered, title: fav.title, url: fav.url, baseScore: 55 + orderBonus) else {
                continue
            }
            let key = normalizedKey(fav.url)
            guard seenNormalizedURLs.insert(key).inserted else { continue }
            candidates.append(
                AddPadSuggestion(
                    id: "fav-\(fav.id.uuidString)",
                    title: fav.title,
                    subtitle: fav.url.host ?? fav.url.absoluteString,
                    url: fav.url,
                    symbolName: fav.symbolName,
                    source: .favorite,
                    score: score
                )
            )
        }

        candidates.sort { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }

        var output: [AddPadSuggestion] = []
        if !trimmed.isEmpty {
            let resolution = OmniboxParser.resolve(
                input: trimmed,
                engine: searchEngine,
                customTemplate: customSearchTemplate
            )
            let actionTitle: String
            let actionSymbol: String
            switch resolution {
            case .directURL(let url):
                actionTitle = L10n.format("add_pad.open_direct", url.host ?? url.absoluteString)
                actionSymbol = "globe"
            case .search(let q, _):
                actionTitle = L10n.format("add_pad.search_web", q)
                actionSymbol = "magnifyingglass"
            }

            output.append(
                AddPadSuggestion(
                    id: "direct-\(trimmed)",
                    title: actionTitle,
                    subtitle: resolution.url.absoluteString,
                    url: resolution.url,
                    symbolName: actionSymbol,
                    source: .directAction,
                    score: 1000
                )
            )
        }

        let remainingSlots = max(0, limit - output.count)
        output.append(contentsOf: candidates.prefix(remainingSlots))
        return output
    }

    private static func matchScore(query: String, title: String, url: URL, baseScore: Int) -> Int? {
        if query.isEmpty {
            return baseScore
        }
        let lowerTitle = title.lowercased()
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: "www.", with: "")
        let fullURL = url.absoluteString.lowercased()

        if lowerTitle == query || host == query {
            return baseScore + 200
        }
        if lowerTitle.hasPrefix(query) {
            return baseScore + 140
        }
        if host.hasPrefix(query) {
            return baseScore + 130
        }
        if lowerTitle.contains(query) {
            return baseScore + 80
        }
        if host.contains(query) || fullURL.contains(query) {
            return baseScore + 60
        }
        return nil
    }
}
