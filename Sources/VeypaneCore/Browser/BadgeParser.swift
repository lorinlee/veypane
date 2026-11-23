import Foundation

public struct ParsedBadge: Equatable, Sendable {
    public var count: Int?
    public var hasUnreadDot: Bool
    public var cleanTitle: String

    public init(count: Int? = nil, hasUnreadDot: Bool = false, cleanTitle: String) {
        self.count = count
        self.hasUnreadDot = hasUnreadDot
        self.cleanTitle = cleanTitle
    }
}

public enum BadgeParser {
    /// Extracts notification counts from web page titles such as `"(3) Inbox"`, `"[12] Messages"`,
    /// `"(99+) Chat"`, `"• Channel — Workspace"`, or `"Inbox (4)"`.
    public static func parse(pageTitle: String) -> ParsedBadge {
        let trimmed = pageTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedBadge(cleanTitle: "")
        }

        // 1. Leading `(12)`, `[12]`, `(1,234+)`, etc.
        if let match = trimmed.range(
            of: #"^[\(\[]\s*([0-9][0-9,]*)\+?\s*[\)\]]\s*"#,
            options: .regularExpression
        ) {
            let prefix = String(trimmed[match])
            if let value = extractPositiveInt(from: prefix) {
                let remainder = String(trimmed[match.upperBound...]).trimmingCharacters(in: .whitespaces)
                return ParsedBadge(
                    count: value,
                    hasUnreadDot: false,
                    cleanTitle: remainder.isEmpty ? trimmed : remainder
                )
            }
        }

        // 2. Leading unread dot indicator `"• Inbox"`, `"● Chat"`, `"* Messages"`
        if let dotMatch = trimmed.range(
            of: #"^[•●◉]\s+"#,
            options: .regularExpression
        ) {
            let remainder = String(trimmed[dotMatch.upperBound...]).trimmingCharacters(in: .whitespaces)
            return ParsedBadge(
                count: nil,
                hasUnreadDot: true,
                cleanTitle: remainder.isEmpty ? trimmed : remainder
            )
        }

        // 3. Trailing count `"Inbox (5)"` — ignore 4-digit numbers in 1900...2099 so `"Report (2026)"` is not misread as unread messages.
        if let trailingMatch = trimmed.range(
            of: #"\s+[\(\[]\s*([0-9][0-9,]*)\+?\s*[\)\]]$"#,
            options: .regularExpression
        ) {
            let suffix = String(trimmed[trailingMatch])
            if let value = extractPositiveInt(from: suffix), !(1900...2099).contains(value) {
                let base = String(trimmed[..<trailingMatch.lowerBound]).trimmingCharacters(in: .whitespaces)
                return ParsedBadge(
                    count: value,
                    hasUnreadDot: false,
                    cleanTitle: base.isEmpty ? trimmed : base
                )
            }
        }

        return ParsedBadge(count: nil, hasUnreadDot: false, cleanTitle: trimmed)
    }

    private static func extractPositiveInt(from bracketed: String) -> Int? {
        let digitsOnly = bracketed.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        let numberString = String(String.UnicodeScalarView(digitsOnly))
        guard let value = Int(numberString), value > 0 else { return nil }
        return value
    }
}
