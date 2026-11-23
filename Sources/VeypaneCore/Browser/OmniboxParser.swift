import Foundation

public enum OmniboxResolution: Equatable, Sendable {
    case directURL(URL)
    case search(query: String, url: URL)

    public var url: URL {
        switch self {
        case .directURL(let url): url
        case .search(_, let url): url
        }
    }
}

public enum OmniboxParser {
    private static let supportedDirectSchemes: Set<String> = Set(
        ["http", "https", "file", "about", "data"] + AppBrandIdentity.supportedURLSchemes
    )

    public static func resolve(
        input: String,
        engine: SearchEnginePreset = .duckDuckGo,
        customTemplate: String? = nil
    ) -> OmniboxResolution {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .directURL(URL(string: "about:blank")!)
        }

        // Explicit search trigger prefix `? query`
        if trimmed.hasPrefix("?") {
            let query = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveQuery = query.isEmpty ? "?" : query
            return .search(
                query: effectiveQuery,
                url: buildSearchURL(query: effectiveQuery, engine: engine, customTemplate: customTemplate)
            )
        }

        // 1. Already has a valid explicit scheme (e.g. https://..., about:blank, file:///..., veypane://...)
        if let schemeRange = trimmed.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) {
            let scheme = String(trimmed[schemeRange].dropLast()).lowercased()
            if supportedDirectSchemes.contains(scheme),
               !trimmed.contains(" "),
               let url = URL(string: trimmed) {
                return .directURL(url)
            }
        }

        // 2. Contains whitespace -> definitely a search query
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return .search(
                query: trimmed,
                url: buildSearchURL(query: trimmed, engine: engine, customTemplate: customTemplate)
            )
        }

        // 3. Localhost or IPv4 or bracketed IPv6 -> default to http://
        if isLocalOrIPAddress(trimmed), let url = URL(string: "http://\(trimmed)") {
            return .directURL(url)
        }

        // 4. Domain-like host (e.g. `apple.com`, `docs.swift.org/swift-book`, `example.co.uk:8443/path`)
        if looksLikeDomainURL(trimmed), let url = URL(string: "https://\(trimmed)") {
            return .directURL(url)
        }

        // 5. Fallback: treat as search keyword
        return .search(
            query: trimmed,
            url: buildSearchURL(query: trimmed, engine: engine, customTemplate: customTemplate)
        )
    }

    public static func buildSearchURL(
        query: String,
        engine: SearchEnginePreset,
        customTemplate: String? = nil
    ) -> URL {
        let template = engine.urlTemplate(customTemplate: customTemplate)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#/")
        let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) ?? query

        let expanded: String
        if template.contains("%s") {
            expanded = template.replacingOccurrences(of: "%s", with: encoded)
        } else if template.contains("{query}") {
            expanded = template.replacingOccurrences(of: "{query}", with: encoded)
        } else {
            let sep = template.contains("?") ? "&q=" : "?q="
            expanded = template + sep + encoded
        }

        return URL(string: expanded) ?? URL(string: "https://duckduckgo.com/?q=\(encoded)")!
    }

    private static func isLocalOrIPAddress(_ candidate: String) -> Bool {
        let hostPort = candidate.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? candidate

        // Bracketed IPv6 `[::1]` or `[::1]:8080`
        if hostPort.hasPrefix("[") && hostPort.contains("]") {
            return true
        }

        let hostOnly = hostPort.split(separator: ":", maxSplits: 1).first.map(String.init)?.lowercased() ?? hostPort.lowercased()
        if hostOnly == "localhost" || hostOnly.hasSuffix(".local") || hostOnly.hasSuffix(".localhost") {
            return true
        }

        // IPv4 check
        let octets = hostOnly.split(separator: ".", omittingEmptySubsequences: false)
        if octets.count == 4, octets.allSatisfy({ part in
            guard let value = Int(part) else { return false }
            return (0...255).contains(value)
        }) {
            return true
        }

        return false
    }

    private static func looksLikeDomainURL(_ candidate: String) -> Bool {
        let hostPort = candidate.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? candidate
        let parts = hostPort.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let host = String(parts[0])
        if parts.count == 2 {
            guard let port = Int(parts[1]), (1...65535).contains(port) else { return false }
        }

        guard host.contains("."), !host.hasPrefix("."), !host.hasSuffix(".") else {
            return false
        }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let tld = labels.last else { return false }

        // TLD must be >= 2 letters (or punycode xn--...)
        let tldStr = String(tld)
        let validTLD = (tldStr.count >= 2 && tldStr.allSatisfy(\.isLetter)) || tldStr.lowercased().hasPrefix("xn--")
        guard validTLD else { return false }

        let validLabelChars = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        return labels.allSatisfy { label in
            !label.isEmpty &&
            !label.hasPrefix("-") &&
            !label.hasSuffix("-") &&
            label.unicodeScalars.allSatisfy { validLabelChars.contains($0) }
        }
    }
}
