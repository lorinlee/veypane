import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import VeypaneCore

// MARK: - Interactive Screen Edge & Corner Picker Diagram (S8 & S9)

public struct ScreenAnchorDiagramView: View {
    @Binding public var selectedAnchor: AnchorPosition
    public var widthPercent: Double
    public var heightPercent: Double
    public var compact: Bool

    public init(
        selectedAnchor: Binding<AnchorPosition>,
        widthPercent: Double = 66.0,
        heightPercent: Double = 76.0,
        compact: Bool = false
    ) {
        self._selectedAnchor = selectedAnchor
        self.widthPercent = widthPercent
        self.heightPercent = heightPercent
        self.compact = compact
    }

    public var body: some View {
        let boxWidth: CGFloat = compact ? 230 : 280
        let boxHeight: CGFloat = compact ? 136 : 168

        VStack(spacing: 6) {
            ZStack {
                // Monitor bezel + wallpaper gradient
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(0.16),
                                Color.primary.opacity(0.06)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.22), lineWidth: 1.5)
                    )

                // Top macOS menu bar hint
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 12)
                    Spacer()
                }
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                // Live miniature preview of the slide-over card inside the screen
                GeometryReader { geo in
                    let inset: CGFloat = 10
                    let availW = geo.size.width - inset * 2
                    let availH = geo.size.height - 12 - inset * 2
                    let cardW = max(50, availW * CGFloat(min(max(widthPercent, 20), 92) / 100.0))
                    let cardH = max(44, availH * CGFloat(min(max(heightPercent, 25), 95) / 100.0))

                    let cardX: CGFloat = selectedAnchor.isLeftAligned
                        ? inset
                        : (geo.size.width - cardW - inset)
                    let cardY: CGFloat = switch selectedAnchor {
                    case .topLeft, .topRight: 12 + inset
                    case .bottomLeft, .bottomRight: geo.size.height - cardH - inset
                    case .left, .right: 12 + inset + (availH - cardH) / 2.0
                    }

                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(.regularMaterial)
                        .overlay(
                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.accentColor.opacity(0.22))
                                    .frame(width: 12)
                                Spacer()
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 1.5)
                        )
                        .shadow(color: .black.opacity(0.14), radius: 4, y: 2)
                        .frame(width: cardW, height: cardH)
                        .position(x: cardX + cardW / 2, y: cardY + cardH / 2)
                        .animation(.easeOut(duration: 0.18), value: selectedAnchor)
                        .animation(.easeOut(duration: 0.12), value: widthPercent)
                        .animation(.easeOut(duration: 0.12), value: heightPercent)
                }

                // Interactive clickable edge & corner targets
                anchorTargetsOverlay
            }
            .frame(width: boxWidth, height: boxHeight)

            Text(selectedAnchor.displayName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Color.accentColor)
        }
    }

    private var anchorTargetsOverlay: some View {
        ZStack {
            // Left Edge
            HStack {
                edgePill(for: .left, vertical: true)
                Spacer()
                edgePill(for: .right, vertical: true)
            }
            .padding(.horizontal, 3)

            // Four Corners
            VStack {
                HStack {
                    cornerDot(for: .topLeft)
                    Spacer()
                    cornerDot(for: .topRight)
                }
                Spacer()
                HStack {
                    cornerDot(for: .bottomLeft)
                    Spacer()
                    cornerDot(for: .bottomRight)
                }
            }
            .padding(5)
        }
    }

    private func edgePill(for anchor: AnchorPosition, vertical: Bool) -> some View {
        let active = (selectedAnchor == anchor)
        return Button {
            selectedAnchor = anchor
        } label: {
            Capsule()
                .fill(active ? Color.accentColor : Color.primary.opacity(0.22))
                .frame(width: vertical ? 7 : 54, height: vertical ? 54 : 7)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(anchor.displayName)
    }

    private func cornerDot(for anchor: AnchorPosition) -> some View {
        let active = (selectedAnchor == anchor)
        return Button {
            selectedAnchor = anchor
        } label: {
            Circle()
                .fill(active ? Color.accentColor : Color.primary.opacity(0.26))
                .frame(width: 13, height: 13)
                .overlay(
                    Circle()
                        .strokeBorder(Color.white.opacity(active ? 0.9 : 0.0), lineWidth: 1.5)
                )
                .padding(4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(anchor.displayName)
    }
}

// MARK: - Hotkey Recorder Button (S8)

struct HotkeyRecorderControl: View {
    var currentBinding: HotkeyBinding
    var onRecorded: (HotkeyBinding) -> Void

    @State private var isRecording: Bool = false
    @State private var monitorToken: Any? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(isRecording ? L10n.string("settings.trigger.press_keys") : currentBinding.displayString)
                .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isRecording ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07))
                )

            Button(isRecording ? L10n.string("common.cancel") : L10n.string("settings.trigger.record_hotkey")) {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            }

            Button(L10n.string("settings.trigger.reset_hotkey")) {
                stopRecording()
                onRecorded(.defaultToggle)
            }
            .controlSize(.small)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        stopRecording()
        isRecording = true
        monitorToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Esc cancels recording
                stopRecording()
                return nil
            }
            let mods = EdgeMonitorController.activeModifiers(from: event.modifierFlags)
            let code = UInt32(event.keyCode)
            let isFnKey = [UInt32(0x7A), 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F].contains(code)
            guard !mods.isEmpty || isFnKey else {
                return nil
            }
            let binding = HotkeyBinding(keyCode: code, modifiers: mods)
            onRecorded(binding)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let token = monitorToken {
            NSEvent.removeMonitor(token)
            monitorToken = nil
        }
    }
}

// MARK: - SettingsView (NavigationSplitView — S8)

public struct SettingsView: View {
    @Bindable var model: AppModel

