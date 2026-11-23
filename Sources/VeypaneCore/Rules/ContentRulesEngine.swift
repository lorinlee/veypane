import Foundation

public enum URLPatternMatcher {
    /// Matches a URL against wildcard patterns like `*://*/*`, `*://*.example.com/*`, `https://news.ycombinator.com/*`,
    /// plain host suffixes like `example.com`, or regex patterns prefixed with `re:`.
    public static func matches(url: URL, pattern: String) -> Bool {
        let trimmed = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed == "*" || trimmed == "*://*/*" || trimmed == "<all_urls>" {
            return true
        }

        let fullString = url.absoluteString

        // Regex mode: `re:^https://(www\.)?example\.com/.*`
        if trimmed.hasPrefix("re:") {
            let expr = String(trimmed.dropFirst(3))
            guard !expr.isEmpty else { return false }
            return fullString.range(of: expr, options: [.regularExpression, .caseInsensitive]) != nil
        }

        // Plain domain pattern without `/` or `*://`
        if !trimmed.contains("/") && !trimmed.contains(":") {
            guard let host = url.host else { return false }
            return SiteSizeRuleMatcher.matchesHost(host, pattern: trimmed)
        }

        // Convert glob `*` and `?` to regular expression
        let escaped = NSRegularExpression.escapedPattern(for: trimmed)
            .replacingOccurrences(of: #"\*"#, with: ".*")
            .replacingOccurrences(of: #"\?"#, with: ".")
        let anchored = "^\(escaped)$"
        return fullString.range(of: anchored, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

public enum ContentRulesEngine {
    /// Returns all enabled `InjectionRule`s matching a given URL.
    public static func matchingInjectionRules(for url: URL, from rules: [InjectionRule]) -> [InjectionRule] {
        rules.filter { $0.isEnabled && URLPatternMatcher.matches(url: url, pattern: $0.urlPattern) }
    }

    /// Generates JavaScript code that injects a `<style>` block safely for a CSS string.
    public static func makeCSSInjectionScript(css: String, ruleID: UUID) -> String? {
        let trimmed = css.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let encodedData = try? JSONEncoder().encode(trimmed)
        let jsonString = encodedData.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
        let elementID = "slidecraft-css-\(ruleID.uuidString.lowercased())"
        return """
        (function() {
            var cssText = \(jsonString);
            function applyStyle() {
                if (document.getElementById("\(elementID)")) return;
                var style = document.createElement("style");
                style.id = "\(elementID)";
                style.textContent = cssText;
                (document.head || document.documentElement).appendChild(style);
            }
            if (document.head || document.documentElement) {
                applyStyle();
            } else {
                document.addEventListener("DOMContentLoaded", applyStyle, { once: true });
            }
        })();
        """
    }

    /// Built-in lightweight ad/tracker blocking rules in WebKit `WKContentRuleList` JSON format.
    public static func makeBuiltInTrackerBlockRules() -> [[String: Any]] {
        [
            [
                "trigger": [
                    "url-filter": "^https?://([a-z0-9-]+\\.)?(doubleclick\\.net|googlesyndication\\.com|googleadservices\\.com|adnxs\\.com|taboola\\.com|outbrain\\.com|criteo\\.com|scorecardresearch\\.com)/",
                    "load-type": ["third-party"]
                ],
                "action": [
                    "type": "block"
                ]
            ],
            [
                "trigger": [
                    "url-filter": ".*",
                    "if-domain": ["*"]
                ],
                "action": [
                    "type": "css-display-none",
                    "selector": ".ad-banner, .adsbygoogle, [id^='google_ads_iframe']"
                ]
            ]
        ]
    }

    /// Compiles `ContentBlockerSettings` into a validated WebKit `WKContentRuleList` JSON string,
    /// or returns `nil` when content blocking is disabled or produces zero rules.
    public static func buildContentRuleListJSON(from settings: ContentBlockerSettings) throws -> String? {
        guard settings.isEnabled else { return nil }
        var rules: [[String: Any]] = []

        if settings.useBuiltInAdBlockRules {
            rules.append(contentsOf: makeBuiltInTrackerBlockRules())
        }

        for rawDomain in settings.blockedDomains {
            let domain = rawDomain
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !domain.isEmpty else { continue }
            let escapedDomain = NSRegularExpression.escapedPattern(for: domain)
            rules.append([
                "trigger": [
                    "url-filter": "^https?://([a-z0-9-]+\\.)?\(escapedDomain)(:|/|$)"
                ],
                "action": [
                    "type": "block"
                ]
            ])
        }

        let customTrimmed = settings.customRuleListJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if !customTrimmed.isEmpty {
            guard let customData = customTrimmed.data(using: .utf8),
                  let customArray = try JSONSerialization.jsonObject(with: customData) as? [[String: Any]] else {
                throw ContentRuleValidationError.invalidCustomJSON
            }
            for entry in customArray {
                guard entry["trigger"] is [String: Any], entry["action"] is [String: Any] else {
                    throw ContentRuleValidationError.missingTriggerOrAction
                }
                rules.append(entry)
            }
        }

        guard !rules.isEmpty else { return nil }
        let encoded = try JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(data: encoded, encoding: .utf8)
    }
}

public enum ContentRuleValidationError: Error, Equatable, Sendable {
    case invalidCustomJSON
    case missingTriggerOrAction
}
