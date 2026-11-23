import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VeypaneCore

/// Non-modal AppKit interaction surface for a sidebar pad icon row (`t329`).
/// Uses standard `NSResponder` `mouseDown` / `mouseDragged` / `mouseUp` WITHOUT entering a modal
/// mouse-only tracking loop, so `NSApplication.run()` delivers Escape (`keyCode == 53`) synchronously
/// while the mouse button is held down, and zero UUID strings are ever placed on the drag pasteboard.
@MainActor
private final class SidebarPadInteractionNSView: NSView {
    var onFrameInWindowChanged: ((CGRect) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    var onDragBegan: ((CGFloat) -> Void)?
    var onDragChanged: ((CGFloat) -> Void)?
    var onDragEnded: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var isTrackingMouse = false
    private var didStartDrag = false
    private var downScreenPoint: CGPoint = .zero

    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTrackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil && isTrackingMouse {
            isTrackingMouse = false
            didStartDrag = false
            onDragEnded?()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func reportFrame() {
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return }
        let rectInWindow = convert(bounds, to: nil)
        onFrameInWindowChanged?(rectInWindow)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        didStartDrag = false
        downScreenPoint = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
    }

    override func mouseDragged(with event: NSEvent) {
        guard isTrackingMouse else { return }
        let curScreen = window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
        let dx = curScreen.x - downScreenPoint.x
        let dySwiftUI = downScreenPoint.y - curScreen.y
        let distance = hypot(dx, dySwiftUI)
        if !didStartDrag {
            if distance >= 6.0 {
                didStartDrag = true
                onDragBegan?(dySwiftUI)
            }
        } else {
            onDragChanged?(dySwiftUI)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard isTrackingMouse else { return }
        isTrackingMouse = false
        if didStartDrag {
            didStartDrag = false
            onDragEnded?()
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
    }
}

private struct SidebarPadInteractionOverlay: NSViewRepresentable {
    var tooltip: String
    var onFrameInWindowChanged: (CGRect) -> Void
    var onHoverChanged: (Bool) -> Void
    var onClick: () -> Void
    var onDragBegan: (CGFloat) -> Void
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void

    func makeNSView(context: Context) -> SidebarPadInteractionNSView {
        let v = SidebarPadInteractionNSView()
        applyCallbacks(to: v)
        return v
    }

    func updateNSView(_ nsView: SidebarPadInteractionNSView, context: Context) {
        applyCallbacks(to: nsView)
        DispatchQueue.main.async {
            nsView.reportFrame()
        }
    }

    private func applyCallbacks(to view: SidebarPadInteractionNSView) {
        if view.toolTip != tooltip {
            view.toolTip = tooltip
        }
        view.onFrameInWindowChanged = onFrameInWindowChanged
        view.onHoverChanged = onHoverChanged
        view.onClick = onClick
        view.onDragBegan = onDragBegan
        view.onDragChanged = onDragChanged
        view.onDragEnded = onDragEnded
    }
}

public struct SidebarStripView: View {
    @Bindable var model: AppModel
    @State private var showProfilePopover: Bool = false
    @State private var renamingPad: Pad? = nil
    @State private var renameText: String = ""
    @State private var isTargetedForDrop: Bool = false
    @State private var hoveredPadID: UUID? = nil
    @State private var hoveredBottomAction: String? = nil
    @State private var draggingPadID: UUID? = nil
    @State private var dragStartIndex: Int? = nil
    @State private var dragTargetIndex: Int? = nil
    @State private var dragTranslationY: CGFloat = 0
    @State private var dragStartCancelToken: Int = 0

    public init(model: AppModel) {
        self.model = model
    }

    private var metrics: PanelChromeMetrics {
        PanelChromeMetrics.forAppearance(model.state.settings.appearance)
    }

    private var stripWidth: CGFloat {
        metrics.sidebarStripWidth
    }

    private static let avatarPalette: [(Color, Color)] = [
        (Color(red: 0.20, green: 0.49, blue: 0.95), Color(red: 0.14, green: 0.36, blue: 0.80)),
        (Color(red: 0.08, green: 0.65, blue: 0.50), Color(red: 0.05, green: 0.49, blue: 0.38)),
        (Color(red: 0.90, green: 0.40, blue: 0.24), Color(red: 0.76, green: 0.29, blue: 0.17)),
        (Color(red: 0.52, green: 0.35, blue: 0.90), Color(red: 0.39, green: 0.24, blue: 0.76)),
        (Color(red: 0.84, green: 0.28, blue: 0.50), Color(red: 0.68, green: 0.19, blue: 0.39)),
        (Color(red: 0.14, green: 0.58, blue: 0.76), Color(red: 0.09, green: 0.44, blue: 0.62))
    ]

    public var body: some View {
        let _ = model.faviconCache.revision
        let m = metrics

        ZStack {
            if model.state.settings.appearance.vibrancySidebar {
                VisualEffectBackground(material: .sidebar, blendingMode: .withinWindow)
            } else {
                Color(nsColor: .controlBackgroundColor)
            }

            VStack(spacing: 3) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: m.padRowSpacing) {
                        ForEach(Array(model.state.pads.enumerated()), id: \.element.id) { index, pad in
                            padRow(pad: pad, index: index, metrics: m)
                        }
                    }
                    .coordinateSpace(name: "sidebarPadList")
                    .padding(.top, m.padListTopPadding)
                    .padding(.bottom, m.padListBottomPadding)
                }
                .onChange(of: model.sidebarPadDragCancelToken) { _, _ in
                    if draggingPadID != nil {
                        draggingPadID = nil
                        dragStartIndex = nil
                        dragTargetIndex = nil
                        dragTranslationY = 0
                        model.isSidebarPadDragActive = false
                    }
                }

                Spacer(minLength: 4)

                // "+" Add-Pad Button (sleek hover-only pill inside full hit target)
                Button {
                    if model.isAddPadPopoverPresented {
                        model.cancelAddressBar()
                    } else {
                        model.addressBarState.openForNewPad()
                        model.omniboxFocusToken &+= 1
                    }
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: m.padHighlightCornerRadius, style: .continuous)
                            .fill(
                                hoveredBottomAction == "add"
                                    ? Color.primary.opacity(0.08)
                                    : Color.clear
                            )
                            .frame(width: m.addButtonVisualSize, height: m.addButtonVisualSize)

                        Image(systemName: "plus")
                            .font(.system(size: m.addButtonGlyphSize, weight: .medium))
                            .foregroundStyle(hoveredBottomAction == "add" ? .primary : .secondary)
                    }
                    .frame(width: m.padHitTargetWidth, height: m.addButtonHitHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredBottomAction = hovering ? "add" : (hoveredBottomAction == "add" ? nil : hoveredBottomAction)
                }
                .help(L10n.string("strip.add_pad_tooltip"))
                .accessibilityLabel(L10n.string("strip.add_pad_tooltip"))
                .popover(
                    isPresented: Binding(
                        get: { model.isAddPadPopoverPresented },
                        set: { presented in
                            if !presented { model.cancelAddressBar() }
                        }
                    ),
                    arrowEdge: .trailing
                ) {
                    AddPadPopoverView(model: model) {
                        model.cancelAddressBar()
                    }
                }

                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(width: max(16, m.sidebarStripWidth - m.dividerHorizontalInset * 2), height: 1)
                    .padding(.vertical, 2)

                // Profile Switcher Button
                Button {
                    showProfilePopover.toggle()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: m.padHighlightCornerRadius, style: .continuous)
                            .fill(hoveredBottomAction == "profile" ? Color.primary.opacity(0.07) : Color.clear)
                            .frame(width: m.bottomActionVisualSize, height: m.bottomActionVisualSize)

                        Image(systemName: activeProfileSymbol)
                            .font(.system(size: m.bottomActionGlyphSize, weight: .medium))
                            .foregroundStyle(hoveredBottomAction == "profile" ? .primary : .secondary)
                    }
                    .frame(width: m.padHitTargetWidth, height: m.bottomActionHitHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredBottomAction = hovering ? "profile" : (hoveredBottomAction == "profile" ? nil : hoveredBottomAction)
                }
                .help(L10n.string("strip.profiles_tooltip"))
                .accessibilityLabel(L10n.string("strip.profiles_tooltip"))
                .popover(isPresented: $showProfilePopover, arrowEdge: .trailing) {
                    profileSwitcherPopover
                }

                // Settings Gear Button
                Button {
                    model.openSettingsWindow()
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: m.padHighlightCornerRadius, style: .continuous)
                            .fill(hoveredBottomAction == "settings" ? Color.primary.opacity(0.07) : Color.clear)
                            .frame(width: m.bottomActionVisualSize, height: m.bottomActionVisualSize)

                        Image(systemName: "gearshape")
                            .font(.system(size: m.bottomActionGlyphSize, weight: .medium))
                            .foregroundStyle(hoveredBottomAction == "settings" ? .primary : .secondary)
                    }
                    .frame(width: m.padHitTargetWidth, height: m.bottomActionHitHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    hoveredBottomAction = hovering ? "settings" : (hoveredBottomAction == "settings" ? nil : hoveredBottomAction)
                }
                .padding(.bottom, m.bottomPadding)
                .help(L10n.string("strip.settings_tooltip"))
                .accessibilityLabel(L10n.string("strip.settings_tooltip"))
            }
        }
        .frame(width: m.sidebarStripWidth)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isTargetedForDrop ? Color.accentColor : .clear, lineWidth: 2)
        )
        .onDrop(of: [.url, .fileURL, .plainText], isTargeted: $isTargetedForDrop) { providers in
            handleDroppedProviders(providers)
        }
        .sheet(item: $renamingPad) { pad in
            VStack(spacing: 14) {
                Text(L10n.string("pad.rename_title"))
                    .font(.headline)
                TextField(L10n.string("pad.rename_placeholder"), text: $renameText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 250)
                    .onSubmit {
                        model.renamePad(pad.id, newTitle: renameText)
                        renamingPad = nil
                    }
                HStack {
                    Button(L10n.string("common.cancel")) { renamingPad = nil }
                    Button(L10n.string("common.save")) {
                        model.renamePad(pad.id, newTitle: renameText)
                        renamingPad = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(20)
        }
    }

    private var activeProfileSymbol: String {
        model.state.profiles.first(where: { $0.id == model.state.activeProfileID })?.symbolName ?? "person.crop.circle"
    }

    private func padRow(pad: Pad, index: Int, metrics m: PanelChromeMetrics) -> some View {
        let isSelected = (pad.id == model.state.selectedPadID)
        let isHovered = (hoveredPadID == pad.id)
        let isDragging = (draggingPadID == pad.id)
        let showDropBeforeIndicator = (draggingPadID != nil && !isDragging && dragTargetIndex == index && (dragStartIndex ?? index) > index)
        let showDropAfterIndicator = (draggingPadID != nil && !isDragging && dragTargetIndex == index && (dragStartIndex ?? index) < index)
        let host = pad.url.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        let tooltipText = host.isEmpty || pad.title.lowercased() == host.lowercased()
            ? pad.title
            : "\(pad.title) — \(host)"

        return ZStack(alignment: .leading) {
            // Crisp slim leading vertical accent indicator bar (visual only, never blocks left resize edge)
            Capsule()
                .fill(isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.24) : Color.clear))
                .frame(
                    width: m.selectionIndicatorWidth,
                    height: isSelected ? m.selectionIndicatorSelectedHeight : (isHovered ? m.selectionIndicatorHoveredHeight : 0)
                )
                .padding(.leading, m.selectionIndicatorLeadingInset)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.14), value: isSelected)
                .animation(.easeOut(duration: 0.12), value: isHovered)

            // Interactive hit area cleanly separated from compact visual icon footprint
            ZStack {
                RoundedRectangle(cornerRadius: m.padHighlightCornerRadius, style: .continuous)
                    .fill(
                        isSelected
                            ? Color.accentColor.opacity(0.09)
                            : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                    )
                    .frame(width: m.padHighlightSize, height: m.padHighlightSize)

                padAvatarView(for: pad, metrics: m)
                    .opacity(pad.isHibernated ? 0.50 : 1.0)
                    .overlay(alignment: .topTrailing) {
                        // Non-jumping badge overlay outside layout sizing
                        unreadBadgeOverlay(for: pad)
                            .allowsHitTesting(false)
                    }
            }
            .frame(width: m.padHitTargetWidth, height: m.padHitTargetHeight)
            .contentShape(Rectangle())
            .frame(maxWidth: .infinity, alignment: .center)
            .overlay(
                SidebarPadInteractionOverlay(
                    tooltip: tooltipText,
                    onFrameInWindowChanged: { rectInWindow in
                        model.sidebarPadFramesInWindow[pad.id] = rectInWindow
                    },
                    onHoverChanged: { hovering in
                        hoveredPadID = hovering ? pad.id : (hoveredPadID == pad.id ? nil : hoveredPadID)
                    },
                    onClick: {
                        model.selectPad(pad.id)
                    },
                    onDragBegan: { dySwiftUI in
                        draggingPadID = pad.id
                        dragStartCancelToken = model.sidebarPadDragCancelToken
                        let startIdx = model.state.pads.firstIndex(where: { $0.id == pad.id }) ?? index
                        dragStartIndex = startIdx
                        let slotStep = m.padRowPitch
                        let deltaSlots = Int((dySwiftUI / slotStep).rounded())
                        dragTargetIndex = min(max(0, startIdx + deltaSlots), max(0, model.state.pads.count - 1))
                        dragTranslationY = dySwiftUI
                        model.isSidebarPadDragActive = true
                    },
                    onDragChanged: { dySwiftUI in
                        guard draggingPadID == pad.id, let startIdx = dragStartIndex else { return }
                        guard model.sidebarPadDragCancelToken == dragStartCancelToken else {
                            dragTranslationY = 0
                            dragTargetIndex = startIdx
                            return
                        }
                        dragTranslationY = dySwiftUI
                        let slotStep = m.padRowPitch
                        let deltaSlots = Int((dySwiftUI / slotStep).rounded())
                        dragTargetIndex = min(max(0, startIdx + deltaSlots), max(0, model.state.pads.count - 1))
                    },
                    onDragEnded: {
                        if draggingPadID == pad.id {
                            let wasCancelled = (model.sidebarPadDragCancelToken != dragStartCancelToken)
                            if !wasCancelled,
                               let startIdx = dragStartIndex,
                               let targetIdx = dragTargetIndex,
                               startIdx != targetIdx {
                                model.movePad(id: pad.id, toIndex: targetIdx)
                            }
                        }
                        draggingPadID = nil
                        dragStartIndex = nil
                        dragTargetIndex = nil
                        dragTranslationY = 0
                        model.isSidebarPadDragActive = false
                    }
                )
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tooltipText)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
            .accessibilityAction {
                model.selectPad(pad.id)
            }
            .contextMenu {
                Button(L10n.string("pad.menu.reload")) {
                    model.reloadPad(pad.id)
                }
                Button(L10n.string("pad.menu.copy_url")) {
                    model.copyPadURL(pad.id)
                }
                Button(L10n.string("pad.menu.open_browser")) {
                    NSWorkspace.shared.open(pad.url)
                }
                Divider()
                Button(L10n.string("pad.menu.rename")) {
                    renameText = pad.title
                    renamingPad = pad
                }
                if pad.hasCustomTitle {
                    Button(L10n.string("pad.menu.use_page_title")) {
                        model.resetPadCustomTitle(pad.id)
                    }
                }
                Button(pad.isHibernated ? L10n.string("pad.menu.wake") : L10n.string("pad.menu.hibernate")) {
                    model.setHibernated(!pad.isHibernated, for: pad.id)
                }
                Button(model.activePiPPadIDs.contains(pad.id) ? L10n.string("pad.menu.exit_pip") : L10n.string("pad.menu.pip")) {
                    model.togglePiP(for: pad.id)
                }
                Divider()
                Button(L10n.string("pad.menu.remove"), role: .destructive) {
                    model.removePad(pad.id)
                }
            }
        }
        .frame(width: m.sidebarStripWidth, height: m.padHitTargetHeight)
        .overlay(alignment: .top) {
            if showDropBeforeIndicator {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(18, m.sidebarStripWidth - 12), height: 2.5)
                    .offset(y: -3)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if showDropAfterIndicator {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: max(18, m.sidebarStripWidth - 12), height: 2.5)
                    .offset(y: 3)
                    .allowsHitTesting(false)
            }
        }
        .offset(y: isDragging ? dragTranslationY : 0)
        .scaleEffect(isDragging ? 1.06 : 1.0)
        .shadow(color: isDragging ? .black.opacity(0.22) : .clear, radius: 6, y: 2)
        .zIndex(isDragging ? 50 : 0)
    }

    @ViewBuilder
    private func unreadBadgeOverlay(for pad: Pad) -> some View {
        if let count = pad.badgeCount, count > 0 {
            Text(count > 99 ? "99+" : "\(count)")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 3.0)
                .padding(.vertical, 0.5)
                .background(
                    Capsule()
                        .fill(Color(red: 0.92, green: 0.24, blue: 0.24))
                        .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                )
                .offset(x: 4, y: -3)
        } else if pad.hasUnreadDot {
            Circle()
                .fill(Color(red: 0.92, green: 0.24, blue: 0.24))
                .frame(width: 6.5, height: 6.5)
                .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.0))
                .offset(x: 2, y: -2)
        }
    }

    @ViewBuilder
    private func padAvatarView(for pad: Pad, metrics m: PanelChromeMetrics) -> some View {
        if let cachedImage = model.faviconCache.image(for: pad) {
            Image(nsImage: cachedImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .scaledToFit()
                .frame(width: m.padVisualIconSize, height: m.padVisualIconSize)
                .clipShape(RoundedRectangle(cornerRadius: m.padIconCornerRadius, style: .continuous))
        } else {
            monogramPlaceholder(for: pad, metrics: m)
        }
    }

    private func monogramPlaceholder(for pad: Pad, metrics m: PanelChromeMetrics) -> some View {
        let seed = (pad.url.host ?? pad.title).unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
        let pair = Self.avatarPalette[abs(seed) % Self.avatarPalette.count]
        return ZStack {
            RoundedRectangle(cornerRadius: m.padIconCornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [pair.0, pair.1],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Text(pad.fallbackInitial)
                .font(.system(size: m.padVisualIconSize * 0.50, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
        }
        .frame(width: m.padVisualIconSize, height: m.padVisualIconSize)
    }

    private var profileSwitcherPopover: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("strip.profiles_title"))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)

            ForEach(model.state.profiles) { profile in
                let isCurrent = (model.state.activeProfileID == profile.id)
                Button {
                    model.switchActiveProfile(profile.id)
                    showProfilePopover = false
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: profile.symbolName)
                            .frame(width: 16)
                        Text(profile.name)
                            .font(.system(size: 12.5))
                        Spacer()
                        if isCurrent {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }

            Divider()

            Button {
                showProfilePopover = false
                model.openSettingsWindow(pane: .padsProfiles)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 16)
                    Text(L10n.string("strip.manage_profiles"))
                        .font(.system(size: 12))
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 205)
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard draggingPadID == nil, !model.isSidebarPadDragActive else { return false }
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let droppedURL: URL? = if let url = item as? URL {
                    url
                } else if let data = item as? Data {
                    URL(dataRepresentation: data, relativeTo: nil)
                } else {
                    nil
                }
                if let droppedURL {
                    Task { @MainActor in
                        model.addPad(url: droppedURL, select: true)
                    }
                }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let raw: String? = if let str = item as? String {
                    str
                } else if let data = item as? Data {
                    String(data: data, encoding: .utf8)
                } else {
                    nil
                }
                if let raw {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Never turn an internal pad UUID or non-URL string into a surprise new tab/pad
                    guard !trimmed.isEmpty, UUID(uuidString: trimmed) == nil else { return }
                    guard case .directURL(let droppedURL) = OmniboxParser.resolve(input: trimmed) else { return }
                    Task { @MainActor in
                        model.addPad(url: droppedURL, select: true)
                    }
                }
            }
            return true
        }
        return false
    }
}
