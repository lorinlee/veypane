import AppKit
import SwiftUI
import VeypaneCore

public struct AddPadPopoverView: View {
    @Bindable var model: AppModel
    public var onClose: () -> Void

    @State private var query: String
    @State private var highlightedIndex: Int = 0
    @FocusState private var isSearchFieldFocused: Bool

    public init(model: AppModel, initialQuery: String = "", onClose: @escaping () -> Void) {
        self.model = model
        self.onClose = onClose
        self._query = State(initialValue: initialQuery)
    }

    private var suggestions: [AddPadSuggestion] {
        AddPadSuggestionEngine.rankSuggestions(
            query: query,
            favorites: model.state.favorites,
            recentHistory: model.state.recentHistory,
            existingPads: model.state.pads,
            searchEngine: model.state.settings.searchEngine,
            customSearchTemplate: model.state.settings.customSearchTemplate,
            limit: 7
        )
    }

    public var body: some View {
        let items = suggestions

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField(L10n.string("add_pad.placeholder"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        commitSelection(items: items)
                    }

                if !query.isEmpty {
                    Button {
                        query = ""
                        highlightedIndex = 0
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.06))
            )

            if !items.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        suggestionRow(item: item, isHighlighted: idx == highlightedIndex)
                            .onTapGesture {
                                highlightedIndex = idx
                                activateSuggestion(item)
                            }
                    }
                }
            }

            Text(L10n.string("add_pad.hint"))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.top, 2)
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            highlightedIndex = 0
            isSearchFieldFocused = true
        }
        .onChange(of: query) { _, _ in
            highlightedIndex = 0
        }
        .onKeyPress(.downArrow) {
            guard !items.isEmpty else { return .ignored }
            highlightedIndex = min(items.count - 1, highlightedIndex + 1)
            return .handled
        }
        .onKeyPress(.upArrow) {
            guard !items.isEmpty else { return .ignored }
            highlightedIndex = max(0, highlightedIndex - 1)
            return .handled
        }
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
    }

    private func suggestionRow(item: AddPadSuggestion, isHighlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.symbolName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isHighlighted ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(isHighlighted ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.05))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            if !item.source.badgeLabel.isEmpty {
                Text(item.source.badgeLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(Color.primary.opacity(0.06))
                    )
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isHighlighted ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func commitSelection(items: [AddPadSuggestion]) {
        if items.indices.contains(highlightedIndex) {
            activateSuggestion(items[highlightedIndex])
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let resolved = OmniboxParser.resolve(
            input: trimmed,
            engine: model.state.settings.searchEngine,
            customTemplate: model.state.settings.customSearchTemplate
        ).url
        model.addPad(url: resolved, select: true)
        onClose()
    }

    private func activateSuggestion(_ suggestion: AddPadSuggestion) {
        if let existingID = suggestion.existingPadID,
           model.state.pads.contains(where: { $0.id == existingID }) {
            model.selectPad(existingID)
        } else {
            let customTitle: String? = (suggestion.source == .directAction) ? nil : suggestion.title
            model.addPad(
                url: suggestion.url,
                title: customTitle,
                symbolName: suggestion.symbolName,
                select: true
            )
        }
        onClose()
    }
}
