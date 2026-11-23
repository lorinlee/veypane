import Foundation

public struct RawFaviconLink: Codable, Equatable, Sendable {
    public var href: String
    public var rel: String
    public var sizes: String
    public var mimeType: String

    public init(href: String, rel: String = "icon", sizes: String = "", mimeType: String = "") {
        self.href = href
        self.rel = rel
        self.sizes = sizes
        self.mimeType = mimeType
    }
}

public struct FaviconCandidate: Codable, Equatable, Sendable {
    public var url: URL
    public var rel: String
    public var declaredMaxDimension: Int?
    public var isScalableVector: Bool
    public var score: Int

    public init(
        url: URL,
        rel: String,
        declaredMaxDimension: Int?,
        isScalableVector: Bool,
        score: Int
    ) {
        self.url = url
        self.rel = rel
        self.declaredMaxDimension = declaredMaxDimension
        self.isScalableVector = isScalableVector
        self.score = score
    }
}

/// High-DPI favicon candidate ranker for Retina pad rail icons (Round 5 Outcome 2).
/// Prefers vector (`svg`) and high-DPI (`64px–192px`, `apple-touch-icon`) assets over blurry `16x16` `.ico` files.
public enum FaviconCandidateSelector {
    /// Default target pixel size for a `36–40 pt` rail icon at `2x` Retina scale (`72–80 px`).
    public static let defaultTargetPixelSize = 72

    public static func rankCandidates(
        from rawLinks: [RawFaviconLink],
        pageURL: URL,
        targetPixelSize: Int = defaultTargetPixelSize
    ) -> [FaviconCandidate] {
        var bestByURL: [String: FaviconCandidate] = [:]

        for raw in rawLinks {
            let trimmedHref = raw.href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHref.isEmpty,
                  let resolved = resolveIconURL(href: trimmedHref, baseURL: pageURL) else {
                continue
            }

            let relLower = raw.rel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let mimeLower = raw.mimeType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let pathLower = resolved.path.lowercased()

            let parsed = parseSizesAttribute(raw.sizes)
            let isSVG = mimeLower.contains("svg")
                || pathLower.hasSuffix(".svg")
                || (parsed.hasAnyKeyword && !pathLower.hasSuffix(".ico"))
            let isAppleTouch = relLower.contains("apple-touch-icon")
            let isMaskIcon = relLower.contains("mask-icon")
            let isICO = mimeLower.contains("icon") && pathLower.hasSuffix(".ico") || pathLower.hasSuffix(".ico")

            // Apple touch icons without an explicit `sizes` attribute are 180x180 by convention.
            let effectiveDim: Int? = parsed.maxDimension ?? (isAppleTouch ? 180 : nil)

            let score = computeScore(
                maxDimension: effectiveDim,
                isSVG: isSVG,
                isAppleTouch: isAppleTouch,
                isMaskIcon: isMaskIcon,
                isICO: isICO,
                targetPixelSize: targetPixelSize
            )

            let candidate = FaviconCandidate(
                url: resolved,
                rel: relLower.isEmpty ? "icon" : relLower,
                declaredMaxDimension: effectiveDim,
                isScalableVector: isSVG,
                score: score
            )

            let key = resolved.absoluteString
            if let existing = bestByURL[key], existing.score >= candidate.score {
                continue
            }
            bestByURL[key] = candidate
        }

        // Add standard origin-level fallbacks if HTTP(S)
        if let scheme = pageURL.scheme?.lowercased(),
           (scheme == "http" || scheme == "https"),
           let host = pageURL.host {
            var comps = URLComponents()
            comps.scheme = scheme
            comps.host = host
            comps.port = pageURL.port

            comps.path = "/apple-touch-icon.png"
            if let touchFallback = comps.url, bestByURL[touchFallback.absoluteString] == nil {
                bestByURL[touchFallback.absoluteString] = FaviconCandidate(
                    url: touchFallback,
                    rel: "fallback-touch",
                    declaredMaxDimension: 180,
                    isScalableVector: false,
                    score: 310
                )
            }

            comps.path = "/favicon.ico"
            if let icoFallback = comps.url, bestByURL[icoFallback.absoluteString] == nil {
                bestByURL[icoFallback.absoluteString] = FaviconCandidate(
                    url: icoFallback,
                    rel: "fallback-ico",
                    declaredMaxDimension: nil,
                    isScalableVector: false,
                    score: 150
                )
            }
        }

        return bestByURL.values.sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.url.absoluteString < rhs.url.absoluteString
        }
    }

    public static func parseSizesAttribute(_ rawSizes: String) -> (maxDimension: Int?, hasAnyKeyword: Bool) {
        let trimmed = rawSizes.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return (nil, false) }

        var hasAny = false
        var best: Int?

        for token in trimmed.split(whereSeparator: \.isWhitespace) {
            if token == "any" {
                hasAny = true
                continue
            }
            let parts = token.split(separator: "x")
            if parts.count == 2,
               let w = Int(parts[0]),
               let h = Int(parts[1]),
               w > 0, h > 0 {
                let dim = max(w, h)
                best = max(best ?? 0, dim)
            }
        }
        return (best, hasAny)
    }

    private static func resolveIconURL(href: String, baseURL: URL) -> URL? {
        if href.lowercased().hasPrefix("data:image/") {
            return URL(string: href)
        }
        guard let url = URL(string: href, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http") else {
            return nil
        }
        return url
    }

    private static func computeScore(
        maxDimension: Int?,
        isSVG: Bool,
        isAppleTouch: Bool,
        isMaskIcon: Bool,
        isICO: Bool,
        targetPixelSize: Int
    ) -> Int {
        if isMaskIcon {
            // Safari pinned-tab monochrome SVGs are single-color silhouettes; use only if better icons aren't present
            return 340
        }
        if isSVG {
            return 950
        }

        if let dim = maxDimension {
            if dim >= targetPixelSize && dim <= 256 {
                // Ideal Retina range (e.g., 72..256: 96x96, 128x128, 180x180, 192x192)
                let distancePenalty = min(60, abs(dim - 128) / 4)
                let touchBonus = isAppleTouch ? 10 : 0
                return 940 - distancePenalty + touchBonus
            }
            if dim >= 64 && dim < targetPixelSize {
                return 880
            }
            if dim > 256 {
                // E.g. 512x512 — sharp, slightly heavier download than 180x180
                return 830
            }
            if dim >= 48 {
                return 680
            }
            if dim >= 32 {
                return 610
            }
            // 16x16 or 24x24: heavily penalized so we never upscale a blurry 16px favicon when a better asset exists
            return 200 + dim
        }

        if isAppleTouch {
            return 900
        }
        if isICO {
            return 410
        }
        return 540
    }
}