    @State private var newProfileName: String = ""
    @State private var newRuleHost: String = ""
    @State private var newRuleWidthPct: String = "50"
    @State private var newRuleHeightPct: String = "80"

    @State private var newBlockedDomain: String = ""
    @State private var newInjName: String = ""
    @State private var newInjPattern: String = "*://*/*"
    @State private var newInjCSS: String = ""
    @State private var newInjJS: String = ""
    @State private var newInjTime: ScriptInjectionTime = .atDocumentEnd

    @State private var showTriggerAdvanced: Bool = false
    @State private var showAppearanceAdvanced: Bool = false
    @State private var showBackupAdvanced: Bool = false
    @State private var showPrivacyAdvanced: Bool = false
    @State private var showAutomationCLI: Bool = false
    @State private var extensionInstallError: String? = nil
    @State private var pendingRemovalExtension: ExtensionSettingsItem? = nil
    @State private var hoveredSidebarPane: SettingsPaneID? = nil

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Native accessible sidebar without NSTableRowView(.sourceList) CAFilter backdrop black artifact
            VStack(alignment: .leading, spacing: 3) {
                ForEach(SettingsPaneID.allCases) { pane in
                    let isSelected = (model.state.settings.selectedSettingsPane == pane)
                    let isHovered = (hoveredSidebarPane == pane)

                    Button {
                        model.state.settings.selectedSettingsPane = pane
                        model.persistState()
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: pane.symbolName)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                                .frame(width: 18, alignment: .center)

                            Text(pane.localizedTitle)
                                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(
                                    isSelected
                                        ? Color(nsColor: .controlAccentColor)
                                        : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                                )
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        hoveredSidebarPane = hovering ? pane : (hoveredSidebarPane == pane ? nil : hoveredSidebarPane)
                    }
                    .accessibilityLabel(pane.localizedTitle)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }

                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: 196)
            .frame(maxHeight: .infinity)
            .background(
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    Color.primary.opacity(0.03)
                }
            )
            .accessibilityElement(children: .contain)

            Divider()

            detailPane(for: model.state.settings.selectedSettingsPane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 680, minHeight: 480)
        .onKeyPress(.upArrow) {
            stepSidebarSelection(delta: -1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            stepSidebarSelection(delta: 1)
            return .handled
        }
    }

    private func stepSidebarSelection(delta: Int) {
        let all = SettingsPaneID.allCases
        guard let currentIndex = all.firstIndex(of: model.state.settings.selectedSettingsPane) else { return }
        let nextIndex = min(max(0, currentIndex + delta), all.count - 1)
        guard nextIndex != currentIndex else { return }
        model.state.settings.selectedSettingsPane = all[nextIndex]
        model.persistState()
    }

    @ViewBuilder
    private func detailPane(for pane: SettingsPaneID) -> some View {
        switch pane {
        case .general:
            generalPane
        case .trigger:
            triggerPane
        case .appearance:
            appearancePane
        case .padsProfiles:
            padsAndProfilesPane
        case .extensions:
            extensionsPane
        case .privacyBlocking:
            privacyAndBlockingPane
        case .automation:
            automationPane
        case .about:
            aboutPane
        }
    }

    // MARK: - 1. General

    private var generalPane: some View {
        Form {
            Section(L10n.string("settings.general.startup")) {
                Toggle(L10n.string("settings.general.launch_at_login"), isOn: Binding(
                    get: { model.state.settings.appearance.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))

                Toggle(L10n.string("settings.general.show_menu_icon"), isOn: $model.state.settings.appearance.showMenuBarIcon)
                    .onChange(of: model.state.settings.appearance.showMenuBarIcon) { _, _ in
                        model.persistState()
                        NotificationCenter.default.post(name: .veypaneMenuBarVisibilityChanged, object: nil)
                    }
            }

            Section(L10n.string("settings.general.browsing")) {
                Picker(L10n.string("settings.general.search_engine"), selection: $model.state.settings.searchEngine) {
                    ForEach(SearchEnginePreset.allCases) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .onChange(of: model.state.settings.searchEngine) { _, _ in model.persistState() }

                if model.state.settings.searchEngine == .custom {
                    TextField(L10n.string("settings.general.custom_search"), text: $model.state.settings.customSearchTemplate)
                        .onSubmit { model.persistState() }
                }

                Picker(L10n.string("settings.general.new_links"), selection: $model.state.settings.newWindowBehavior) {
                    ForEach(NewWindowBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                .onChange(of: model.state.settings.newWindowBehavior) { _, _ in model.persistState() }

                Toggle(L10n.string("settings.general.cmd_w_hides"), isOn: $model.state.settings.commandWHidesPanel)
                    .onChange(of: model.state.settings.commandWHidesPanel) { _, _ in model.persistState() }
            }

            Section(L10n.string("settings.general.language")) {
                Text(L10n.string("settings.general.language_caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 2. Trigger

    private var triggerPane: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    ScreenAnchorDiagramView(
                        selectedAnchor: Binding(
                            get: { model.state.settings.anchor },
                            set: { newAnchor in
                                model.state.settings.anchor = newAnchor
                                model.refreshPanelGeometryAndAppearance()
                                model.persistState()
                            }
                        ),
                        widthPercent: model.state.settings.widthPercent,
                        heightPercent: model.state.settings.heightPercent
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)

                    Text(L10n.string("settings.trigger.diagram_caption"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(L10n.string("settings.trigger.enable_hot_edge"), isOn: $model.state.settings.edgeTrigger.isEnabled)
                    .onChange(of: model.state.settings.edgeTrigger.isEnabled) { _, _ in model.persistState() }

                Stepper(
                    "\(L10n.string("settings.trigger.dwell_delay")): \(model.state.settings.edgeTrigger.dwellMilliseconds) ms",
                    value: $model.state.settings.edgeTrigger.dwellMilliseconds,
                    in: 0...1200,
                    step: 20
                )
                .onChange(of: model.state.settings.edgeTrigger.dwellMilliseconds) { _, _ in model.persistState() }

                Stepper(
                    "\(L10n.string("settings.trigger.hide_delay")): \(model.state.settings.edgeTrigger.dismissGraceMilliseconds) ms",
                    value: $model.state.settings.edgeTrigger.dismissGraceMilliseconds,
                    in: 100...2500,
                    step: 50
                )
                .onChange(of: model.state.settings.edgeTrigger.dismissGraceMilliseconds) { _, _ in model.persistState() }
            } header: {
                Text(L10n.string("settings.trigger.position"))
            }

            Section {
                LabeledContent(L10n.string("settings.trigger.hotkey")) {
                    HotkeyRecorderControl(currentBinding: model.state.settings.toggleHotkey) { recorded in
                        model.applyUpdatedHotkey(recorded)
                    }
                }
                Text(L10n.string("settings.trigger.hotkey_caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup(L10n.string("settings.trigger.advanced"), isExpanded: $showTriggerAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 12) {
                            Text(L10n.string("settings.trigger.require_modifier"))
                                .font(.callout)
                            modifierToggle("⌃", flag: .control)
                            modifierToggle("⌥", flag: .option)
                            modifierToggle("⇧", flag: .shift)
                            modifierToggle("⌘", flag: .command)
                        }

                        Toggle(L10n.string("settings.trigger.ignore_fullscreen"), isOn: $model.state.settings.edgeTrigger.ignoreInFullScreenApps)
                            .onChange(of: model.state.settings.edgeTrigger.ignoreInFullScreenApps) { _, _ in model.persistState() }

                        Toggle(L10n.string("settings.trigger.ignore_drag"), isOn: $model.state.settings.edgeTrigger.ignoreWhileDragging)
                            .onChange(of: model.state.settings.edgeTrigger.ignoreWhileDragging) { _, _ in model.persistState() }

                        Toggle(L10n.string("settings.trigger.gestures"), isOn: $model.state.settings.enableTrackpadGestures)
                            .onChange(of: model.state.settings.enableTrackpadGestures) { _, _ in
                                model.refreshPanelGeometryAndAppearance()
                                model.persistState()
                            }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func modifierToggle(_ title: String, flag: HotkeyModifiers) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.state.settings.edgeTrigger.requiredModifiers.contains(flag) },
            set: { enabled in
                if enabled {
                    model.state.settings.edgeTrigger.requiredModifiers.insert(flag)
                } else {
                    model.state.settings.edgeTrigger.requiredModifiers.remove(flag)
                }
                model.persistState()
            }
        ))
        .toggleStyle(.checkbox)
    }

    // MARK: - 3. Appearance

    private var appearancePane: some View {
        Form {
            Section(L10n.string("settings.appearance.layout")) {
                VStack(spacing: 6) {
                    ScreenAnchorDiagramView(
                        selectedAnchor: Binding(
                            get: { model.state.settings.anchor },
                            set: { newAnchor in
                                model.state.settings.anchor = newAnchor
                                model.refreshPanelGeometryAndAppearance()
                                model.persistState()
                            }
                        ),
                        widthPercent: model.state.settings.widthPercent,
                        heightPercent: model.state.settings.heightPercent,
                        compact: true
                    )
                    .frame(maxWidth: .infinity)
                    Text(L10n.string("settings.appearance.preview_caption"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Picker(L10n.string("settings.appearance.side"), selection: Binding(
                    get: { model.state.settings.anchor.isLeftAligned },
                    set: { placeLeft in
                        model.state.settings.anchor = model.state.settings.anchor.withHorizontalSide(left: placeLeft)
                        model.refreshPanelGeometryAndAppearance()
                        model.persistState()
                    }
                )) {
                    Text(L10n.string("settings.appearance.side_left")).tag(true)
                    Text(L10n.string("settings.appearance.side_right")).tag(false)
                }
                .pickerStyle(.segmented)

                LabeledContent("\(L10n.string("settings.appearance.width")) (\(Int(model.state.settings.widthPercent.rounded()))%)") {
                    Slider(value: $model.state.settings.widthPercent, in: PanelGeometry.minPercent...PanelGeometry.maxPercent, step: 1) { _ in
                        model.state.settings.panelSizeUserCustomized = true
                        model.refreshPanelGeometryAndAppearance()
                        model.persistState()
                    }
                }

                LabeledContent("\(L10n.string("settings.appearance.height")) (\(Int(model.state.settings.heightPercent.rounded()))%)") {
                    Slider(value: $model.state.settings.heightPercent, in: PanelGeometry.minPercent...PanelGeometry.maxPercent, step: 1) { _ in
                        model.state.settings.panelSizeUserCustomized = true
                        model.refreshPanelGeometryAndAppearance()
                        model.persistState()
                    }
                }
            }

            Section(L10n.string("settings.appearance.style")) {
                Picker(L10n.string("settings.appearance.theme"), selection: $model.state.settings.appearance.theme) {
                    ForEach(AppThemePreference.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .onChange(of: model.state.settings.appearance.theme) { _, _ in
                    model.refreshPanelGeometryAndAppearance()
                    model.persistState()
                }

                LabeledContent("\(L10n.string("settings.appearance.corners")) (\(Int(model.state.settings.appearance.cornerRadius)) pt)") {
                    Slider(value: $model.state.settings.appearance.cornerRadius, in: 6...24, step: 1) { _ in
                        model.refreshPanelGeometryAndAppearance()
                        model.persistState()
                    }
                }

                Toggle(L10n.string("settings.appearance.shadow"), isOn: $model.state.settings.appearance.hasShadow)
                    .onChange(of: model.state.settings.appearance.hasShadow) { _, _ in
                        model.refreshPanelGeometryAndAppearance()
                        model.persistState()
                    }

                Toggle(L10n.string("settings.appearance.compact_strip"), isOn: $model.state.settings.appearance.compactSidebar)
                    .onChange(of: model.state.settings.appearance.compactSidebar) { _, _ in
                        model.refreshPanelGeometryAndAppearance()
                        model.persistState()
                    }

                sidebarSizingControls

                Toggle(L10n.string("settings.appearance.disable_animations"), isOn: $model.state.settings.disableAnimations)
                    .onChange(of: model.state.settings.disableAnimations) { _, newValue in
                        model.setDisableAnimations(newValue)
                    }

                Toggle(L10n.string("settings.appearance.pin_open"), isOn: $model.state.settings.isPinnedOpen)
                    .onChange(of: model.state.settings.isPinnedOpen) { _, newValue in
                        model.setPinnedOpen(newValue)
                    }

                Toggle(L10n.string("settings.appearance.always_on_top"), isOn: $model.state.settings.isAlwaysOnTop)
                    .onChange(of: model.state.settings.isAlwaysOnTop) { _, newValue in
                        model.setAlwaysOnTop(newValue)
                    }
            }

            Section {
                DisclosureGroup(L10n.string("settings.appearance.advanced"), isExpanded: $showAppearanceAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        displayTargetPicker
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var sidebarSizingControls: some View {
        let appearance = model.state.settings.appearance
        let metrics = PanelChromeMetrics.forAppearance(appearance)
        let currentWidth = Double(metrics.sidebarStripWidth)
        let currentIcon = Double(metrics.padVisualIconSize)
        let maxIcon = Double(PanelChromeMetrics.maxIconSize(forSidebarWidth: metrics.sidebarStripWidth))
        let defaultW = Int(PanelChromeMetrics.defaultSidebarWidth(compactSidebar: appearance.compactSidebar))
        let defaultI = Int(PanelChromeMetrics.defaultIconSize(compactSidebar: appearance.compactSidebar))

        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("\(L10n.string("settings.appearance.sidebar_width")) (\(Int(currentWidth.rounded())) pt)") {
                Slider(
                    value: Binding(
                        get: { currentWidth },
                        set: { newValue in
                            model.setSidebarWidth(newValue, persist: false)
                        }
                    ),
                    in: Double(PanelChromeMetrics.minSidebarWidth)...Double(PanelChromeMetrics.maxSidebarWidth),
                    step: 1
                ) { editing in
                    if !editing {
                        model.persistState()
                        model.writeLiveUIState()
                    }
                }
            }

            LabeledContent("\(L10n.string("settings.appearance.sidebar_icon_size")) (\(Int(currentIcon.rounded())) pt)") {
                Slider(
                    value: Binding(
                        get: { min(currentIcon, maxIcon) },
                        set: { newValue in
                            model.setSidebarIconSize(newValue, persist: false)
                        }
                    ),
                    in: Double(PanelChromeMetrics.minPadIconSize)...maxIcon,
                    step: 1
                ) { editing in
                    if !editing {
                        model.persistState()
                        model.writeLiveUIState()
                    }
                }
            }

            HStack(spacing: 12) {
                sidebarMiniPreview(metrics: metrics)
                    .accessibilityLabel(L10n.string("settings.appearance.sidebar_preview_label"))

                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.string("settings.appearance.sidebar_mode_caption"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button(L10n.format("settings.appearance.sidebar_reset_default", defaultW, defaultI)) {
                        model.resetSidebarSizingToDefault()
                    }
                    .controlSize(.small)
                    .disabled(!appearance.isActiveSidebarSizingCustomized)
                }
            }
            .padding(.top, 2)
        }
    }

    private func sidebarMiniPreview(metrics m: PanelChromeMetrics) -> some View {
        HStack(spacing: 0) {
            VStack(spacing: m.padRowSpacing) {
                ForEach(0..<3, id: \.self) { idx in
                    let isSelected = (idx == 0)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(isSelected ? Color.accentColor : Color.clear)
                            .frame(width: m.selectionIndicatorWidth, height: isSelected ? m.selectionIndicatorSelectedHeight : 0)
                            .padding(.leading, m.selectionIndicatorLeadingInset)

                        ZStack {
                            RoundedRectangle(cornerRadius: m.padHighlightCornerRadius, style: .continuous)
                                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
                                .frame(width: m.padHighlightSize, height: m.padHighlightSize)

                            RoundedRectangle(cornerRadius: m.padIconCornerRadius, style: .continuous)
                                .fill(idx == 0 ? Color.accentColor : (idx == 1 ? Color.orange.opacity(0.85) : Color.teal.opacity(0.85)))
                                .frame(width: m.padVisualIconSize, height: m.padVisualIconSize)
                        }
                        .frame(width: m.padHitTargetWidth, height: m.padHitTargetHeight)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .frame(width: m.sidebarStripWidth, height: m.padHitTargetHeight)
                }
            }
            .padding(.vertical, 6)
            .frame(width: m.sidebarStripWidth)
            .background(Color(nsColor: .controlBackgroundColor))

            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(width: PanelChromeMetrics.sidebarDividerWidth)

            Color(nsColor: .textBackgroundColor)
                .frame(width: 28)
        }
        .frame(height: max(96, m.padRowPitch * 3 + 12))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
        )
    }

    private var displayTargetPicker: some View {
        let displays = EdgeMonitorController.currentDisplays()
        return Picker(L10n.string("settings.appearance.display"), selection: Binding(
            get: {
                switch model.state.settings.displayTarget {
                case .followMouse: return UInt32(0)
                case .pinnedDisplay(let id, _): return id
                }
            },
            set: { newID in
                if newID == 0 {
                    model.state.settings.displayTarget = .followMouse
                } else {
                    let name = displays.first(where: { $0.id == newID })?.name
                    model.state.settings.displayTarget = .pinnedDisplay(displayID: newID, name: name)
                }
                model.refreshPanelGeometryAndAppearance()
                model.persistState()
            }
        )) {
            Text(L10n.string("settings.appearance.follow_mouse")).tag(UInt32(0))
            ForEach(displays) { disp in
                Text(disp.name).tag(disp.id)
            }
        }
    }

    // MARK: - 4. Pads & Profiles

    private var padsAndProfilesPane: some View {
        Form {
            Section {
                ForEach(model.state.profiles) { profile in
                    HStack {
                        Image(systemName: profile.symbolName)
                        Text(profile.name)
                        if model.state.activeProfileID == profile.id {
                            Text(L10n.string("common.default"))
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
                        }
                        Spacer()
                        if model.state.activeProfileID != profile.id {
                            Button(L10n.string("common.apply")) {
                                model.switchActiveProfile(profile.id)
                            }
                            .controlSize(.small)
                        }
                        if model.state.profiles.count > 1 {
                            Button(role: .destructive) {
                                removeProfile(profile)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                HStack {
                    TextField(L10n.string("settings.profiles.new_placeholder"), text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.string("settings.profiles.add_button")) {
                        let trimmed = newProfileName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        model.state.profiles.append(BrowserProfile(name: trimmed, symbolName: "person.crop.square"))
                        newProfileName = ""
                        model.persistState()
                    }
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Text(L10n.string("settings.profiles.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.string("settings.profiles.section"))
            }

            Section(L10n.string("settings.profiles.memory")) {
                Picker(
                    L10n.string("settings.profiles.retention_label"),
                    selection: Binding(
                        get: { model.state.settings.autoHibernateMinutes },
                        set: { model.setPageRetention(autoHibernateMinutes: $0) }
                    )
                ) {
                    Text(L10n.string("settings.profiles.retention_30m")).tag(30)
                    Text(L10n.string("settings.profiles.retention_1h")).tag(60)
                    Text(L10n.string("settings.profiles.retention_2h")).tag(120)
                    Text(L10n.string("settings.profiles.retention_4h")).tag(240)
                    Text(L10n.string("settings.profiles.retention_12h")).tag(720)
                    Text(L10n.string("settings.profiles.retention_24h")).tag(1440)
                    Text(L10n.string("settings.profiles.retention_always")).tag(0)
                    if !AppSettings.autoHibernatePresetMinutes.contains(model.state.settings.autoHibernateMinutes) {
                        Text(L10n.format("settings.profiles.retention_custom_min", model.state.settings.autoHibernateMinutes))
                            .tag(model.state.settings.autoHibernateMinutes)
                    }
                }

                Picker(
                    L10n.string("settings.profiles.max_live_label"),
                    selection: Binding(
                        get: { model.state.settings.maxLivePads },
                        set: { model.setPageRetention(maxLivePads: $0) }
                    )
                ) {
                    Text(L10n.string("settings.profiles.max_live_unlimited")).tag(0)
                    ForEach(AppSettings.maxLivePadPresets.filter { $0 > 0 }, id: \.self) { count in
                        Text(L10n.format("settings.profiles.max_live_count", count)).tag(count)
                    }
                    if !AppSettings.maxLivePadPresets.contains(model.state.settings.maxLivePads) {
                        Text(L10n.format("settings.profiles.max_live_count", model.state.settings.maxLivePads))
                            .tag(model.state.settings.maxLivePads)
                    }
                }

                Text(L10n.string("settings.profiles.retention_caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(model.state.siteSizeRules) { rule in
                    HStack {
                        Text(rule.hostPattern)
                            .font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text("\(Int(rule.sizeOverride.widthPercent ?? model.state.settings.widthPercent))% × \(Int(rule.sizeOverride.heightPercent ?? model.state.settings.heightPercent))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            model.state.siteSizeRules.removeAll { $0.id == rule.id }
                            model.refreshPanelGeometryAndAppearance()
                            model.persistState()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField(L10n.string("settings.profiles.host_placeholder"), text: $newRuleHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("W%", text: $newRuleWidthPct)
                        .frame(width: 48)
                        .textFieldStyle(.roundedBorder)
                    TextField("H%", text: $newRuleHeightPct)
                        .frame(width: 48)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.string("common.add")) {
                        let host = newRuleHost.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !host.isEmpty else { return }
                        let w = Double(newRuleWidthPct) ?? 66
                        let h = Double(newRuleHeightPct) ?? 76
                        model.state.siteSizeRules.append(
                            SiteSizeRule(hostPattern: host, sizeOverride: PanelSizeOverride(widthPercent: w, heightPercent: h))
                        )
                        newRuleHost = ""
                        model.refreshPanelGeometryAndAppearance()
                        model.persistState()
                    }
                }
            }

            Section {
                DisclosureGroup(L10n.string("settings.profiles.backup_sync"), isExpanded: $showBackupAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button(L10n.string("settings.profiles.export")) { exportSettingsJSON() }
                            Button(L10n.string("settings.profiles.import")) { importSettingsJSON(merge: false) }
                            Button(L10n.string("settings.profiles.merge")) { importSettingsJSON(merge: true) }
                        }
                        HStack {
                            TextField(
                                L10n.string("settings.profiles.sync_folder"),
                                text: Binding(
                                    get: { model.state.settings.syncFolderPath ?? "" },
                                    set: {
                                        model.state.settings.syncFolderPath = $0.isEmpty ? nil : $0
                                        model.persistState()
                                    }
                                )
                            )
                            Button(L10n.string("settings.profiles.use_icloud")) {
                                model.state.settings.syncFolderPath = VeypaneStore.defaultiCloudSyncFolderURL.path
                                model.persistState()
                            }
                        }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func removeProfile(_ profile: BrowserProfile) {
        model.state.profiles.removeAll { $0.id == profile.id }
        if model.state.activeProfileID == profile.id {
            model.state.activeProfileID = model.state.profiles.first?.id
        }
        WKWebsiteDataStore.remove(forIdentifier: profile.dataStoreIdentifier) { _ in }
        model.persistState()
    }

    private func exportSettingsJSON() {
        let save = NSSavePanel()
        save.allowedContentTypes = [.json]
        save.nameFieldStringValue = "veypane-settings.json"
        if save.runModal() == .OK, let url = save.url {
            if let data = try? model.store.exportData(from: model.state) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private func importSettingsJSON(merge: Bool) {
        let open = NSOpenPanel()
        open.allowedContentTypes = [.json]
        open.allowsMultipleSelection = false
        if open.runModal() == .OK, let url = open.url,
           let data = try? Data(contentsOf: url),
           let updated = try? model.store.importData(data, into: model.state, merge: merge) {
            model.state = updated
            model.refreshPanelGeometryAndAppearance()
            model.persistState()
        }
    }

    // MARK: - 5. Privacy & Blocking

    private var privacyAndBlockingPane: some View {
        Form {
            Section(L10n.string("settings.privacy.blocker")) {
                Toggle(L10n.string("settings.privacy.enable_blocker"), isOn: $model.state.settings.contentBlocker.isEnabled)
                    .onChange(of: model.state.settings.contentBlocker.isEnabled) { _, _ in
                        model.persistState()
                        Task { await model.recompileContentBlockerAndApply() }
                    }

                Toggle(L10n.string("settings.privacy.builtin_rules"), isOn: $model.state.settings.contentBlocker.useBuiltInAdBlockRules)
                    .onChange(of: model.state.settings.contentBlocker.useBuiltInAdBlockRules) { _, _ in
                        model.persistState()
                        Task { await model.recompileContentBlockerAndApply() }
                    }

                HStack {
                    TextField(L10n.string("settings.privacy.block_domain_placeholder"), text: $newBlockedDomain)
                        .textFieldStyle(.roundedBorder)
                    Button(L10n.string("settings.privacy.block_button")) {
                        let dom = newBlockedDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        guard !dom.isEmpty else { return }
                        if !model.state.settings.contentBlocker.blockedDomains.contains(dom) {
                            model.state.settings.contentBlocker.blockedDomains.append(dom)
                            model.persistState()
                            Task { await model.recompileContentBlockerAndApply() }
                        }
                        newBlockedDomain = ""
                    }
                }

                if !model.state.settings.contentBlocker.blockedDomains.isEmpty {
                    ScrollView(.horizontal) {
                        HStack {
                            ForEach(model.state.settings.contentBlocker.blockedDomains, id: \.self) { dom in
                                HStack(spacing: 4) {
                                    Text(dom).font(.caption)
                                    Button {
                                        model.state.settings.contentBlocker.blockedDomains.removeAll { $0 == dom }
                                        model.persistState()
                                        Task { await model.recompileContentBlockerAndApply() }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                        }
                    }
                }
            }

            Section {
                ForEach(model.state.injectionRules) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rule.name).font(.subheadline.weight(.medium))
                            Text(rule.urlPattern).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            model.state.injectionRules.removeAll { $0.id == rule.id }
                            model.persistState()
                            Task { await model.recompileContentBlockerAndApply() }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                TextField(L10n.string("settings.privacy.rule_name"), text: $newInjName)
                TextField(L10n.string("settings.privacy.rule_pattern"), text: $newInjPattern)
                Picker("", selection: $newInjTime) {
                    Text(L10n.string("settings.privacy.inject_start")).tag(ScriptInjectionTime.atDocumentStart)
                    Text(L10n.string("settings.privacy.inject_end")).tag(ScriptInjectionTime.atDocumentEnd)
                }
                TextField(L10n.string("settings.privacy.custom_css"), text: $newInjCSS, axis: .vertical)
                    .lineLimit(2...3)
                TextField(L10n.string("settings.privacy.custom_js"), text: $newInjJS, axis: .vertical)
                    .lineLimit(2...3)

                Button(L10n.string("settings.privacy.add_rule")) {
                    let name = newInjName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { return }
                    model.state.injectionRules.append(
                        InjectionRule(
                            name: name,
                            urlPattern: newInjPattern,
                            css: newInjCSS,
                            javascript: newInjJS,
                            injectionTime: newInjTime
                        )
                    )
                    newInjName = ""
                    newInjCSS = ""
                    newInjJS = ""
                    model.persistState()
                    Task { await model.recompileContentBlockerAndApply() }
                }
                Text(L10n.string("settings.privacy.scripts_caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.string("settings.privacy.scripts"))
            }

            Section {
                DisclosureGroup(L10n.string("settings.privacy.advanced_json"), isExpanded: $showPrivacyAdvanced) {
                    TextField(
                        "[{\"trigger\":…,\"action\":…}]",
                        text: $model.state.settings.contentBlocker.customRuleListJSON,
                        axis: .vertical
                    )
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3...6)
                    .onSubmit {
                        model.persistState()
                        Task { await model.recompileContentBlockerAndApply() }
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 6. Automation

    private var automationPane: some View {
        Form {
            Section {
                Toggle(L10n.string("settings.automation.enable"), isOn: $model.state.settings.automation.isEnabled)
                    .onChange(of: model.state.settings.automation.isEnabled) { _, _ in
                        model.persistState()
                        Task { await model.syncAutomationServer() }
                    }

                LabeledContent(L10n.string("settings.automation.address")) {
                    Text("http://127.0.0.1:\(model.state.settings.automation.port)")
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }

                Stepper(
                    "\(L10n.string("settings.automation.port")): \(model.state.settings.automation.port)",
                    value: Binding(
                        get: { Int(model.state.settings.automation.port) },
                        set: {
                            model.state.settings.automation.port = UInt16(clamping: $0)
                            model.persistState()
                            Task { await model.syncAutomationServer() }
                        }
                    ),
                    in: 1024...65535
                )

                LabeledContent(L10n.string("settings.automation.token")) {
                    HStack(spacing: 6) {
                        Text(model.state.settings.automation.authToken)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 180)
                        Button(L10n.string("settings.automation.copy_token")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.state.settings.automation.authToken, forType: .string)
                        }
                        Button(L10n.string("settings.automation.regenerate_token")) {
                            model.state.settings.automation.authToken = AutomationSettings.generateToken()
                            model.persistState()
                            Task { await model.syncAutomationServer() }
                        }
                    }
                }

                Toggle(L10n.string("settings.automation.allow_js"), isOn: $model.state.settings.automation.allowLimitedJS)
                    .onChange(of: model.state.settings.automation.allowLimitedJS) { _, _ in
                        model.persistState()
                        Task { await model.syncAutomationServer() }
                    }

                Text(L10n.string("settings.automation.caption"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text(L10n.string("settings.automation.server"))
            }

            Section {
                DisclosureGroup(L10n.string("settings.automation.cli_reference"), isExpanded: $showAutomationCLI) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("veypanectl show | hide | toggle | list | ui state | ui diagnostics")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Text("veypane://toggle · veypane://open?url=https://example.com (legacy sidelarkctl/slidecraftctl & sidelark:// / slidecraft:// also supported)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 6)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 7. About

    private var aboutPane: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    if let iconURL = L10n.iconFileURL, let appIcon = NSImage(contentsOf: iconURL) {
                        Image(nsImage: appIcon)
                            .resizable()
                            .interpolation(.high)
                            .antialiased(true)
                            .scaledToFit()
                            .frame(width: 78, height: 78)
                    } else {
                        Image(nsImage: NSApplication.shared.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 72, height: 72)
                    }

                    Text(L10n.string("app.name"))
                        .font(.title2.weight(.bold))

                    Text(L10n.string("settings.about.subtitle"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(L10n.string("settings.about.version"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)

                    Button(L10n.string("menu.welcome_guide")) {
                        model.openWelcomeWindow()
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
            }

            Section {
                Text(L10n.string("settings.about.cleanroom"))
                    .font(.callout)
                Text(L10n.string("settings.about.extensions_note"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 5. Extensions (E2)

    @ViewBuilder
    private var extensionsPane: some View {
        let _ = model.extensionManager.uiRevision
        if !model.extensionManager.isSupported {
            VStack(spacing: 12) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text(L10n.string("settings.extensions.requires_macos"))
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let items = model.extensionManager.settingsItems()

            Form {
                Section {
                    HStack(spacing: 10) {
                        Button {
                            chooseSafariExtensionAppToInstall()
                        } label: {
                            Label(L10n.string("settings.extensions.add_safari_app"), systemImage: "safari")
                        }

                        Button {
                            chooseExtensionFolderToInstall()
                        } label: {
                            Label(L10n.string("settings.extensions.add_folder"), systemImage: "folder.badge.plus")
                        }

                        Button {
                            chooseExtensionArchiveToInstall()
                        } label: {
                            Label(L10n.string("settings.extensions.add_file"), systemImage: "doc.zipper")
                        }

                        Spacer()

                        if items.contains(where: { $0.sourceKind == .safariAppExtension }) {
                            Button {
                                Task { @MainActor in
                                    _ = await model.extensionManager.checkAndReloadSafariExtensionUpdates()
                                }
                            } label: {
                                Label(L10n.string("settings.extensions.check_safari_updates"), systemImage: "arrow.triangle.2.circlepath")
                            }
                            .controlSize(.small)
                        }
                    }

                    if let installErr = extensionInstallError, !installErr.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text(installErr)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                extensionInstallError = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Text(L10n.string("settings.extensions.caption"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L10n.string("settings.extensions.section")) {
                    if items.isEmpty {
                        Text(L10n.string("settings.extensions.empty"))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(items) { item in
                            ExtensionSettingsRowView(
                                item: item,
                                model: model,
                                onRequestRemove: { pendingRemovalExtension = item }
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .alert(
                L10n.format("settings.extensions.remove_confirm_title", pendingRemovalExtension?.displayName ?? ""),
                isPresented: Binding(
                    get: { pendingRemovalExtension != nil },
                    set: { if !$0 { pendingRemovalExtension = nil } }
                )
            ) {
                Button(L10n.string("common.cancel"), role: .cancel) {
                    pendingRemovalExtension = nil
                }
                Button(L10n.string("common.remove"), role: .destructive) {
                    if let target = pendingRemovalExtension {
                        pendingRemovalExtension = nil
                        Task { @MainActor in
                            await model.extensionManager.removeExtension(id: target.id)
                        }
                    }
                }
            } message: {
                if pendingRemovalExtension?.sourceKind == .safariAppExtension {
                    Text(L10n.string("settings.extensions.remove_confirm_safari_message"))
                } else {
                    Text(L10n.string("settings.extensions.remove_confirm_message"))
                }
            }
        }
    }

    private func chooseSafariExtensionAppToInstall() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        var allowed: [UTType] = [.applicationBundle]
        if let appexType = UTType(filenameExtension: "appex") {
            allowed.append(appexType)
        }
        panel.allowedContentTypes = allowed
        panel.prompt = L10n.string("common.add")
        if panel.runModal() == .OK, let appURL = panel.url {
            installExtensionAndReportError(from: appURL)
        }
    }

    private func chooseExtensionFolderToInstall() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.string("common.add")
        if panel.runModal() == .OK, let folderURL = panel.url {
            installExtensionAndReportError(from: folderURL)
        }
    }

    private func chooseExtensionArchiveToInstall() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        var allowed: [UTType] = [.zip]
        if let crxType = UTType(filenameExtension: "crx") {
            allowed.append(crxType)
        }
        panel.allowedContentTypes = allowed
        panel.allowsOtherFileTypes = true
        panel.prompt = L10n.string("common.add")
        if panel.runModal() == .OK, let fileURL = panel.url {
            installExtensionAndReportError(from: fileURL)
        }
    }

    private func installExtensionAndReportError(from url: URL) {
        extensionInstallError = nil
        Task { @MainActor in
            do {
                _ = try await model.extensionManager.installExtension(from: url)
            } catch {
                extensionInstallError = error.localizedDescription
            }
        }
    }
}

private struct ExtensionSettingsRowView: View {
    let item: ExtensionSettingsItem
    let model: AppModel
    let onRequestRemove: () -> Void

    @State private var showPermissions: Bool = false
    @State private var newSitePattern: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row: icon, name + version, Options..., Enabled switch
            HStack(spacing: 12) {
                Group {
                    if let icon = item.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    } else {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Color.accentColor.opacity(0.14))
                            .frame(width: 30, height: 30)
                            .overlay(
                                Image(systemName: "puzzlepiece.extension.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.accentColor)
                            )
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.displayName)
                            .font(.headline)
                        Text("v\(item.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                        if item.sourceKind == .safariAppExtension, let appName = item.sourceAppDisplayName {
                            Text(L10n.format("settings.extensions.safari_source_badge", appName))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.accentColor.opacity(0.12)))
                        }
                    }
                    Text(item.id)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer()

                if item.sourceKind == .safariAppExtension {
                    Button(L10n.string("settings.extensions.reload_safari")) {
                        Task { @MainActor in
                            _ = await model.extensionManager.checkAndReloadSafariExtensionUpdates(extensionID: item.id)
                        }
                    }
                    .controlSize(.small)
                }

                if item.hasOptionsPage {
                    Button(L10n.string("settings.extensions.options")) {
                        model.extensionManager.openOptionsPage(id: item.id)
                    }
                    .controlSize(.small)
                }

                Toggle(L10n.string("settings.extensions.enabled"), isOn: Binding(
                    get: { item.enabled },
                    set: { newEnabled in
                        Task { @MainActor in
                            await model.extensionManager.setExtensionEnabled(id: item.id, enabled: newEnabled)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(L10n.string("settings.extensions.enabled"))
            }

            // Controls row: Pin to toolbar, Website access popup, Remove button
            HStack(spacing: 14) {
                Toggle(L10n.string("settings.extensions.pin_toolbar"), isOn: Binding(
                    get: { item.pinnedToToolbar },
                    set: { model.extensionManager.setExtensionPinned(id: item.id, pinned: $0) }
                ))
                .controlSize(.small)

                Spacer()

                Picker(L10n.string("settings.extensions.website_access"), selection: Binding(
                    get: { item.websiteAccessMode },
                    set: { model.extensionManager.setWebsiteAccessMode(id: item.id, mode: $0) }
                )) {
                    Text(L10n.string("settings.extensions.access.all")).tag(ExtensionWebsiteAccessMode.allWebsites)
                    Text(L10n.string("settings.extensions.access.ask")).tag(ExtensionWebsiteAccessMode.ask)
                    Text(L10n.string("settings.extensions.access.specific")).tag(ExtensionWebsiteAccessMode.specificSites)
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(maxWidth: 230)

                Button(role: .destructive) {
                    onRequestRemove()
                } label: {
                    Text(L10n.string("common.remove"))
                }
                .controlSize(.small)
            }

            // Per-site match pattern list when Website access == .specificSites
            if item.websiteAccessMode == .specificSites {
                VStack(alignment: .leading, spacing: 6) {
                    let specificPatterns = item.grantedMatchPatterns.filter { $0 != "<all_urls>" && $0 != "*://*/*" }
                    ForEach(specificPatterns, id: \.self) { pat in
                        HStack {
                            Text(pat)
                                .font(.caption.monospaced())
                            Spacer()
                            Button {
                                model.extensionManager.removeSpecificSitePattern(id: item.id, pattern: pat)
                            } label: {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    HStack(spacing: 6) {
                        TextField(L10n.string("settings.extensions.site_placeholder"), text: $newSitePattern)
                            .textFieldStyle(.roundedBorder)
                            .controlSize(.small)
                            .onSubmit {
                                guard !newSitePattern.isEmpty else { return }
                                model.extensionManager.addSpecificSitePattern(id: item.id, pattern: newSitePattern)
                                newSitePattern = ""
                            }
                        Button(L10n.string("common.add")) {
                            guard !newSitePattern.isEmpty else { return }
                            model.extensionManager.addSpecificSitePattern(id: item.id, pattern: newSitePattern)
                            newSitePattern = ""
                        }
                        .controlSize(.small)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
            }

            // Permissions disclosure
            DisclosureGroup(L10n.string("settings.extensions.permissions"), isExpanded: $showPermissions) {
                if item.allPermissions.isEmpty {
                    Text(L10n.string("settings.extensions.no_permissions"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(item.allPermissions, id: \.self) { perm in
                            Toggle(perm, isOn: Binding(
                                get: { item.grantedPermissions.contains(perm) },
                                set: { model.extensionManager.setPermissionGranted(id: item.id, permission: perm, granted: $0) }
                            ))
                            .font(.caption.monospaced())
                            .controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }
            }
            .font(.caption)

            // Inline manifest / context errors
            if !item.errors.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label(L10n.string("settings.extensions.errors_label"), systemImage: "info.circle")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                    ForEach(item.errors.prefix(4), id: \.self) { err in
                        Text("• \(err)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.08)))
            }
        }
        .padding(.vertical, 4)
    }
}

extension Notification.Name {
    static let veypaneMenuBarVisibilityChanged = Notification.Name("VeypaneMenuBarVisibilityChanged")
}
