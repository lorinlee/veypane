import Foundation

public enum AddressBarMode: Equatable, Sendable {
    /// Default browsing state for existing pads: no URL text field is shown, maximizing web viewport height.
    case hidden
    /// Transient omnibox entry when creating a new pad (`+` button or `⌘T`).
    case creatingNewPad(draftText: String)
    /// Transient omnibox overlay for editing the current pad's URL (`⌘L` or menu action).
    case editingCurrentPad(padID: UUID, originalURL: String, draftText: String)
}

public enum AddressBarSubmitEffect: Equatable, Sendable {
    case none
    case createNewPad(URL)
    case navigateExistingPad(padID: UUID, url: URL)
}

/// Pure, unit-testable state machine governing the transient address/search entry (Round 5 Outcome 3).
/// Ensures SwiftUI view redraws or draft edits never trigger accidental navigations.
public struct AddressBarStateMachine: Equatable, Sendable {
    public private(set) var mode: AddressBarMode = .hidden

    public init(mode: AddressBarMode = .hidden) {
        self.mode = mode
    }

    public var isVisible: Bool {
        mode != .hidden
    }

    public var isCreatingNewPad: Bool {
        if case .creatingNewPad = mode { return true }
        return false
    }

    public var isEditingCurrentPad: Bool {
        if case .editingCurrentPad = mode { return true }
        return false
    }

    public var draftText: String {
        switch mode {
        case .hidden:
            return ""
        case .creatingNewPad(let draftText):
            return draftText
        case .editingCurrentPad(_, _, let draftText):
            return draftText
        }
    }

    public var editingPadID: UUID? {
        if case .editingCurrentPad(let padID, _, _) = mode {
            return padID
        }
        return nil
    }

    public var originalURLString: String? {
        if case .editingCurrentPad(_, let originalURL, _) = mode {
            return originalURL
        }
        return nil
    }

    public mutating func openForNewPad(initialDraft: String = "") {
        mode = .creatingNewPad(draftText: initialDraft)
    }

    public mutating func revealForCurrentPad(padID: UUID, currentURL: URL) {
        let urlString = currentURL.absoluteString
        mode = .editingCurrentPad(padID: padID, originalURL: urlString, draftText: urlString)
    }

    /// Updates draft text without triggering any navigation side effects.
    public mutating func updateDraft(_ newDraft: String) {
        switch mode {
        case .hidden:
            break
        case .creatingNewPad:
            mode = .creatingNewPad(draftText: newDraft)
        case .editingCurrentPad(let padID, let originalURL, _):
            mode = .editingCurrentPad(padID: padID, originalURL: originalURL, draftText: newDraft)
        }
    }

    /// Cancels transient entry (`Esc` or click-outside), restoring the underlying webpage untouched.
    public mutating func cancel() {
        mode = .hidden
    }

    /// Dismisses transient editing if the user switches to a different pad without submitting.
    public mutating func handleSelectedPadChanged(to newPadID: UUID?) {
        if case .editingCurrentPad(let editingID, _, _) = mode, editingID != newPadID {
            mode = .hidden
        }
    }

    /// Commits the current draft on explicit user Return, dismissing the transient bar immediately.
    public mutating func submit(
        searchEngine: SearchEnginePreset = .duckDuckGo,
        customSearchTemplate: String? = nil
    ) -> AddressBarSubmitEffect {
        switch mode {
        case .hidden:
            return .none

        case .creatingNewPad(let draft):
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .none }
            let resolved = OmniboxParser.resolve(
                input: trimmed,
                engine: searchEngine,
                customTemplate: customSearchTemplate
            ).url
            mode = .hidden
            return .createNewPad(resolved)

        case .editingCurrentPad(let padID, _, let draft):
            let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .none }
            let resolved = OmniboxParser.resolve(
                input: trimmed,
                engine: searchEngine,
                customTemplate: customSearchTemplate
            ).url
            mode = .hidden
            return .navigateExistingPad(padID: padID, url: resolved)
        }
    }
}
