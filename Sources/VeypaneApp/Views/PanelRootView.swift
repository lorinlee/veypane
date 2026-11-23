import AppKit
import SwiftUI
import WebKit
import VeypaneCore

public struct VisualEffectBackground: NSViewRepresentable {
    public var material: NSVisualEffectView.Material
    public var blendingMode: NSVisualEffectView.BlendingMode
    public var cornerRadius: CGFloat?

    public init(
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .withinWindow,
        cornerRadius: CGFloat? = nil
    ) {
        self.material = material
        self.blendingMode = blendingMode
        self.cornerRadius = cornerRadius
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        applyCornerMask(to: view)
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        applyCornerMask(to: nsView)
    }

    private func applyCornerMask(to view: NSVisualEffectView) {
        if let radius = cornerRadius, radius > 0 {
            view.wantsLayer = true
            view.layer?.cornerRadius = radius
            view.layer?.cornerCurve = .continuous
            view.layer?.masksToBounds = true
            view.maskImage = Self.roundedMaskImage(cornerRadius: radius)
        } else {
            view.maskImage = nil
            if view.layer != nil {
                view.layer?.cornerRadius = 0
                view.layer?.masksToBounds = false
            }
        }
    }

    @MainActor
    private static var cachedMaskImages: [Int: NSImage] = [:]

    @MainActor
    private static func roundedMaskImage(cornerRadius: CGFloat) -> NSImage {
        let key = max(1, Int((cornerRadius * 2.0).rounded()))
        if let existing = cachedMaskImages[key] {
            return existing
        }
        let r = CGFloat(key) / 2.0
        let edgeLength = 2.0 * r + 1.0
        let image = NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        cachedMaskImages[key] = image
        return image
    }
}

/// Persistent multi-pad AppKit deck container that keeps active `WKWebView`s mounted at identical bounds
/// and switches pads via `isHidden` without reparenting, viewport resizing, or scroll resets (Outcome 1).
public final class PadDeckContainerNSView: NSView {
    private var mountedByPadID: [UUID: WKWebView] = [:]

    public override func layout() {
        super.layout()
        let targetBounds = bounds
        for webView in mountedByPadID.values where webView.frame != targetBounds {
            webView.frame = targetBounds
        }
    }

    @MainActor
    public func syncDeck(entries: [(padID: UUID, webView: WKWebView)], selectedPadID: UUID?) {
        let activeIDs = Set(entries.map(\.padID))

        // Remove only webViews that were closed, hibernated, or moved to PiP
        for (padID, webView) in Array(mountedByPadID) where !activeIDs.contains(padID) {
            mountedByPadID.removeValue(forKey: padID)
            if webView.superview === self {
                webView.removeFromSuperview()
            }
        }

        // Ensure all active pad webViews are attached once and visibility matches selection
        for (padID, webView) in entries {
            let isSelected = (padID == selectedPadID)
            if webView.superview !== self {
                webView.removeFromSuperview()
                webView.frame = bounds
                webView.autoresizingMask = [.width, .height]
                webView.isHidden = !isSelected
                addSubview(webView)
            } else if webView.isHidden == isSelected {
                webView.isHidden = !isSelected
            }
            mountedByPadID[padID] = webView
        }
    }
}

public struct PadDeckHostView: NSViewRepresentable {
    public var entries: [(padID: UUID, webView: WKWebView)]
    public var selectedPadID: UUID?

    public init(entries: [(padID: UUID, webView: WKWebView)], selectedPadID: UUID?) {
        self.entries = entries
        self.selectedPadID = selectedPadID
    }

    public func makeNSView(context: Context) -> PadDeckContainerNSView {
        let deck = PadDeckContainerNSView()
        deck.wantsLayer = true
        deck.syncDeck(entries: entries, selectedPadID: selectedPadID)
        return deck
    }

    public func updateNSView(_ deck: PadDeckContainerNSView, context: Context) {
        deck.syncDeck(entries: entries, selectedPadID: selectedPadID)
    }
}

private struct ToolbarViewAnchorProbe: NSViewRepresentable {
    var onAttach: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            onAttach(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onAttach(nsView)
        }
    }
}

