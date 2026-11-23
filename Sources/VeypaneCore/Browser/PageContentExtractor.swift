import Foundation

/// Unit-testable seam representing a Pad's web session for `/v1/pads/content` and MCP `get_page_content`.
public protocol WebPageContentSession: Sendable {
    func ensureLoadedAndWaitUntilReady(timeoutSeconds: TimeInterval) async -> Bool
    func currentTitle() async -> String?
    func currentURL() async -> URL?
    func extractBodyInnerText() async -> String?
    func extractDocumentTextContent() async -> String?
}

public enum PageContentExtractor {
    public static let defaultTimeoutSeconds: TimeInterval = 10.0
    public static let maxTextLength: Int = 16_000

    /// Ensures the page finishes loading (within `timeoutSeconds`), extracts `document.body.innerText`,
    /// falls back to `document.documentElement.textContent` when empty, and throws `pageLoadTimedOut` on timeout.
    public static func extractSnapshot(
        padID: String,
        fallbackTitle: String,
        fallbackURL: URL,
        session: any WebPageContentSession,
        timeoutSeconds: TimeInterval = defaultTimeoutSeconds,
        maxCharacters: Int = maxTextLength
    ) async throws -> AutomationPageSnapshot {
        let ready = await session.ensureLoadedAndWaitUntilReady(timeoutSeconds: timeoutSeconds)

        let liveTitle = (await session.currentTitle())?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (liveTitle?.isEmpty == false) ? liveTitle! : fallbackTitle
        let resolvedURL = (await session.currentURL())?.absoluteString ?? fallbackURL.absoluteString

        guard ready else {
            throw AutomationBridgeError.pageLoadTimedOut(
                title: resolvedTitle,
                url: resolvedURL,
                timeoutSeconds: timeoutSeconds
            )
        }

        let rawInner = (await session.extractBodyInnerText()) ?? ""
        let cleanedInner = normalizeExtractedText(rawInner, maxCharacters: maxCharacters)
        if !cleanedInner.isEmpty {
            return AutomationPageSnapshot(
                padID: padID,
                title: resolvedTitle,
                url: resolvedURL,
                text: cleanedInner
            )
        }

        let rawFallback = (await session.extractDocumentTextContent()) ?? ""
        let cleanedFallback = normalizeExtractedText(rawFallback, maxCharacters: maxCharacters)
        return AutomationPageSnapshot(
            padID: padID,
            title: resolvedTitle,
            url: resolvedURL,
            text: cleanedFallback
        )
    }

    public static func normalizeExtractedText(_ raw: String, maxCharacters: Int = maxTextLength) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.count <= maxCharacters {
            return trimmed
        }
        return String(trimmed.prefix(maxCharacters))
    }
}