public struct PanelRootView: View {
    @Bindable var model: AppModel
    public var snapshotWebImage: NSImage?
    public var snapshotCompatibilityIssue: SiteCompatibilityIssueKind?
    public var snapshotCompatibilitySummary: String?

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isTransientOmniboxFocused: Bool
    @State private var lastHandledFocusToken: Int = 0
    @State private var highlightedSuggestionIndex: Int = 0
    @State private var showCustomUASheet: Bool = false
    @State private var customUAInput: String = ""
    @State private var showSiteSizeSheet: Bool = false
    @State private var siteWidthInput: String = ""
    @State private var siteHeightInput: String = ""

    public init(
        model: AppModel,
        snapshotWebImage: NSImage? = nil,
        snapshotCompatibilityIssue: SiteCompatibilityIssueKind? = nil,
        snapshotCompatibilitySummary: String? = nil
    ) {
        self.model = model
        self.snapshotWebImage = snapshotWebImage
        self.snapshotCompatibilityIssue = snapshotCompatibilityIssue
        self.snapshotCompatibilitySummary = snapshotCompatibilitySummary
    }

    @MainActor
    public static func makeHostingView(model: AppModel) -> NSHostingView<PanelRootView> {
        let hostingView = NSHostingView(rootView: PanelRootView(model: model))
        // Keep SlideOverPanel.minSize (320 x 340) as the sole authoritative minimum window bound so
        // dynamic toolbar/extension items never force a wider Auto Layout floor that breaks opposite-side anchoring.
        hostingView.sizingOptions = []
        // Never reserve a synthetic top titlebar safe-area inset above the floating card.
        hostingView.safeAreaRegions = []
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = CGFloat(model.state.settings.appearance.cornerRadius)
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.masksToBounds = true
        return hostingView
    }

    public var body: some View {
        let radius = CGFloat(model.state.settings.appearance.cornerRadius)

        ZStack {
            if snapshotWebImage != nil {
                Color(nsColor: .windowBackgroundColor)
            }
            VisualEffectBackground(
                material: .hudWindow,
                blendingMode: snapshotWebImage != nil ? .withinWindow : .behindWindow,
                cornerRadius: radius
            )

            HStack(spacing: 0) {
                SidebarStripView(model: model)

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: PanelChromeMetrics.sidebarDividerWidth)

                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        minimalPageHeader

                        if let pad = model.selectedPad {
                            compatibilityBannerIfNeeded(for: pad)
                        }

                        if model.isFindBarVisible {
                            findBar
                            Divider()
                        }

                        webContentArea

                        if let status = model.statusMessage, !status.isEmpty {
                            statusBanner(status)
                        }
                    }

                    // Outcome 3: Transient floating address editor (⌘L), never permanently occupying space
                    if model.addressBarState.isEditingCurrentPad {
                        transientAddressOverlay
                            .transition(.opacity.combined(with: .move(edge: .top)))
                            .zIndex(20)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity)
            }
        }
        .ignoresSafeArea()
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(colorScheme == .dark ? 0.11 : 0.36),
                    lineWidth: 0.75
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(
                    Color.black.opacity(colorScheme == .dark ? 0.34 : 0.14),
                    lineWidth: 1
                )
        )
        .onChange(of: model.omniboxFocusToken) { _, newValue in
            if newValue != lastHandledFocusToken {
                lastHandledFocusToken = newValue
                highlightedSuggestionIndex = 0
                if model.addressBarState.isEditingCurrentPad {
                    isTransientOmniboxFocused = true
                }
            }
        }
        .sheet(isPresented: $model.isDiagnosticsSheetPresented) {
            SiteDiagnosticsSheetView(model: model) {
                model.isDiagnosticsSheetPresented = false
            }
        }
        .sheet(isPresented: $showCustomUASheet) {
            VStack(spacing: 14) {
                Text(L10n.string("toolbar.custom_ua_title"))
                    .font(.headline)
                TextField("Mozilla/5.0 …", text: $customUAInput)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
                HStack {
                    Button(L10n.string("common.cancel")) { showCustomUASheet = false }
                    Button(L10n.string("common.apply")) {
                        if let id = model.selectedPad?.id {
                            model.setUserAgentPreset(.custom, custom: customUAInput, for: id)
                        }
                        showCustomUASheet = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showSiteSizeSheet) {
            let padTitle = model.selectedPad?.title ?? ""
            VStack(spacing: 14) {
                Text(L10n.format("panel.size_sheet_title", padTitle))
                    .font(.headline)
                Form {
                    TextField(L10n.string("panel.size_width_pct"), text: $siteWidthInput)
                    TextField(L10n.string("panel.size_height_pct"), text: $siteHeightInput)
                }
                .frame(width: 300)
                HStack {
                    Button(L10n.string("common.reset")) {
                        if let id = model.selectedPad?.id {
                            model.updatePadSizeOverride(nil, for: id)
                        }
                        showSiteSizeSheet = false
                    }
                    Button(L10n.string("common.cancel")) { showSiteSizeSheet = false }
                    Button(L10n.string("common.apply")) {
                        if let id = model.selectedPad?.id {
                            let w = Double(siteWidthInput.trimmingCharacters(in: .whitespaces))
                            let h = Double(siteHeightInput.trimmingCharacters(in: .whitespaces))
                            model.updatePadSizeOverride(PanelSizeOverride(widthPercent: w, heightPercent: h), for: id)
                        }
                        showSiteSizeSheet = false
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
    }

    // MARK: - Outcome 3: Minimal URL-Free Page Header (30 pt, max web content area)

    private var minimalPageHeader: some View {
        let _ = model.webStateRevision
        let _ = model.extensionManager.uiRevision
        let controller = (snapshotWebImage == nil) ? model.selectedPad.flatMap { model.existingWebController(for: $0.id) } : nil
        let pad = model.selectedPad
        let isLoading = controller?.isLoading ?? false
        let progress = controller?.estimatedProgress ?? 0.0
        let extensionItems = model.extensionManager.toolbarItems(for: pad?.id)
        let pinnedExtensions = extensionItems.filter(\.isPinned)
        let effectiveIssue = snapshotCompatibilityIssue ?? controller?.compatibilityIssue ?? .none

        return HStack(spacing: 6) {
            // Back / Forward / Reload — accessible without any permanent URL bar
            HStack(spacing: 2) {
                Button {
                    controller?.goBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!(controller?.canGoBack ?? false))
                .help(L10n.string("toolbar.back"))

                Button {
                    controller?.goForward()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11.5, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(!(controller?.canGoForward ?? false))
                .help(L10n.string("toolbar.forward"))

                Button {
                    if isLoading {
                        controller?.stopLoading()
                    } else if let pad {
                        model.reloadPad(pad.id)
                    }
                } label: {
                    Image(systemName: isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(pad == nil)
                .help(isLoading ? L10n.string("toolbar.stop") : L10n.string("toolbar.reload"))
            }

            // Read-only page title label (never an address input field)
            if let pad {
                Text(pad.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)
                    .padding(.leading, 4)
            }

            Spacer(minLength: 6)

            // Trailing page & extension controls
            HStack(spacing: 3) {
                if effectiveIssue != .none || pad?.pauseCustomModifications == true {
                    Button {
                        model.isDiagnosticsSheetPresented = true
                    } label: {
                        Image(systemName: effectiveIssue != .none ? "exclamationmark.triangle.fill" : "shield.lefthalf.filled.slash")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(effectiveIssue != .none ? Color.orange : Color.secondary)
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("toolbar.site_diagnostics"))
                }

                // Discoverable Open Location button (⌘L)
                Button {
                    model.beginEditingAddress()
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help("\(L10n.string("toolbar.edit_address")) (⌘L)")

                if model.extensionManager.isSupported {
                    ForEach(pinnedExtensions) { extItem in
                        extensionToolbarButton(for: extItem)
                    }
                    extensionOverflowMenu(items: extensionItems)
                }

                Button {
                    model.togglePinnedOpen()
                } label: {
                    Image(systemName: model.state.settings.isPinnedOpen ? "pin.fill" : "pin")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(model.state.settings.isPinnedOpen ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .help(model.state.settings.isPinnedOpen ? L10n.string("toolbar.unpin") : L10n.string("toolbar.pin"))

                Button {
                    model.openSelectedPadInDefaultBrowser()
                } label: {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .disabled(pad == nil)
                .help(L10n.string("toolbar.open_browser"))

                if let pad {
                    moreToolbarMenu(for: pad)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 5)
        .padding(.bottom, 3)
        .frame(height: PanelChromeMetrics.headerBarHeight)
        .background(VisualEffectBackground(material: .headerView, blendingMode: .withinWindow))
        .overlay(alignment: .bottom) {
            if isLoading && progress < 1.0 {
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: max(14, geo.size.width * max(0.06, progress)), height: 2)
                }
                .frame(height: 2)
            } else {
                Rectangle()
                    .fill(Color.primary.opacity(0.09))
                    .frame(height: 1)
            }
        }
    }

    // MARK: - Outcome 3: Transient Floating Address Editor Overlay (`⌘L`)

    private var transientAddressOverlay: some View {
        let draftBinding = Binding<String>(
            get: { model.addressBarState.draftText },
            set: { model.addressBarState.updateDraft($0) }
        )
        let suggestions = AddPadSuggestionEngine.rankSuggestions(
            query: model.addressBarState.draftText,
            favorites: model.state.favorites,
            recentHistory: model.state.recentHistory,
            existingPads: model.state.pads,
            searchEngine: model.state.settings.searchEngine,
            customSearchTemplate: model.state.settings.customSearchTemplate,
            limit: 6
        )

        return ZStack(alignment: .top) {
            // Click-outside scrim cancels and restores underlying webpage untouched
            Color.black.opacity(0.14)
                .ignoresSafeArea()
                .onTapGesture {
                    model.cancelAddressBar()
                }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.accentColor)

                    TextField(L10n.string("toolbar.address_placeholder"), text: draftBinding)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5))
                        .focused($isTransientOmniboxFocused)
                        .onSubmit {
                            if suggestions.indices.contains(highlightedSuggestionIndex),
                               highlightedSuggestionIndex > 0 {
                                applyTransientSuggestion(suggestions[highlightedSuggestionIndex])
                            } else {
                                model.submitOmnibox()
                            }
                            isTransientOmniboxFocused = false
                        }
                        .onKeyPress(.escape) {
                            model.cancelAddressBar()
                            isTransientOmniboxFocused = false
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            guard !suggestions.isEmpty else { return .ignored }
                            highlightedSuggestionIndex = min(suggestions.count - 1, highlightedSuggestionIndex + 1)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            guard !suggestions.isEmpty else { return .ignored }
                            highlightedSuggestionIndex = max(0, highlightedSuggestionIndex - 1)
                            return .handled
                        }

                    Button {
                        model.cancelAddressBar()
                        isTransientOmniboxFocused = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("common.cancel"))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1.2)
                        )
                )

                if !suggestions.isEmpty {
                    VStack(spacing: 2) {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, item in
                            HStack(spacing: 9) {
                                Image(systemName: item.symbolName)
                                    .font(.system(size: 12))
                                    .foregroundStyle(idx == highlightedSuggestionIndex ? Color.accentColor : Color.secondary)
                                    .frame(width: 18)
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(item.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(idx == highlightedSuggestionIndex ? Color.accentColor.opacity(0.14) : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                applyTransientSuggestion(item)
                            }
                        }
                    }
                }

                Text(L10n.string("add_pad.hint"))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }
            .padding(12)
            .frame(maxWidth: 520)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.98))
                    .shadow(color: .black.opacity(0.24), radius: 16, y: 6)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            )
            .padding(.top, 36)
            .padding(.horizontal, 24)
            .onAppear {
                highlightedSuggestionIndex = 0
                isTransientOmniboxFocused = true
            }
        }
    }

    private func applyTransientSuggestion(_ suggestion: AddPadSuggestion) {
        if let existingID = suggestion.existingPadID,
           existingID != model.selectedPad?.id,
           model.state.pads.contains(where: { $0.id == existingID }) {
            model.cancelAddressBar()
            model.selectPad(existingID)
        } else if let currentID = model.selectedPad?.id {
            model.cancelAddressBar()
            model.navigatePad(id: currentID, to: suggestion.url)
        } else {
            model.cancelAddressBar()
            model.addPad(url: suggestion.url, select: true)
        }
    }

    // MARK: - Factual compact status, separate from web content

    @ViewBuilder
    private func compatibilityBannerIfNeeded(for pad: Pad) -> some View {
        let _ = model.webStateRevision
        let wc = (snapshotWebImage == nil) ? model.existingWebController(for: pad.id) : nil
        let issue = snapshotCompatibilityIssue ?? wc?.compatibilityIssue ?? .none
        let dismissed = wc?.isCompatibilityBannerDismissed ?? false

        if issue != .none && !dismissed {
            // Compact, neutral, single-line status strip (sibling in VStack, never covering web content).
            // Never speculates that Google or any site rejected WKWebView or browser extensions.
            let bannerMessage = (issue == .verificationRouteObserved)
                ? L10n.string("compat.banner.title")
                : L10n.string("compat.banner.subtitle")
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(bannerMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L10n.string("compat.action.diagnostics")) {
                    model.isDiagnosticsSheetPresented = true
                }
                .buttonStyle(.link)
                .controlSize(.small)
                Menu {
                    Button(L10n.string("compat.action.open_browser")) {
                        NSWorkspace.shared.open(wc?.webView.url ?? pad.url)
                    }
                    Button(L10n.string("compat.action.retry")) {
                        model.reloadPad(pad.id)
                    }
                    Button(L10n.string("compat.action.copy_link")) {
                        model.copyPadURL(pad.id)
                    }
                    Divider()
                    Button(pad.pauseCustomModifications ? L10n.string("compat.action.mods_paused") : L10n.string("compat.action.pause_mods")) {
                        model.togglePauseCustomModifications(for: pad.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help(L10n.string("toolbar.more"))
                Button {
                    model.dismissCompatibilityBanner(for: pad.id)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L10n.string("common.close"))
                .accessibilityLabel(L10n.string("common.close"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .fixedSize(horizontal: false, vertical: true)
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
            .accessibilityIdentifier("siteCompatibilityBanner")
            // VStack sibling of WKWebView, not a covering overlay/hit-test layer.
        }
    }

    private func moreToolbarMenu(for pad: Pad) -> some View {
        Menu {
            Button("\(L10n.string("toolbar.edit_address")) (⌘L)") {
                model.beginEditingAddress()
            }
            Divider()
            Button(L10n.string("toolbar.zoom_in")) { model.adjustZoom(delta: 0.1) }
            Button(L10n.string("toolbar.zoom_out")) { model.adjustZoom(delta: -0.1) }
            Button(L10n.string("toolbar.zoom_reset")) { model.adjustZoom(delta: nil) }
            Divider()
            Button(L10n.string("toolbar.find")) {
                model.isFindBarVisible = true
            }
            Menu(L10n.string("toolbar.user_agent")) {
                ForEach(UserAgentPreset.allCases.filter { $0 != .custom }) { preset in
                    Button {
                        model.setUserAgentPreset(preset, for: pad.id)
                    } label: {
                        HStack {
                            Text(preset.displayName)
                            if pad.userAgentPreset == preset {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                Button {
                    customUAInput = pad.customUserAgent ?? ""
                    showCustomUASheet = true
                } label: {
                    HStack {
                        Text(L10n.string("toolbar.custom_ua_option"))
                        if pad.userAgentPreset == .custom {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            Button(L10n.string("toolbar.per_site_size")) {
                siteWidthInput = pad.sizeOverride?.widthPercent.map { String(Int($0)) } ?? ""
                siteHeightInput = pad.sizeOverride?.heightPercent.map { String(Int($0)) } ?? ""
                showSiteSizeSheet = true
            }
            Divider()
            Button(pad.pauseCustomModifications ? L10n.string("toolbar.resume_modifications") : L10n.string("toolbar.pause_modifications")) {
                model.togglePauseCustomModifications(for: pad.id)
            }
            Button(L10n.string("toolbar.site_diagnostics")) {
                model.isDiagnosticsSheetPresented = true
            }
            Divider()
            Button(model.activePiPPadIDs.contains(pad.id) ? L10n.string("pad.menu.exit_pip") : L10n.string("pad.menu.pip")) {
                model.togglePiP(for: pad.id)
            }
            Button {
                model.setAlwaysOnTop(!model.state.settings.isAlwaysOnTop)
            } label: {
                HStack {
                    Text(L10n.string("toolbar.always_on_top"))
                    if model.state.settings.isAlwaysOnTop {
                        Image(systemName: "checkmark")
                    }
                }
            }
            Button(pad.isMuted ? L10n.string("toolbar.unmute") : L10n.string("toolbar.mute")) {
                model.toggleMute(for: pad.id)
            }
            Button(pad.isInspectable ? L10n.string("toolbar.inspector_disable") : L10n.string("toolbar.inspector_enable")) {
                model.toggleInspectable(for: pad.id)
            }
            Divider()
            Button(L10n.string("toolbar.copy_url")) {
                model.copyPadURL(pad.id)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.string("toolbar.more"))
    }

    private func extensionToolbarButton(for item: ExtensionToolbarItem) -> some View {
        Button {
            model.extensionManager.performToolbarAction(for: item.id)
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 15, height: 15)
                    } else {
                        Image(systemName: "puzzlepiece.extension.fill")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 24, height: 24)

                if !item.badgeText.isEmpty {
                    Text(String(item.badgeText.prefix(4)))
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 0.5)
                        .background(Capsule().fill(Color.accentColor))
                        .offset(x: 3, y: 2)
                }
            }
        }
        .buttonStyle(.borderless)
        .help(item.tooltip)
        .background(
            ToolbarViewAnchorProbe { nsView in
                model.extensionManager.registerToolbarAnchorView(nsView, for: item.id)
            }
        )
    }

    private func extensionOverflowMenu(items: [ExtensionToolbarItem]) -> some View {
        Menu {
            if items.isEmpty {
                Text(L10n.string("toolbar.no_extensions"))
            } else {
                ForEach(items) { item in
                    Button {
                        model.extensionManager.performToolbarAction(for: item.id)
                    } label: {
                        let labelText = item.badgeText.isEmpty
                            ? item.title
                            : "\(item.title) (\(item.badgeText))"
                        Text(labelText)
                    }
                }
            }
            Divider()
            Button(L10n.string("toolbar.manage_extensions")) {
                model.openSettingsWindow(pane: .extensions)
            }
        } label: {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(items.isEmpty ? Color.secondary.opacity(0.75) : Color.secondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.string("toolbar.extensions"))
        .background(
            ToolbarViewAnchorProbe { nsView in
                model.extensionManager.registerOverflowAnchorView(nsView)
            }
        )
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(L10n.string("find.placeholder"), text: $model.findQuery)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit {
                    model.triggerFind(forward: true)
                }
            Button {
                model.triggerFind(forward: false)
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)

            Button {
                model.triggerFind(forward: true)
            } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.borderless)

            if model.findMatchFound == false && !model.findQuery.isEmpty {
                Text(L10n.string("find.not_found"))
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()
            Button {
                model.isFindBarVisible = false
                model.scheduleWebFocusRestoreIfAppropriate()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.primary.opacity(0.03))
    }

    @ViewBuilder
    private var webContentArea: some View {
        if let snapshotWebImage {
            Image(nsImage: snapshotWebImage)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .background(Color.white)
        } else if !model.areExtensionsReady {
            ProgressView()
                .controlSize(.regular)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            ZStack {
                // Persistent AppKit deck keeps all active pad WKWebViews alive at full size
                PadDeckHostView(
                    entries: model.deckMountedWebViews(),
                    selectedPadID: model.selectedPad?.id
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))

                if let pad = model.selectedPad {
                    if pad.isHibernated {
                        VStack(spacing: 12) {
                            Image(systemName: "moon.zzz.fill")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text(L10n.format("panel.hibernated_title", pad.title))
                                .font(.headline)
                            Text(SiteCompatibilityInspector.sanitizedOrigin(for: pad.url))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                            Button(L10n.string("panel.wake_button")) {
                                model.setHibernated(false, for: pad.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                    } else if model.activePiPPadIDs.contains(pad.id) {
                        VStack(spacing: 12) {
                            Image(systemName: "pip")
                                .font(.system(size: 32))
                                .foregroundStyle(.secondary)
                            Text(L10n.format("panel.pip_title", pad.title))
                                .font(.headline)
                            Button(L10n.string("panel.pip_return")) {
                                model.togglePiP(for: pad.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "sidebar.squares.left")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)
                        Text(L10n.string("panel.empty_title"))
                            .font(.headline)
                        Button(L10n.string("panel.empty_button")) {
                            model.presentNewPadFlow()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
                }
            }
        }
    }

    private func statusBanner(_ message: String) -> some View {
        HStack {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button {
                model.statusMessage = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SiteDiagnosticsSheetView: View {
    @Bindable var model: AppModel
    let onClose: () -> Void

    var body: some View {
        let _ = model.webStateRevision
        let report = model.buildSiteDiagnosticsReport()

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label(L10n.string("compat.diag.window_title"), systemImage: "stethoscope")
                    .font(.headline)
                Spacer()
                Button(L10n.string("compat.diag.refresh")) {
                    Task { @MainActor in
                        await model.refreshSiteDiagnosticsSample()
                    }
                }
                .controlSize(.small)

                Button(L10n.string("compat.diag.copy_report")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report.formattedPlainText(), forType: .string)
                }
                .controlSize(.small)
            }

            ScrollView {
                Text(report.formattedPlainText())
                    .font(.system(size: 11.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(height: 280)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
            )

            Text(L10n.string("compat.diag.privacy_note"))
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button(L10n.string("common.done")) {
                    onClose()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(width: 560)
        .task {
            await model.refreshSiteDiagnosticsSample()
        }
    }
}
