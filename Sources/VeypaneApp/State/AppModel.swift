import AppKit
import SwiftUI
import Observation
import WebKit
import ServiceManagement
import Carbon
import VeypaneCore

@MainActor
private final class DistributedIPCReceiver: NSObject {
    var onAction: (@MainActor (VeypaneAutomationAction) -> Void)?

    @objc func handleDistributedNotification(_ notification: Notification) {
        guard let action = VeypaneIPC.extractAction(from: notification) else { return }
        onAction?(action)
    }
}

@MainActor
private final class AppleEventURLReceiver: NSObject {
    var onURL: (@MainActor (URL) -> Void)?

    @objc func handleGetURLEvent(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlString) else { return }
        onURL?(url)
    }
}

@MainActor
private final class ManagedWindowDelegate: NSObject, NSWindowDelegate {
    var onVisibilityChanged: (@MainActor () -> Void)?

    func windowDidBecomeKey(_ notification: Notification) {
        onVisibilityChanged?()
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor [weak self] in
            self?.onVisibilityChanged?()
        }
    }
}

@MainActor
@Observable
public final class AppModel {
    public static let shared = AppModel()

    public let store: VeypaneStore
    public let extensionManager: ExtensionManager
    public let faviconCache: FaviconCacheManager
    public var state: WorkspaceState
    public var areExtensionsReady: Bool = true
    public var isPanelVisible: Bool = false
    public var addressBarState = AddressBarStateMachine()
    public var omniboxFocusToken: Int = 0
    public var isFindBarVisible: Bool = false
    public var findQuery: String = ""
    public var findMatchFound: Bool? = nil
    public var statusMessage: String? = nil
    public var webStateRevision: Int = 0
    public var activePiPPadIDs: Set<UUID> = []
    public var isDiagnosticsSheetPresented: Bool = false
    public var isSidebarPadDragActive: Bool = false
    public var sidebarPadDragCancelToken: Int = 0
    @ObservationIgnored public var sidebarPadFramesInWindow: [UUID: CGRect] = [:]
    public var transitionController = PanelTransitionController()
    public var diagnostics = RuntimeDiagnosticsCounters()
    public private(set) var presentedDisplay: DisplayDescriptor?
    public private(set) var presentedAnchor: AnchorPosition?
    public var simulatedDisplaysOverride: [DisplayDescriptor]?
    public let useNonPersistentWebsiteDataStore: Bool

    public var isEditingAddress: Bool {
        get { addressBarState.isEditingCurrentPad }
        set {
            if newValue {
                if let pad = selectedPad {
                    let liveURL = webControllers[pad.id]?.webView.url ?? pad.url
                    addressBarState.revealForCurrentPad(padID: pad.id, currentURL: liveURL)
                }
            } else if addressBarState.isEditingCurrentPad {
                addressBarState.cancel()
                scheduleWebFocusRestoreIfAppropriate()
            }
        }
    }

    public var isAddPadPopoverPresented: Bool {
        get { addressBarState.isCreatingNewPad }
        set {
            if newValue {
                if !addressBarState.isCreatingNewPad {
                    addressBarState.openForNewPad()
                }
            } else if addressBarState.isCreatingNewPad {
                addressBarState.cancel()
                scheduleWebFocusRestoreIfAppropriate()
            }
        }
    }

    public var omniboxText: String {
        get { addressBarState.draftText }
        set { addressBarState.updateDraft(newValue) }
    }

    public var hasStatusItem: Bool = false
    public var isStatusItemVisible: Bool = false

    @ObservationIgnored private var isRuntimeActive: Bool = false
    @ObservationIgnored private var webControllers: [UUID: PadWebController] = [:]
    @ObservationIgnored private var pipControllers: [UUID: PiPWindowController] = [:]
    @ObservationIgnored public private(set) var ephemeralPopups: [UUID: EphemeralPopupWindowController] = [:]
    @ObservationIgnored private var ephemeralPopupOrder: [UUID] = []
    @ObservationIgnored private var scriptSpawnedPadIDs: Set<UUID> = []
    public var forceOffscreenPopupWindows: Bool = false
    @ObservationIgnored private var compiledRuleList: WKContentRuleList?
    @ObservationIgnored public private(set) var panel: SlideOverPanel?
    @ObservationIgnored private var offscreenWebWindow: NSWindow?
    @ObservationIgnored private var settingsWindow: NSWindow?
    @ObservationIgnored private var welcomeWindow: NSWindow?
    @ObservationIgnored private let settingsWindowDelegate = ManagedWindowDelegate()
    @ObservationIgnored private let welcomeWindowDelegate = ManagedWindowDelegate()
    @ObservationIgnored private var hotkeyManager: GlobalHotkeyManager?
    @ObservationIgnored private var edgeMonitor: EdgeMonitorController?
    @ObservationIgnored private var localKeyMonitor: Any?
    @ObservationIgnored private var outsideClickMonitor: OutsideClickEventMonitor?
    @ObservationIgnored private var hibernateTimer: Timer?
    @ObservationIgnored private var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private let ipcReceiver = DistributedIPCReceiver()
    @ObservationIgnored private let urlEventReceiver = AppleEventURLReceiver()
    @ObservationIgnored private var automationServer: LocalAutomationServer?

    public var simulatedModalOrFileDialogActiveForTesting: Bool = false
    public var simulatedMenuOpenForTesting: Bool = false
    @ObservationIgnored public private(set) var outsideClickEventsObserved: Int = 0
    @ObservationIgnored public private(set) var outsideClickDismissalsTriggered: Int = 0
    @ObservationIgnored public private(set) var lastOutsideClickDecision: OutsideClickDecision?
    @ObservationIgnored public private(set) var lastOutsideClickDismissalDecision: OutsideClickDecision?
    public var outsideClickMonitorBackend: String { outsideClickMonitor?.backendDescription ?? "stopped" }
    public var activeSettingsWindow: NSWindow? { settingsWindow }
    public var activeWelcomeWindow: NSWindow? { welcomeWindow }

    public init(
        store: VeypaneStore = VeypaneStore(),
        extensionManager: ExtensionManager = .shared,
        allowExtensionPrompts: Bool = true,
        useNonPersistentWebsiteDataStore: Bool = false
    ) {
        self.store = store
        self.extensionManager = extensionManager
        self.useNonPersistentWebsiteDataStore = useNonPersistentWebsiteDataStore
        self.faviconCache = FaviconCacheManager(diskDirectoryURL: store.faviconsDirectoryURL)
        let loaded = store.load()
        var initialState = loaded.state

        if let syncPath = initialState.settings.syncFolderPath, !syncPath.isEmpty {
            let syncDir = URL(fileURLWithPath: (syncPath as NSString).expandingTildeInPath, isDirectory: true)
            if let newer = try? store.loadNewerSyncSnapshotIfAvailable(fromDirectory: syncDir, currentState: initialState) {
                initialState = newer
            }
        }

        self.state = initialState
        if loaded.didRecoverFromCorruption {
            self.statusMessage = "Recovered workspace from backup."
        }
        self.extensionManager.bind(to: self, allowInteractivePrompts: allowExtensionPrompts)
    }

    public var selectedPad: Pad? {
        guard let id = state.selectedPadID else { return state.pads.first }
        return state.pads.first(where: { $0.id == id }) ?? state.pads.first
    }

    // MARK: - Runtime Services Setup

    public func startRuntimeServices(makePanelContentView: () -> NSView) {
        isRuntimeActive = true
        ensureOffscreenWebHostWindow()

        let initialFrame = computeTargetFrames().visible
        let slidePanel = SlideOverPanel(contentRect: initialFrame)
        slidePanel.contentView = makePanelContentView()
        slidePanel.activeAnchor = state.settings.anchor
        slidePanel.gesturesEnabled = state.settings.enableTrackpadGestures
        slidePanel.animationsDisabled = state.settings.disableAnimations
        slidePanel.applyAppearance(state.settings.appearance, isAlwaysOnTop: state.settings.isAlwaysOnTop)
        slidePanel.onEscapeDuringDrag = { [weak self] in
            guard let self, self.isSidebarPadDragActive else { return false }
            self.sidebarPadDragCancelToken &+= 1
            self.isSidebarPadDragActive = false
            return true
        }
        slidePanel.onEscapePressed = { [weak self] in
            guard let self else { return }
            if self.isSidebarPadDragActive {
                self.sidebarPadDragCancelToken &+= 1
                self.isSidebarPadDragActive = false
            } else if self.addressBarState.isVisible {
                self.cancelAddressBar()
            } else if self.isFindBarVisible {
                self.isFindBarVisible = false
                self.scheduleWebFocusRestoreIfAppropriate()
            } else {
                self.hidePanel()
            }
        }
        slidePanel.onGestureAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .none: break
            case .nextPad: self.cyclePad(forward: true)
            case .previousPad: self.cyclePad(forward: false)
            case .hidePanel: self.hidePanel()
            }
        }
        slidePanel.screenVisibleFrameForResizeProvider = { [weak self] in
            guard let self else { return NSRect(x: 0, y: 0, width: 1920, height: 1080) }
            let displays = self.availableDisplays()
            let resolved = DisplaySelector.resolveLockedDisplay(
                locked: self.presentedDisplay,
                panelFrame: self.panel?.frame ?? .zero,
                in: displays
            ) ?? DisplaySelector.selectDisplay(
                from: displays,
                mode: self.state.settings.displayTarget,
                mouseLocation: NSEvent.mouseLocation
            )
            return resolved?.visibleFrame ?? NSRect(x: 0, y: 25, width: 1440, height: 875)
        }
        slidePanel.onInteractiveResizeEnded = { [weak self] finalFrame in
            self?.commitUserResizedPanelFrame(finalFrame)
        }
        self.panel = slidePanel

        settingsWindowDelegate.onVisibilityChanged = { [weak self] in
            self?.writeLiveUIState()
        }
        welcomeWindowDelegate.onVisibilityChanged = { [weak self] in
            self?.writeLiveUIState()
        }

        // Global Carbon Hotkey
        let hk = GlobalHotkeyManager()
        hk.onTrigger = { [weak self] in
            self?.togglePanel(activateFocus: true)
        }
        hk.register(binding: state.settings.toggleHotkey)
        self.hotkeyManager = hk

        // Hot Edge / Hot Corner Monitor
        let monitor = EdgeMonitorController()
        monitor.settingsProvider = { [weak self] in
            guard let self else { return AppSettings() }
            var effective = self.state.settings
            if self.extensionManager.isAnyPopupVisible
                || !self.ephemeralPopups.isEmpty
                || self.hasActiveModalOrSheetOrFileDialog()
                || self.hasActivePopupMenuWindow()
                || (self.panel?.isInInteractiveResize == true)
                || (self.panel?.childWindows?.contains(where: \.isVisible) == true) {
                effective.isPinnedOpen = true
            }
            return effective
        }
        monitor.currentPanelFrameProvider = { [weak self] in
            guard let self else { return .zero }
            if self.isPanelVisible,
               let panel = self.panel,
               panel.isVisible,
               panel.activeAnimationFlight == nil,
               panel.frame.width > 10,
               panel.frame.height > 10 {
                return panel.frame
            }
            return self.computeTargetFrames(
                preferredDisplay: self.presentedDisplay,
                anchorOverride: self.presentedAnchor
            ).visible
        }
        monitor.presentedDisplayProvider = { [weak self] in
            self?.presentedDisplay
        }
        monitor.presentedAnchorProvider = { [weak self] in
            self?.presentedAnchor
        }
        monitor.isPanelAnimatingInProvider = { [weak self] in
            self?.transitionController.phase == .showing
        }
        monitor.onShowRequested = { [weak self] targetDisplay in
            self?.showPanel(activateFocus: true, openedFromEdge: true, triggeredOnDisplay: targetDisplay)
        }
        monitor.onHideRequested = { [weak self] in
            self?.hidePanel()
        }
        monitor.start()
        self.edgeMonitor = monitor

        installLocalShortcutMonitor()
        installOutsideClickMonitors()
        installHibernateTimer()
        installMemoryPressureMonitor()
        installDistributedIPCObserver()
        installAppleEventURLHandler()

        // Load enabled extensions before pads create web views (E1)
        let hasEnabledExtensions = state.installedExtensions.contains(where: \.enabled)
        if !hasEnabledExtensions {
            areExtensionsReady = true
            if let pad = selectedPad, !pad.isHibernated {
                _ = webController(for: pad)
            }
            extensionManager.syncTabsWithWorkspace()
        } else {
            areExtensionsReady = false
        }

        if !state.settings.hasCompletedOnboarding {
            openWelcomeWindow()
        }

        writeLiveUIState()

        Task {
            if hasEnabledExtensions {
                await extensionManager.loadEnabledExtensionsAtStartup()
                self.areExtensionsReady = true
                if let pad = self.selectedPad, !pad.isHibernated {
                    _ = self.webController(for: pad)
                }
                self.extensionManager.syncTabsWithWorkspace()
            }
            await recompileContentBlockerAndApply()
            await syncAutomationServer()
        }
    }

    private func ensureOffscreenWebHostWindow() {
        guard offscreenWebWindow == nil else { return }
        let win = NSWindow(
            contentRect: NSRect(x: -15000, y: -15000, width: 1080, height: 740),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        win.isOpaque = false
        win.alphaValue = 0.0
        win.ignoresMouseEvents = true
        win.isReleasedWhenClosed = false
        win.collectionBehavior = [.transient, .ignoresCycle]
        let hostView = NSView(frame: NSRect(x: 0, y: 0, width: 1080, height: 740))
        win.contentView = hostView
        self.offscreenWebWindow = win
    }

    public func attachToOffscreenHostIfUnparented(_ webView: WKWebView) {
        ensureOffscreenWebHostWindow()
        guard webView.superview == nil, let hostView = offscreenWebWindow?.contentView else { return }
        webView.frame = hostView.bounds
        webView.autoresizingMask = [.width, .height]
        hostView.addSubview(webView)
    }

    // MARK: - Live UI State Writer & Diagnostics Counters

    private func syncDiagnosticsFromTransitionController() {
        diagnostics.panelShowCount = transitionController.showCount
        diagnostics.panelHideCount = transitionController.hideCount
        diagnostics.panelInterruptedTransitions = transitionController.interruptedTransitions
        diagnostics.transitionPhase = transitionController.phase
    }

    public func writeLiveUIState() {
        guard isRuntimeActive else { return }
        syncDiagnosticsFromTransitionController()
        let frameRect = panel?.frame ?? .zero
        let frameStr = NSStringFromRect(frameRect)
        let padTitle = selectedPad?.title ?? ""
        let padLoading = selectedPad.flatMap { webControllers[$0.id]?.isLoading } ?? false

        let snapshot = UIStateSnapshot(
            appName: AppBrandIdentity.productName,
            bundleIdentifier: AppBrandIdentity.bundleIdentifier,
            statusItem: hasStatusItem,
            statusItemVisible: isStatusItemVisible,
            panelVisible: isPanelVisible && (panel?.isVisible ?? false),
            panelFrame: frameStr,
            selectedPad: padTitle,
            selectedPadLoading: padLoading,
            settingsVisible: settingsWindow?.isVisible ?? false,
            welcomeVisible: welcomeWindow?.isVisible ?? false,
            diagnostics: diagnostics
        )
        try? store.writeUIState(snapshot)
    }

    // MARK: - Panel Visibility & Geometry (Generation-Guarded Transitions)

    public func togglePanel(activateFocus: Bool = true) {
        if transitionController.isTargetVisible && (panel?.isVisible ?? isPanelVisible) {
            hidePanel()
        } else {
            showPanel(activateFocus: activateFocus, openedFromEdge: false)
        }
    }

    public func showPanel(
        activateFocus: Bool = true,
        openedFromEdge: Bool = false,
        triggeredOnDisplay: DisplayDescriptor? = nil
    ) {
        let step = transitionController.beginShow()
        isPanelVisible = true
        syncDiagnosticsFromTransitionController()

        let effectiveAnchor = state.settings.anchor
        let preferredDisplay = triggeredOnDisplay ?? (step.reversedInFlight ? presentedDisplay : nil)
        let resolved = resolveTargetFramesAndDisplay(
            preferredDisplay: preferredDisplay,
            anchor: effectiveAnchor
        )
        presentedDisplay = resolved.display
        presentedAnchor = effectiveAnchor

        guard let panel else {
            _ = transitionController.completeShow(generation: step.generation)
            syncDiagnosticsFromTransitionController()
            writeLiveUIState()
            return
        }

        panel.activeAnchor = effectiveAnchor
        panel.gesturesEnabled = state.settings.enableTrackpadGestures
        panel.animationsDisabled = state.settings.disableAnimations
        panel.applyAppearance(state.settings.appearance, isAlwaysOnTop: state.settings.isAlwaysOnTop)

        if areExtensionsReady, let pad = selectedPad, !pad.isHibernated {
            PadWorkspaceEngine.touchActivePad(in: &state)
            _ = webController(for: pad)
        }

        edgeMonitor?.syncPanelVisibility(true, pointerAlreadyInside: openedFromEdge)

        if step.shouldPerformTransition || !panel.isVisible {
            panel.slideIn(
                from: resolved.hidden,
                to: resolved.visible,
                generation: step.generation,
                reversedInFlight: step.reversedInFlight,
                duration: state.settings.animationDuration,
                activateKeyFocus: activateFocus
            ) { [weak self] completedGen in
                guard let self else { return }
                if self.transitionController.completeShow(generation: completedGen) {
                    self.syncDiagnosticsFromTransitionController()
                    self.writeLiveUIState()
                }
            }
        } else {
            panel.orderFrontRegardless()
            if activateFocus {
                panel.makeKey()
            }
        }

        if activateFocus {
            scheduleWebFocusRestoreIfAppropriate()
        }
        extensionManager.notifyWindowFocused()
        writeLiveUIState()
    }

    /// Returns `true` when `responder` belongs to a native AppKit text control (`NSText` / `NSTextView` field editor / `NSTextField`),
    /// ensuring focus restoration and extension shortcuts never steal focus from active native text inputs.
    public static func isNativeTextResponder(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSText || responder is NSTextField {
            return true
        }
        if let view = responder as? NSView {
            if view.enclosingScrollView?.documentView is NSText {
                return true
            }
            var ancestor: NSView? = view.superview
            while let current = ancestor {
                if current is NSTextField || current is NSSearchField {
                    return true
                }
                ancestor = current.superview
            }
        }
        return false
    }

    /// Restores `firstResponder` to the selected pad's mounted `WKWebView` ONLY when no transient address bar,
    /// Find bar, sheet, or native `NSText` field currently owns focus.
    @discardableResult
    public func restoreWebViewFocusIfAppropriate(in targetWindow: NSWindow? = nil) -> Bool {
        let win = targetWindow ?? panel
        guard let win else { return false }
        if targetWindow == nil {
            guard isPanelVisible else { return false }
        }
        guard !addressBarState.isVisible,
              !isFindBarVisible,
              !isDiagnosticsSheetPresented,
              win.attachedSheet == nil else {
            return false
        }
        if Self.isNativeTextResponder(win.firstResponder) {
            return false
        }
        guard let pad = selectedPad,
              !pad.isHibernated,
              !activePiPPadIDs.contains(pad.id),
              let wc = webControllers[pad.id] else {
            return false
        }
        let targetWebView = wc.webView
        guard !targetWebView.isHidden, targetWebView.window === win else {
            return false
        }
        if let frView = win.firstResponder as? NSView,
           (frView === targetWebView || frView.isDescendant(of: targetWebView)) {
            return true
        }
        return win.makeFirstResponder(targetWebView)
    }

    public func scheduleWebFocusRestoreIfAppropriate() {
        _ = restoreWebViewFocusIfAppropriate()
        DispatchQueue.main.async { [weak self] in
            _ = self?.restoreWebViewFocusIfAppropriate()
        }
    }

    public func hidePanel() {
        if isSidebarPadDragActive {
            sidebarPadDragCancelToken &+= 1
            isSidebarPadDragActive = false
        }
        isAddPadPopoverPresented = false
        isFindBarVisible = false
        isDiagnosticsSheetPresented = false
        addressBarState.cancel()

        let step = transitionController.beginHide()
        isPanelVisible = false
        syncDiagnosticsFromTransitionController()

        guard let panel else {
            presentedDisplay = nil
            presentedAnchor = nil
            _ = transitionController.completeHide(generation: step.generation)
            syncDiagnosticsFromTransitionController()
            writeLiveUIState()
            return
        }

        edgeMonitor?.syncPanelVisibility(
            false,
            pointerAlreadyInside: false,
            requireTriggerExitBeforeReshow: true
        )
        guard step.shouldPerformTransition else {
            writeLiveUIState()
            return
        }

        // Always hide back toward the anchor & display on which the panel was shown,
        // even if the pointer moved onto another display before dismissal.
        PadWorkspaceEngine.touchActivePad(in: &state)
        let hideAnchor = presentedAnchor ?? state.settings.anchor
        let displays = availableDisplays()
        let lockedDisplay = DisplaySelector.resolveLockedDisplay(
            locked: presentedDisplay,
            panelFrame: panel.frame,
            in: displays
        )
        let frames = computeTargetFrames(
            preferredDisplay: lockedDisplay,
            anchorOverride: hideAnchor
        )
        let effectiveFromVisible: CGRect
        let effectiveToHidden: CGRect
        if !step.reversedInFlight && panel.activeAnimationFlight == nil && panel.frame.width > 10 && panel.frame.height > 10 {
            effectiveFromVisible = panel.frame
            let fullScreen = lockedDisplay?.frame ?? NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
            effectiveToHidden = PanelGeometry.hiddenFrame(
                visibleFrame: effectiveFromVisible,
                screenFrame: fullScreen,
                anchor: hideAnchor
            )
        } else {
            effectiveFromVisible = frames.visible
            effectiveToHidden = frames.hidden
        }
        panel.activeAnchor = hideAnchor
        panel.animationsDisabled = state.settings.disableAnimations
        panel.slideOut(
            from: effectiveFromVisible,
            to: effectiveToHidden,
            generation: step.generation,
            reversedInFlight: step.reversedInFlight,
            duration: state.settings.animationDuration,
            shouldFinalizeHide: { [weak self] completedGen in
                guard let self else { return false }
                let allowed = self.transitionController.completeHide(generation: completedGen)
                if allowed {
                    self.presentedDisplay = nil
                    self.presentedAnchor = nil
                }
                self.syncDiagnosticsFromTransitionController()
                return allowed
            },
            completion: { [weak self] in
                guard let self else { return }
                // Keep mounted webViews inside the panel deck view so scroll position & layout never reset;
                // only attach to offscreen host if a webView has no superview at all.
                if let pad = self.selectedPad, let wc = self.webControllers[pad.id], wc.webView.superview == nil {
                    self.attachToOffscreenHostIfUnparented(wc.webView)
                }
                self.writeLiveUIState()
            }
        )
        writeLiveUIState()
    }

    public func presentNewPadFlow() {
        showPanel(activateFocus: true, openedFromEdge: false)
        addressBarState.openForNewPad()
        omniboxFocusToken &+= 1
    }

    public func setPinnedOpen(_ pinned: Bool) {
        state.settings.isPinnedOpen = pinned
        persistState()
        writeLiveUIState()
    }

    public func togglePinnedOpen() {
        setPinnedOpen(!state.settings.isPinnedOpen)
    }

    public func setAlwaysOnTop(_ enabled: Bool) {
        state.settings.isAlwaysOnTop = enabled
        refreshPanelGeometryAndAppearance()
        persistState()
    }

    public func setDisableAnimations(_ disabled: Bool) {
        state.settings.disableAnimations = disabled
        panel?.animationsDisabled = disabled
        persistState()
        writeLiveUIState()
    }

    public func setSidebarWidth(_ width: Double, persist: Bool = true) {
        state.settings.appearance.setActiveSidebarWidth(width)
        refreshPanelGeometryAndAppearance()
        if persist {
            persistState()
            writeLiveUIState()
        }
    }

    public func setSidebarIconSize(_ size: Double, persist: Bool = true) {
        state.settings.appearance.setActiveSidebarIconSize(size)
        refreshPanelGeometryAndAppearance()
        if persist {
            persistState()
            writeLiveUIState()
        }
    }

    public func resetSidebarSizingToDefault() {
        state.settings.appearance.resetActiveSidebarSizingToDefault()
        refreshPanelGeometryAndAppearance()
        persistState()
        writeLiveUIState()
    }

    public func refreshPanelGeometryAndAppearance() {
        guard let panel else { return }
        panel.activeAnchor = state.settings.anchor
        panel.gesturesEnabled = state.settings.enableTrackpadGestures
        panel.animationsDisabled = state.settings.disableAnimations
        panel.applyAppearance(state.settings.appearance, isAlwaysOnTop: state.settings.isAlwaysOnTop)
        if isPanelVisible {
            presentedAnchor = state.settings.anchor
            let resolved = resolveTargetFramesAndDisplay(
                preferredDisplay: presentedDisplay,
                anchor: state.settings.anchor
            )
            presentedDisplay = resolved.display
            panel.resizeSmoothly(to: resolved.visible)
        }
        writeLiveUIState()
    }

    public func commitUserResizedPanelFrame(_ finalFrame: CGRect) {
        let displays = availableDisplays()
        let screenDesc = DisplaySelector.resolveLockedDisplay(
            locked: presentedDisplay,
            panelFrame: finalFrame,
            in: displays
        ) ?? DisplaySelector.selectDisplay(
            from: displays,
            mode: state.settings.displayTarget,
            mouseLocation: NSEvent.mouseLocation
        )
        let visibleScreen = screenDesc?.visibleFrame ?? CGRect(x: 0, y: 25, width: 1440, height: 875)
        let percents = PanelGeometry.sizePercents(forFrame: finalFrame, in: visibleScreen)

        if let pad = selectedPad,
           let idx = state.pads.firstIndex(where: { $0.id == pad.id }),
           let existingOverride = state.pads[idx].sizeOverride,
           !existingOverride.isEmpty {
            state.pads[idx].sizeOverride = PanelSizeOverride(
                widthPercent: percents.widthPercent,
                heightPercent: percents.heightPercent
            )
        } else {
            state.settings.widthPercent = percents.widthPercent
            state.settings.heightPercent = percents.heightPercent
            state.settings.panelSizeUserCustomized = true
        }

        if let padID = selectedPad?.id {
            extensionManager.notifyTabPropertiesChanged(padID: padID, size: true)
        }
        persistState()
        writeLiveUIState()
    }

    private func availableDisplays() -> [DisplayDescriptor] {
        simulatedDisplaysOverride ?? EdgeMonitorController.currentDisplays()
    }

    private func resolveTargetFramesAndDisplay(
        preferredDisplay: DisplayDescriptor?,
        anchor: AnchorPosition
    ) -> (visible: CGRect, hidden: CGRect, display: DisplayDescriptor?) {
        let displays = availableDisplays()
        let mouse = NSEvent.mouseLocation
        let screenDesc: DisplayDescriptor?
        if let preferredDisplay,
           let matched = DisplaySelector.resolveLockedDisplay(
               locked: preferredDisplay,
               panelFrame: panel?.frame ?? .zero,
               in: displays
           ) {
            screenDesc = matched
        } else {
            screenDesc = DisplaySelector.selectDisplay(
                from: displays,
                mode: state.settings.displayTarget,
                mouseLocation: mouse
            )
        }
        let visibleScreen = screenDesc?.visibleFrame ?? CGRect(x: 0, y: 25, width: 1440, height: 875)
        let fullScreen = screenDesc?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)

        let sizeOverride = selectedPad.flatMap {
            SiteSizeRuleMatcher.effectiveOverride(for: $0, rules: state.siteSizeRules)
        }

        let visible = PanelGeometry.visibleFrame(
            screenVisibleFrame: visibleScreen,
            anchor: anchor,
            defaultWidthPercent: state.settings.widthPercent,
            defaultHeightPercent: state.settings.heightPercent,
            override: sizeOverride,
            edgeInset: state.settings.edgeInset
        )
        let hidden = PanelGeometry.hiddenFrame(
            visibleFrame: visible,
            screenFrame: fullScreen,
            anchor: anchor
        )
        return (visible, hidden, screenDesc)
    }

    private func computeTargetFrames(
        preferredDisplay: DisplayDescriptor? = nil,
        anchorOverride: AnchorPosition? = nil
    ) -> (visible: CGRect, hidden: CGRect) {
        let res = resolveTargetFramesAndDisplay(
            preferredDisplay: preferredDisplay,
            anchor: anchorOverride ?? state.settings.anchor
        )
        return (res.visible, res.hidden)
    }

    // MARK: - WebController Pool Management

    public func webController(
        for pad: Pad,
        suppliedConfiguration: WKWebViewConfiguration? = nil
    ) -> PadWebController {
        if let existing = webControllers[pad.id] {
            if existing.webView.superview == nil {
                attachToOffscreenHostIfUnparented(existing.webView)
            }
            return existing
        }

        let effectiveProfileID = pad.profileID ?? state.activeProfileID
        let dataStoreUUID = state.profiles.first(where: { $0.id == effectiveProfileID })?.dataStoreIdentifier

        diagnostics.webViewCreations &+= 1
        let controller = PadWebController(
            pad: pad,
            profileDataStoreID: dataStoreUUID,
            useNonPersistentDataStore: useNonPersistentWebsiteDataStore,
            suppliedConfiguration: suppliedConfiguration,
            injectionRules: state.injectionRules,
            compiledContentRuleList: compiledRuleList,
            globalMuted: state.settings.isGlobalMuted,
            onInitialLoadIssued: { [weak self] in
                self?.diagnostics.loadRequests &+= 1
            }
        )
        controller.onLoadRequested = { [weak self] in
            self?.diagnostics.loadRequests &+= 1
        }
        controller.onReloadRequested = { [weak self] in
            self?.diagnostics.reloadRequests &+= 1
        }
        attachToOffscreenHostIfUnparented(controller.webView)

        let padID = pad.id
        controller.onPadStateChanged = { [weak self] in
            guard let self else { return }
            self.webStateRevision &+= 1
            if self.state.selectedPadID == padID {
                self.writeLiveUIState()
            }
        }
        controller.onTitleAndBadgeUpdated = { [weak self] rawTitle, _ in
            guard let self, let idx = self.state.pads.firstIndex(where: { $0.id == padID }) else { return }
            let parsed = self.state.pads[idx].applyObservedPageTitle(rawTitle)
            PadWorkspaceEngine.recordHistory(
                in: &self.state,
                title: parsed.cleanTitle.isEmpty ? self.state.pads[idx].title : parsed.cleanTitle,
                url: self.state.pads[idx].url
            )
            self.persistState()
            self.writeLiveUIState()
        }
        controller.onURLCommitted = { [weak self] newURL in
            guard let self, let idx = self.state.pads.firstIndex(where: { $0.id == padID }) else { return }
            let oldHost = self.state.pads[idx].url.host?.lowercased()
            let newHost = newURL.host?.lowercased()
            self.state.pads[idx].url = newURL
            if self.state.selectedPadID == padID {
                self.state.pads[idx].lastActiveAt = Date()
            }
            if oldHost != newHost {
                self.faviconCache.cancelLoad(for: padID)
            }
            PadWorkspaceEngine.recordHistory(in: &self.state, title: self.state.pads[idx].title, url: newURL)
            self.persistState()
        }
        controller.onWebContentProcessTerminated = { [weak self] in
            self?.handleWebContentProcessTerminated(for: padID)
        }
        controller.onFaviconDetected = { [weak self] iconURL in
            guard let self, let idx = self.state.pads.firstIndex(where: { $0.id == padID }) else { return }
            if self.state.pads[idx].faviconURL == nil {
                self.state.pads[idx].faviconURL = iconURL
                self.persistState()
            }
        }
        controller.onFaviconCandidatesDetected = { [weak self] candidates in
            guard let self else { return }
            self.faviconCache.resolveBestIcon(for: padID, candidates: candidates) { [weak self] winningURL in
                guard let self, let idx = self.state.pads.firstIndex(where: { $0.id == padID }) else { return }
                if self.state.pads[idx].faviconURL != winningURL {
                    self.state.pads[idx].faviconURL = winningURL
                    self.persistState()
                }
            }
        }
        controller.onNewWindowRequested = { [weak self] targetURL in
            self?.handleNewWindowURL(targetURL)
        }
        controller.onCreatePopupWebView = { [weak self] config, navAction, winFeatures in
            self?.handleCreatePopupWebView(
                fromPadID: padID,
                configuration: config,
                navigationAction: navAction,
                windowFeatures: winFeatures
            )
        }
        controller.onWebViewDidClose = { [weak self] in
            guard let self, self.scriptSpawnedPadIDs.contains(padID) else { return }
            self.scriptSpawnedPadIDs.remove(padID)
            self.removePad(padID)
        }
        controller.onDownloadStatusChanged = { [weak self] status in
            self?.statusMessage = status
        }

        controller.webView.onOpenInNewPad = { [weak self] url in
            self?.addPad(url: url, select: true)
        }
        controller.webView.onOpenInDefaultBrowser = { url in
            NSWorkspace.shared.open(url)
        }
        controller.webView.onCopyPageURL = { [weak self] in
            self?.copySelectedPadURL()
        }

        webControllers[pad.id] = controller
        enforceLivePadCapacityIfNeeded(protectedPadIDs: [pad.id])
        return controller
    }

    public func activeWebController() -> PadWebController? {
        guard areExtensionsReady, let pad = selectedPad, !pad.isHibernated else { return nil }
        return webController(for: pad)
    }

    public func existingWebView(for padID: UUID) -> WKWebView? {
        webControllers[padID]?.webView
    }

    public func existingWebController(for padID: UUID) -> PadWebController? {
        webControllers[padID]
    }

    /// Returns all currently instantiated, non-hibernated, non-PiP pad web views in workspace order
    /// so `PadDeckContainerNSView` keeps them mounted at identical bounds without reparenting or reloading.
    public func deckMountedWebViews() -> [(padID: UUID, webView: WKWebView)] {
        guard areExtensionsReady else { return [] }
        if let selected = selectedPad, !selected.isHibernated, !activePiPPadIDs.contains(selected.id) {
            _ = webController(for: selected)
        }
        return state.pads.compactMap { pad in
            guard !pad.isHibernated,
                  !activePiPPadIDs.contains(pad.id),
                  let wc = webControllers[pad.id] else {
                return nil
            }
            return (pad.id, wc.webView)
        }
    }

    public var currentPanelFrame: CGRect? {
        panel?.frame
    }

    public var panelContentRootView: NSView? {
        panel?.contentView
    }

    public func persist() {
        persistState()
    }

    // MARK: - Pad Actions

    @discardableResult
    public func addPad(
        url: URL,
        title: String? = nil,
        symbolName: String = "globe",
        userAgent: UserAgentPreset = .desktopSafari,
        select: Bool = true
    ) -> Pad {
        var created = PadWorkspaceEngine.addPad(
            to: &state,
            url: url,
            title: title,
            symbolName: symbolName,
            profileID: state.activeProfileID,
            select: select
        )
        if let idx = state.pads.firstIndex(where: { $0.id == created.id }) {
            state.pads[idx].userAgentPreset = userAgent
            created = state.pads[idx]
        }
        PadWorkspaceEngine.recordHistory(in: &state, title: created.title, url: created.url)
        if select {
            addressBarState.cancel()
            if areExtensionsReady {
                _ = webController(for: created)
            }
            refreshPanelGeometryAndAppearance()
            scheduleWebFocusRestoreIfAppropriate()
        }
        extensionManager.syncTabsWithWorkspace()
        persistState()
        writeLiveUIState()
        return created
    }

    public func selectPad(_ padID: UUID) {
        let prevSelectedID = state.selectedPadID
        guard prevSelectedID != padID else {
            if let pad = selectedPad, areExtensionsReady && !pad.isHibernated {
                _ = webController(for: pad)
            }
            return
        }
        diagnostics.padSwitchCount &+= 1
        PadWorkspaceEngine.selectPad(id: padID, in: &state)
        addressBarState.handleSelectedPadChanged(to: padID)
        if let pad = selectedPad, areExtensionsReady && !pad.isHibernated {
            let wc = webController(for: pad)
            if wc.processRecoveryState.needsRecovery {
                applyWebContentRecoveryDecision(
                    wc.recoverIfNeededAfterProcessTermination()
                )
            }
        }
        extensionManager.syncTabsWithWorkspace(previousSelectedPadID: prevSelectedID)
        refreshPanelGeometryAndAppearance()
        scheduleWebFocusRestoreIfAppropriate()
        persistState()
        writeLiveUIState()
    }

    public func selectPad(id: UUID) {
        selectPad(id)
    }

    public func cyclePad(forward: Bool) {
        if let nextID = PadWorkspaceEngine.cyclePad(forward: forward, in: &state) {
            selectPad(nextID)
        }
    }

    public func selectPadByNumber(_ number: Int) {
        if let id = PadWorkspaceEngine.selectPadByShortcutNumber(number, in: &state) {
            selectPad(id)
        }
    }

    public func removePad(_ padID: UUID) {
        scriptSpawnedPadIDs.remove(padID)
        let childPopupIDs = ephemeralPopups.values
            .filter { $0.openerPadID == padID }
            .map(\.id)
        for popupID in childPopupIDs {
            ephemeralPopups[popupID]?.closePopup()
        }
        if let pip = pipControllers.removeValue(forKey: padID) {
            pip.closeAndReturnWebView()
            activePiPPadIDs.remove(padID)
        }
        if let wc = webControllers.removeValue(forKey: padID) {
            wc.webView.removeFromSuperview()
        }
        faviconCache.removePadState(for: padID)
        _ = PadWorkspaceEngine.removePad(id: padID, from: &state)
        addressBarState.handleSelectedPadChanged(to: state.selectedPadID)
        if let pad = selectedPad, areExtensionsReady && !pad.isHibernated {
            let wc = webController(for: pad)
            if wc.processRecoveryState.needsRecovery {
                applyWebContentRecoveryDecision(
                    wc.recoverIfNeededAfterProcessTermination()
                )
            }
        }
        extensionManager.syncTabsWithWorkspace()
        refreshPanelGeometryAndAppearance()
        persistState()
        writeLiveUIState()
    }

    public func removePad(id: UUID) {
        removePad(id)
    }

    public func reopenLastClosedPad() {
        if let restored = PadWorkspaceEngine.reopenLastClosedPad(in: &state) {
            addressBarState.cancel()
            if areExtensionsReady {
                _ = webController(for: restored)
            }
            extensionManager.syncTabsWithWorkspace()
            refreshPanelGeometryAndAppearance()
            persistState()
            writeLiveUIState()
        }
    }

    public func renamePad(_ padID: UUID, newTitle: String) {
        PadWorkspaceEngine.renamePad(id: padID, newTitle: newTitle, in: &state)
        if let idx = state.pads.firstIndex(where: { $0.id == padID }),
           !state.pads[idx].hasCustomTitle,
           let liveTitle = webControllers[padID]?.webView.title,
           !liveTitle.isEmpty {
            state.pads[idx].applyObservedPageTitle(liveTitle)
        }
        persistState()
        writeLiveUIState()
    }

    public func resetPadCustomTitle(_ padID: UUID) {
        let liveTitle = webControllers[padID]?.webView.title
        PadWorkspaceEngine.resetCustomTitle(id: padID, fallbackPageTitle: liveTitle, in: &state)
        persistState()
        writeLiveUIState()
    }

    public func reorderPads(draggedID: UUID, before targetID: UUID) {
        let oldOpenIndex = state.pads.filter { !$0.isHibernated }.firstIndex(where: { $0.id == draggedID })
        PadWorkspaceEngine.reorderPad(draggedID: draggedID, before: targetID, in: &state)
        if let oldOpenIndex {
            extensionManager.notifyTabMoved(padID: draggedID, from: oldOpenIndex)
        }
        persistState()
    }

    public func movePad(id draggedID: UUID, toIndex destinationIndex: Int) {
        guard let sourceIndex = state.pads.firstIndex(where: { $0.id == draggedID }) else { return }
        let clamped = min(max(0, destinationIndex), max(0, state.pads.count - 1))
        guard sourceIndex != clamped else { return }
        let oldOpenIndex = state.pads.filter { !$0.isHibernated }.firstIndex(where: { $0.id == draggedID })
        PadWorkspaceEngine.movePad(from: sourceIndex, to: clamped, in: &state)
        if let oldOpenIndex {
            extensionManager.notifyTabMoved(padID: draggedID, from: oldOpenIndex)
        }
        persistState()
    }

    public func reloadPad(_ padID: UUID) {
        guard let pad = state.pads.first(where: { $0.id == padID }) else { return }
        if pad.isHibernated {
            setHibernated(false, for: padID)
        } else {
            webController(for: pad).reload()
        }
    }

    public func copyPadURL(_ padID: UUID) {
        guard let pad = state.pads.first(where: { $0.id == padID }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pad.url.absoluteString, forType: .string)
        statusMessage = L10n.string("panel.copied_url")
    }

    public func setHibernated(_ hibernated: Bool, for padID: UUID) {
        guard let idx = state.pads.firstIndex(where: { $0.id == padID }) else { return }
        state.pads[idx].isHibernated = hibernated
        if hibernated {
            if let pip = pipControllers.removeValue(forKey: padID) {
                pip.closeAndReturnWebView()
                activePiPPadIDs.remove(padID)
            }
            if let wc = webControllers.removeValue(forKey: padID) {
                wc.webView.removeFromSuperview()
            }
        } else {
            state.pads[idx].lastActiveAt = Date()
            if areExtensionsReady {
                _ = webController(for: state.pads[idx])
            }
        }
        extensionManager.syncTabsWithWorkspace()
        webStateRevision &+= 1
        persistState()
        writeLiveUIState()
    }

    public func wakePad(id: UUID) {
        setHibernated(false, for: id)
    }

    public func toggleMute(for padID: UUID) {
        guard let idx = state.pads.firstIndex(where: { $0.id == padID }) else { return }
        state.pads[idx].isMuted.toggle()
        let effective = state.pads[idx].isMuted || state.settings.isGlobalMuted
        webControllers[padID]?.applyMute(effective)
        extensionManager.notifyTabPropertiesChanged(padID: padID, muted: true)
        persistState()
    }

    public func toggleMute(padID: UUID) {
        toggleMute(for: padID)
    }

    public func toggleGlobalMute() {
        state.settings.isGlobalMuted.toggle()
        for pad in state.pads {
            webControllers[pad.id]?.applyMute(pad.isMuted || state.settings.isGlobalMuted)
        }
        persistState()
    }

    public func setUserAgentPreset(_ preset: UserAgentPreset, custom: String? = nil, for padID: UUID) {
        guard let idx = state.pads.firstIndex(where: { $0.id == padID }) else { return }
        state.pads[idx].userAgentPreset = preset
        if let custom {
            state.pads[idx].customUserAgent = custom
        }
        webControllers[padID]?.applyUserAgentPreset(preset, customValue: state.pads[idx].customUserAgent)
        persistState()
    }

    public func togglePauseCustomModifications(for padID: UUID) {
        guard let idx = state.pads.firstIndex(where: { $0.id == padID }) else { return }
        state.pads[idx].pauseCustomModifications.toggle()
        let paused = state.pads[idx].pauseCustomModifications
        webControllers[padID]?.applyPauseCustomModifications(paused)
        webStateRevision &+= 1
        persistState()
    }

    public func dismissCompatibilityBanner(for padID: UUID) {
        webControllers[padID]?.isCompatibilityBannerDismissed = true
        webStateRevision &+= 1
    }

    public func refreshSiteDiagnosticsSample(for padID: UUID? = nil) async {
        let resolvedPad = padID.flatMap { id in state.pads.first(where: { $0.id == id }) } ?? selectedPad
        guard let pad = resolvedPad, let wc = webControllers[pad.id] else { return }
        await wc.refreshPassiveDiagnosticsSample(includeFavicons: false)
    }

    public func buildSiteDiagnosticsReport(for padID: UUID? = nil) -> SiteDiagnosticsReport {
        let resolvedPad = padID.flatMap { id in state.pads.first(where: { $0.id == id }) } ?? selectedPad
        let wc = resolvedPad.flatMap { webControllers[$0.id] }
        let liveURL = wc?.webView.url ?? resolvedPad?.url
        let origin = SiteCompatibilityInspector.sanitizedOrigin(for: liveURL)
        let locationCategory = SiteCompatibilityInspector.classifyLocation(url: liveURL)

        let preset = resolvedPad?.userAgentPreset ?? .desktopSafari
        let appNameSuffix: String? = if let wc {
            wc.webView.configuration.applicationNameForUserAgent
        } else {
            (preset == .defaultWebKit) ? nil : UserAgentPreset.desktopSafariApplicationName
        }

        let sampledNavUA: SampledNavigatorUADiagnostic
        let observedReqUA: ObservedHTTPHeaderUADiagnostic
        if let wc {
            sampledNavUA = wc.sampledNavigatorUserAgent
            observedReqUA = wc.observedHTTPRequestUserAgent
        } else {
            let reason = (resolvedPad?.isHibernated == true)
                ? "pad is hibernated (no active WKWebView)"
                : "no active WKWebView initialized yet"
            sampledNavUA = .unavailable(reason: reason)
            observedReqUA = .notObserved(reason: reason)
        }

        let uaDiagnostics = UserAgentDiagnostics.resolve(
            preset: preset,
            padCustomUserAgent: resolvedPad?.customUserAgent,
            liveWebViewCustomUserAgent: wc?.webView.customUserAgent,
            applicationNameForUserAgent: appNameSuffix,
            sampledNavigatorUA: sampledNavUA,
            observedHTTPRequestUA: observedReqUA
        )

        let jsEnabled = wc?.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript ?? true
        let paused = resolvedPad?.pauseCustomModifications ?? false
        let matchingRulesCount = (paused || liveURL == nil)
            ? 0
            : ContentRulesEngine.matchingInjectionRules(for: liveURL!, from: state.injectionRules).count

        let webKitVersion = Bundle(for: WKWebView.self).infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "System WebKit"
        let extScopes: [ExtensionScopeDiagnostic] = extensionManager.settingsItems()
            .filter(\.isLoaded)
            .map { ext in
                let scope: String = switch ext.websiteAccessMode {
                case .allWebsites: "all-websites"
                case .ask: "ask"
                case .specificSites: "specific-sites (\(ext.grantedMatchPatterns.count))"
                }
                return ExtensionScopeDiagnostic(
                    name: ext.displayName,
                    version: ext.version,
                    websiteAccessScope: scope
                )
            }

        let topNav = wc?.buildTopLevelNavigationDiagnostic() ?? TopLevelNavigationDiagnostic()

        // If no live webController has finished sampling yet, still evaluate passive route category on `liveURL`
        let effectiveIssue: SiteCompatibilityIssueKind
        let effectiveSummary: String?
        if let wc {
            effectiveIssue = wc.compatibilityIssue
            effectiveSummary = wc.compatibilitySummary
        } else {
            let fallbackEval = SiteCompatibilityInspector.evaluatePassiveObservation(url: liveURL)
            effectiveIssue = fallbackEval.issueKind
            effectiveSummary = fallbackEval.summary
        }

        return SiteDiagnosticsReport(
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            webKitVersion: webKitVersion,
            topLevelOrigin: origin,
            locationCategory: locationCategory,
            userAgent: uaDiagnostics,
            javaScriptEnabled: jsEnabled,
            customModificationsPaused: paused,
            contentBlockerEnabled: state.settings.contentBlocker.isEnabled && !paused,
            blockedDomainCount: state.settings.contentBlocker.blockedDomains.count,
            matchingInjectionRuleCount: matchingRulesCount,
            loadedExtensions: extScopes,
            topLevelNavigation: topNav,
            subframeObservations: wc?.subframeObservations ?? [],
            iframeDiagnostics: wc?.iframeDiagnostics ?? PassiveIframeDiagnosticSummary(),
            failureCategories: wc?.failureCategories ?? [],
            issueKind: effectiveIssue,
            issueSummary: effectiveSummary
        )
    }

    public func toggleInspectable(for padID: UUID) {
        guard let idx = state.pads.firstIndex(where: { $0.id == padID }) else { return }
        state.pads[idx].isInspectable.toggle()
        webControllers[padID]?.applyInspectable(state.pads[idx].isInspectable)
        persistState()
    }

    public func switchActiveProfile(_ profileID: UUID) {
        state.activeProfileID = profileID
        if let pad = selectedPad {
            assignProfile(profileID, to: pad.id)
        } else {
            persistState()
        }
    }

    public func assignProfile(_ profileID: UUID?, to padID: UUID) {
        guard let idx = state.pads.firstIndex(where: { $0.id == padID }) else { return }
        guard state.pads[idx].profileID != profileID else { return }
        state.pads[idx].profileID = profileID
        if let old = webControllers.removeValue(forKey: padID) {
            old.webView.removeFromSuperview()
        }
        if !state.pads[idx].isHibernated {
            _ = webController(for: state.pads[idx])
        }
        webStateRevision &+= 1
        persistState()
    }

    public func updatePadSizeOverride(_ override: PanelSizeOverride?, for padID: UUID) {
        guard let idx = state.pads.firstIndex(where: { $0.id == padID }) else { return }
        state.pads[idx].sizeOverride = (override?.isEmpty == true) ? nil : override
        refreshPanelGeometryAndAppearance()
        persistState()
    }

    // MARK: - Navigation, Address Editing, Zoom, Find & PiP

    public func beginEditingAddress() {
        if !isPanelVisible {
            showPanel(activateFocus: true, openedFromEdge: false)
        } else {
            panel?.makeKey()
        }
        if let pad = selectedPad {
            let liveURL = webControllers[pad.id]?.webView.url ?? pad.url
            addressBarState.revealForCurrentPad(padID: pad.id, currentURL: liveURL)
        } else {
            addressBarState.openForNewPad()
        }
        omniboxFocusToken &+= 1
    }

    public func cancelAddressBar() {
        addressBarState.cancel()
        scheduleWebFocusRestoreIfAppropriate()
    }

    public func submitOmnibox() {
        let effect = addressBarState.submit(
            searchEngine: state.settings.searchEngine,
            customSearchTemplate: state.settings.customSearchTemplate
        )
        switch effect {
        case .none:
            break
        case .createNewPad(let url):
            _ = addPad(url: url, select: true)
        case .navigateExistingPad(let padID, let url):
            navigatePad(id: padID, to: url)
            scheduleWebFocusRestoreIfAppropriate()
        }
    }

    public func navigateSelectedPad(to url: URL) {
        if state.pads.isEmpty {
            _ = addPad(url: url, select: true)
            return
        }
        guard let pad = selectedPad else { return }
        navigatePad(id: pad.id, to: url)
    }

    public func navigatePad(id: UUID, to url: URL) {
        guard let idx = state.pads.firstIndex(where: { $0.id == id }) else { return }
        let wasExtensionPage = extensionManager.isExtensionInternalURL(state.pads[idx].url)
        let isExtensionPage = extensionManager.isExtensionInternalURL(url)
        state.pads[idx].url = url
        state.pads[idx].isHibernated = false
        state.pads[idx].lastActiveAt = Date()
        if !state.pads[idx].hasCustomTitle {
            state.pads[idx].title = url.host ?? url.absoluteString
        }
        addressBarState.cancel()
        PadWorkspaceEngine.recordHistory(in: &state, title: state.pads[idx].title, url: url)
        if wasExtensionPage != isExtensionPage, let old = webControllers.removeValue(forKey: id) {
            old.webView.removeFromSuperview()
        }

        // Prevent double load: if no controller existed yet, `webController(for:)` already loads `url` once in `init`!
        let hadExistingController = (webControllers[id] != nil)
        let wc = webController(for: state.pads[idx])
        if hadExistingController {
            wc.navigate(to: url)
        }

        extensionManager.syncTabsWithWorkspace()
        refreshPanelGeometryAndAppearance()
        persistState()
        writeLiveUIState()
    }

    public func focusOmnibox() {
        beginEditingAddress()
    }

    public func adjustZoom(delta: Double? = nil) {
        guard let pad = selectedPad,
              let idx = state.pads.firstIndex(where: { $0.id == pad.id }) else { return }
        let nextZoom: Double
        if let delta {
            nextZoom = min(max(state.pads[idx].pageZoom + delta, 0.5), 3.0)
        } else {
            nextZoom = 1.0
        }
        state.pads[idx].pageZoom = nextZoom
        webControllers[pad.id]?.applyZoom(nextZoom)
        extensionManager.notifyTabPropertiesChanged(padID: pad.id, zoom: true)
        persistState()
    }

    public func triggerFind(forward: Bool = true) {
        activeWebController()?.findInPage(findQuery, forward: forward) { [weak self] matched in
            Task { @MainActor [weak self] in
                self?.findMatchFound = matched
            }
        }
    }

    public func openSelectedPadInDefaultBrowser() {
        guard let url = selectedPad?.url else { return }
        NSWorkspace.shared.open(url)
    }

    public func copySelectedPadURL() {
        guard let pad = selectedPad else { return }
        copyPadURL(pad.id)
    }

    public func togglePiP(for padID: UUID) {
        if let existing = pipControllers.removeValue(forKey: padID) {
            activePiPPadIDs.remove(padID)
            existing.closeAndReturnWebView()
            if let wc = webControllers[padID] {
                attachToOffscreenHostIfUnparented(wc.webView)
            }
            webStateRevision &+= 1
            return
        }
        guard let pad = state.pads.first(where: { $0.id == padID }) else { return }
        if pad.isHibernated {
            setHibernated(false, for: padID)
        }
        let wc = webController(for: pad)
        let pip = PiPWindowController(pad: pad, webView: wc.webView)
        pip.onDockBackToSidebar = { [weak self] returnedID in
            guard let self else { return }
            self.pipControllers.removeValue(forKey: returnedID)
            self.activePiPPadIDs.remove(returnedID)
            if let wc = self.webControllers[returnedID] {
                self.attachToOffscreenHostIfUnparented(wc.webView)
            }
            self.webStateRevision &+= 1
        }
        pipControllers[padID] = pip
        activePiPPadIDs.insert(padID)
        webStateRevision &+= 1
    }

    private func handleNewWindowURL(_ url: URL) {
        switch state.settings.newWindowBehavior {
        case .openInNewPad:
            _ = addPad(url: url, select: true)
        case .openInCurrentPad:
            navigateSelectedPad(to: url)
        case .openInDefaultBrowser:
            NSWorkspace.shared.open(url)
        }
    }

    public static func hasExplicitPopupFeatures(_ windowFeatures: WKWindowFeatures) -> Bool {
        if windowFeatures.width != nil
            || windowFeatures.height != nil
            || windowFeatures.x != nil
            || windowFeatures.y != nil {
            return true
        }
        if windowFeatures.menuBarVisibility?.boolValue == false
            || windowFeatures.toolbarsVisibility?.boolValue == false
            || windowFeatures.statusBarVisibility?.boolValue == false {
            return true
        }
        return false
    }

    /// Production `WKUIDelegate.webView(_:createWebViewWith:for:windowFeatures:)` handler (`T269`).
    /// Honors WebKit's supplied `WKWebViewConfiguration` without issuing duplicate manual loads,
    /// keeping scripted/auth popups ephemeral (`window.opener`, `postMessage`, named reuse, `webViewDidClose`)
    /// while routing ordinary `<a target="_blank">` links per `newWindowBehavior`.
    public func handleCreatePopupWebView(
        fromPadID openerPadID: UUID,
        configuration: WKWebViewConfiguration,
        navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let disposition = PopupNavigationPolicy.classifyCreateWebView(
            requestURL: navigationAction.request.url,
            isLinkActivated: navigationAction.navigationType == .linkActivated,
            hasExplicitPopupWindowFeatures: Self.hasExplicitPopupFeatures(windowFeatures),
            newWindowBehavior: state.settings.newWindowBehavior
        )

        switch disposition {
        case .reject:
            return nil

        case .openExternallyAndReturnNil(let url):
            NSWorkspace.shared.open(url)
            return nil

        case .navigateCurrentPadAndReturnNil(let url):
            navigatePad(id: openerPadID, to: url)
            return nil

        case .newPadWithSuppliedConfiguration(let url):
            let openerPad = state.pads.first(where: { $0.id == openerPadID })
            var created = PadWorkspaceEngine.addPad(
                to: &state,
                url: url,
                title: nil,
                symbolName: "globe",
                profileID: openerPad?.profileID ?? state.activeProfileID,
                select: true
            )
            if let openerPad, let idx = state.pads.firstIndex(where: { $0.id == created.id }) {
                state.pads[idx].userAgentPreset = openerPad.userAgentPreset
                state.pads[idx].customUserAgent = openerPad.customUserAgent
                created = state.pads[idx]
            }
            scriptSpawnedPadIDs.insert(created.id)
            addressBarState.cancel()
            PadWorkspaceEngine.recordHistory(in: &state, title: created.title, url: created.url)
            let wc = webController(for: created, suppliedConfiguration: configuration)
            extensionManager.syncTabsWithWorkspace()
            refreshPanelGeometryAndAppearance()
            scheduleWebFocusRestoreIfAppropriate()
            persistState()
            writeLiveUIState()
            return wc.webView

        case .ephemeralPopupWindow:
            // Bounded popup pool (max 8 concurrent child popups)
            while ephemeralPopupOrder.count >= 8, let oldestID = ephemeralPopupOrder.first {
                ephemeralPopupOrder.removeFirst()
                ephemeralPopups.removeValue(forKey: oldestID)?.closePopup()
            }

            let offscreen = forceOffscreenPopupWindows || !isRuntimeActive
            let openerLevel = panel?.level ?? (state.settings.isAlwaysOnTop ? .statusBar : .floating)
            let popup = EphemeralPopupWindowController(
                openerPadID: openerPadID,
                suppliedConfiguration: configuration,
                windowFeatures: windowFeatures,
                openerWindowLevel: openerLevel,
                presentOffscreenOnly: offscreen
            )
            popup.onClosed = { [weak self] closedID in
                guard let self else { return }
                self.ephemeralPopups.removeValue(forKey: closedID)
                self.ephemeralPopupOrder.removeAll(where: { $0 == closedID })
                if self.isPanelVisible {
                    self.scheduleWebFocusRestoreIfAppropriate()
                }
            }
            popup.onCreateNestedPopup = { [weak self] nestedConfig, nestedAction, nestedFeatures in
                self?.handleCreatePopupWebView(
                    fromPadID: openerPadID,
                    configuration: nestedConfig,
                    navigationAction: nestedAction,
                    windowFeatures: nestedFeatures
                )
            }
            ephemeralPopups[popup.id] = popup
            ephemeralPopupOrder.append(popup.id)
            return popup.webView
        }
    }

    public func closeAllEphemeralPopups() {
        for popup in Array(ephemeralPopups.values) {
            popup.closePopup()
        }
        ephemeralPopups.removeAll()
        ephemeralPopupOrder.removeAll()
    }

    // MARK: - Settings & Welcome Windows (S8 & S9)

    public func openSettingsWindow(pane: SettingsPaneID? = nil) {
        if let pane {
            state.settings.selectedSettingsPane = pane
            persistState()
        }
        if let existing = settingsWindow {
            existing.title = L10n.string("settings.window_title")
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            writeLiveUIState()
            return
        }
        let hosting = NSHostingController(rootView: SettingsView(model: self))
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.string("settings.window_title")
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 740, height: 520))
        window.minSize = NSSize(width: 660, height: 460)
        if !window.setFrameUsingName("VeypaneSettingsWindow") {
            window.center()
        }
        window.setFrameAutosaveName("VeypaneSettingsWindow")
        window.isReleasedWhenClosed = false
        window.delegate = settingsWindowDelegate
        self.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeLiveUIState()
    }

    public func openWelcomeWindow() {
        if let existing = welcomeWindow {
            existing.title = L10n.string("welcome.window_title")
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            writeLiveUIState()
            return
        }
        let hosting = NSHostingController(rootView: WelcomeView(model: self, onTryNow: { [weak self] in
            guard let self else { return }
            self.completeOnboardingAndShowPanel()
        }))
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.string("welcome.window_title")
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.setContentSize(NSSize(width: 520, height: 440))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = welcomeWindowDelegate
        self.welcomeWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        writeLiveUIState()
    }

    public func completeOnboardingAndShowPanel() {
        state.settings.hasCompletedOnboarding = true
        persistState()
        welcomeWindow?.close()
        showPanel(activateFocus: true, openedFromEdge: false)
    }

    // MARK: - Persistence, Hotkey, Launch-at-Login, Content Blocker & Automation

    public func persistState() {
        try? store.save(state)
    }

    public func applyUpdatedHotkey(_ binding: HotkeyBinding) {
        state.settings.toggleHotkey = binding
        hotkeyManager?.register(binding: binding)
        persistState()
    }

    public func setLaunchAtLogin(_ enabled: Bool) {
        state.settings.appearance.launchAtLogin = enabled
        persistState()
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func recompileContentBlockerAndApply() async {
        do {
            if let json = try ContentRulesEngine.buildContentRuleListJSON(from: state.settings.contentBlocker) {
                let compiled = try await WKContentRuleListStore.default().compileContentRuleList(
                    forIdentifier: "VeypaneContentRules",
                    encodedContentRuleList: json
                )
                self.compiledRuleList = compiled
            } else {
                self.compiledRuleList = nil
            }
        } catch {
            self.compiledRuleList = nil
        }

        for controller in webControllers.values {
            controller.updateRules(
                injectionRules: state.injectionRules,
                compiledContentRuleList: compiledRuleList
            )
        }
    }

    public func syncAutomationServer() async {
        if automationServer == nil {
            let bridge = AppAutomationBridge(model: self)
            automationServer = LocalAutomationServer(settings: state.settings.automation, bridge: bridge)
        }
        guard let server = automationServer else { return }
        do {
            try await server.updateSettings(state.settings.automation)
        } catch {
            if state.settings.automation.isEnabled {
                statusMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Automation Actions (`veypane://`, `veypanectl`, App Intents)

    public func handleAutomationAction(_ action: VeypaneAutomationAction) {
        switch action {
        case .togglePanel:
            togglePanel(activateFocus: true)
        case .showPanel:
            showPanel(activateFocus: true, openedFromEdge: false)
        case .hidePanel:
            hidePanel()
        case .reloadStore:
            let loaded = store.load().state
            self.state = loaded
            addressBarState.handleSelectedPadChanged(to: state.selectedPadID)
            extensionManager.syncTabsWithWorkspace()
            Task {
                await extensionManager.reconcileWithStoreState()
            }
            refreshPanelGeometryAndAppearance()
            writeLiveUIState()
        case .syncExtensionsFromStore:
            let loaded = store.load().state
            self.state.installedExtensions = loaded.installedExtensions
            Task {
                await extensionManager.reconcileWithStoreState()
            }
        case .performExtensionCommand(let extensionQuery, let commandID, let padQuery):
            _ = try? extensionManager.performAutomationCommand(
                extensionQuery: extensionQuery,
                commandID: commandID,
                padQuery: padQuery
            )
        case .openURL(let url, let padQuery, let inNewPad):
            if inNewPad {
                _ = addPad(url: url, select: true)
            } else if let padQuery,
                      let target = PadWorkspaceEngine.findPad(matching: padQuery, in: state.pads) {
                selectPad(target.id)
                navigateSelectedPad(to: url)
            } else {
                navigateSelectedPad(to: url)
            }
            showPanel(activateFocus: true, openedFromEdge: false)
        case .addPad(let url, let title, let profileName):
            if let profileName,
               let profile = state.profiles.first(where: { $0.name.lowercased() == profileName.lowercased() }) {
                state.activeProfileID = profile.id
            }
            _ = addPad(url: url, title: title, select: true)
            showPanel(activateFocus: true, openedFromEdge: false)
        case .removePad(let padQuery):
            if let match = PadWorkspaceEngine.findPad(matching: padQuery, in: state.pads) {
                removePad(match.id)
            }
        case .selectPad(let padQuery):
            if let match = PadWorkspaceEngine.findPad(matching: padQuery, in: state.pads) {
                selectPad(match.id)
                showPanel(activateFocus: true, openedFromEdge: false)
            }
        case .openSettings(let rawPane):
            let pane = SettingsPaneID.resolve(rawPane)
            openSettingsWindow(pane: pane)
        case .showWelcome:
            openWelcomeWindow()
        }
    }

    // MARK: - Local Keyboard Shortcuts, Hibernate Timer & Distributed IPC

    /// Processes a panel `.keyDown` event through Veypane's production local-shortcut rules.
    /// Returns `nil` when consumed by Veypane, or `event` when passed through to AppKit's responder chain / Edit menu.
    public func processPanelKeyDownEvent(_ event: NSEvent, activePanelOverride: NSWindow? = nil) -> NSEvent? {
        let effectivePanel = activePanelOverride ?? panel
        guard isPanelVisible || activePanelOverride != nil else { return event }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if event.keyCode == 53 {
            if self.isSidebarPadDragActive {
                self.sidebarPadDragCancelToken &+= 1
                self.isSidebarPadDragActive = false
            } else if self.isAddPadPopoverPresented {
                self.isAddPadPopoverPresented = false
            } else if self.isEditingAddress {
                self.isEditingAddress = false
            } else if self.isFindBarVisible {
                self.isFindBarVisible = false
                self.scheduleWebFocusRestoreIfAppropriate()
            } else {
                self.hidePanel()
            }
            return nil
        }

        // Never intercept standard editing commands (`⌘C`, `⌘V`, `⌘X`, `⌘A`, `⌘Z`, `⇧⌘Z`):
        // let AppKit's nil-targeted Edit menu / responder chain deliver them to the real firstResponder.
        let activeMods = EdgeMonitorController.activeModifiers(from: flags)
        if StandardEditCommand.match(
            modifiers: activeMods,
            charactersIgnoringModifiers: chars,
            keyCode: event.keyCode
        ) != nil {
            return event
        }

        // Let enabled browser extensions handle manifest commands (e.g. Alt+A) when panel is key,
        // except while editing in native AppKit chrome text fields.
        if effectivePanel?.isKeyWindow == true
            && !self.isEditingAddress
            && !self.isAddPadPopoverPresented
            && !self.isFindBarVisible
            && !Self.isNativeTextResponder(effectivePanel?.firstResponder) {
            if self.extensionManager.handleKeyEvent(event) {
                return nil
            }
        }

        if event.keyCode == 48 && flags.contains(.control) {
            self.cyclePad(forward: !flags.contains(.shift))
            return nil
        }

        if flags == .command {
            switch chars {
            case "l":
                self.beginEditingAddress()
                return nil
            case "t":
                self.presentNewPadFlow()
                return nil
            case "r":
                self.activeWebController()?.reload()
                return nil
            case "[":
                self.activeWebController()?.goBack()
                return nil
            case "]":
                self.activeWebController()?.goForward()
                return nil
            case "=", "+":
                self.adjustZoom(delta: 0.1)
                return nil
            case "-":
                self.adjustZoom(delta: -0.1)
                return nil
            case "0":
                self.adjustZoom(delta: nil)
                return nil
            case "f":
                self.isFindBarVisible.toggle()
                return nil
            case "w":
                if self.state.settings.commandWHidesPanel {
                    self.hidePanel()
                } else if let id = self.selectedPad?.id {
                    self.removePad(id)
                }
                return nil
            case ",":
                self.openSettingsWindow()
                return nil
            case "1", "2", "3", "4", "5", "6", "7", "8", "9":
                if let num = Int(chars) {
                    self.selectPadByNumber(num)
                    return nil
                }
            default:
                break
            }
        }

        if flags == [.command, .shift] && chars == "t" {
            self.reopenLastClosedPad()
            return nil
        }

        return event
    }

    private func installLocalShortcutMonitor() {
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.processPanelKeyDownEvent(event)
        }
    }

    public func hasActiveModalOrSheetOrFileDialog() -> Bool {
        if simulatedModalOrFileDialogActiveForTesting || isDiagnosticsSheetPresented {
            return true
        }
        if let panel, (panel.attachedSheet != nil || !panel.sheets.isEmpty) {
            return true
        }
        if NSApp.modalWindow != nil {
            return true
        }
        if webControllers.values.contains(where: \.isPresentingOpenPanel) {
            return true
        }
        return NSApp.windows.contains(where: { ($0 is NSSavePanel) && $0.isVisible })
    }

    public func hasActivePopupMenuWindow() -> Bool {
        if simulatedMenuOpenForTesting {
            return true
        }
        return NSApp.windows.contains { win in
            guard win.isVisible else { return false }
            let cls = NSStringFromClass(type(of: win))
            return cls.contains("MenuWindow")
                || cls.contains("CarbonMenu")
                || cls.contains("PopupMenu")
        }
    }

    public func classifyLocalMouseWindow(
        _ targetWindow: NSWindow?,
        screenLocation: CGPoint = NSEvent.mouseLocation
    ) -> OutsideClickEventOrigin {
        if hasActivePopupMenuWindow() {
            return .sameApplicationMenuOrStatusItem
        }
        if let targetWindow {
            let cls = NSStringFromClass(type(of: targetWindow))
            if cls.contains("StatusBar")
                || cls.contains("MenuWindow")
                || cls.contains("CarbonMenu")
                || cls.contains("PopupMenu") {
                return .sameApplicationMenuOrStatusItem
            }
            if targetWindow === panel {
                return .sameApplicationPanel
            }
            if let panel,
               (targetWindow.parent === panel
                || targetWindow.sheetParent === panel
                || panel.childWindows?.contains(targetWindow) == true
                || panel.sheets.contains(targetWindow)) {
                return .sameApplicationPanelChildOrPopover
            }
            if cls.contains("Popover") || targetWindow is NSSavePanel {
                return .sameApplicationPanelChildOrPopover
            }
            if ephemeralPopups.values.contains(where: {
                $0.panel === targetWindow || $0.panel.childWindows?.contains(targetWindow) == true
            }) {
                return .sameApplicationEphemeralChildPopup
            }
            if cls.contains("Inspector") || targetWindow.title.localizedCaseInsensitiveContains("Web Inspector") {
                return .sameApplicationInspectorWindow
            }
            return .sameApplicationOtherStandardWindow
        }

        // Fallback when `event.window` is nil on a local mouse event: check live child/popover & panel frames.
        if let panel {
            if let children = panel.childWindows,
               children.contains(where: { $0.isVisible && $0.frame.contains(screenLocation) }) {
                return .sameApplicationPanelChildOrPopover
            }
            let liveFrame = panel.currentPresentationSample().frame.union(panel.frame)
            if liveFrame.contains(screenLocation) {
                return .sameApplicationPanel
            }
        }
        return .sameApplicationOtherStandardWindow
    }

    @discardableResult
    public func handlePointerDownForOutsideDismissal(
        origin: OutsideClickEventOrigin,
        screenLocation: CGPoint = NSEvent.mouseLocation
    ) -> OutsideClickDecision {
        outsideClickEventsObserved &+= 1
        // If a popup/context menu owned by this process is currently open, let menu tracking dismiss the menu first.
        let effectiveOrigin: OutsideClickEventOrigin = (origin == .externalApplicationOrDesktop && hasActivePopupMenuWindow())
            ? .sameApplicationMenuOrStatusItem
            : origin

        let liveFrame = panel.map { $0.currentPresentationSample().frame.union($0.frame) } ?? .zero
        let ctx = OutsideClickContext(
            isPanelTargetVisible: transitionController.isTargetVisible,
            transitionPhase: transitionController.phase,
            isPinnedOpen: state.settings.isPinnedOpen || extensionManager.isAnyPopupVisible,
            isAlwaysOnTop: state.settings.isAlwaysOnTop,
            hasActiveModalOrSheetOrFileDialog: hasActiveModalOrSheetOrFileDialog(),
            hasActiveEphemeralChildPopup: !ephemeralPopups.isEmpty,
            origin: effectiveOrigin,
            screenLocation: screenLocation,
            livePanelFrame: liveFrame
        )
        let decision = OutsideClickDismissalPolicy.evaluate(ctx)
        lastOutsideClickDecision = decision
        if decision.shouldDismiss {
            lastOutsideClickDismissalDecision = decision
            outsideClickDismissalsTriggered &+= 1
            hidePanel()
        }
        return decision
    }

    private func installOutsideClickMonitors() {
        outsideClickMonitor?.stop()
        let monitor = OutsideClickEventMonitor()
        monitor.onMouseDown = { [weak self] targetWindow, screenLocation, fromFallbackLocal in
            guard let self else { return }
            let origin: OutsideClickEventOrigin
            if let targetWindow {
                origin = self.classifyLocalMouseWindow(targetWindow, screenLocation: screenLocation)
            } else if fromFallbackLocal {
                origin = self.classifyLocalMouseWindow(nil, screenLocation: screenLocation)
            } else {
                origin = .externalApplicationOrDesktop
            }
            _ = self.handlePointerDownForOutsideDismissal(origin: origin, screenLocation: screenLocation)
        }
        monitor.start()
        self.outsideClickMonitor = monitor
    }

    public func stopRuntimeServices() {
        isRuntimeActive = false
        edgeMonitor?.stop()
        edgeMonitor = nil
        hotkeyManager?.unregister()
        hotkeyManager = nil
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        outsideClickMonitor?.stop()
        outsideClickMonitor = nil
        hibernateTimer?.invalidate()
        hibernateTimer = nil
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        DistributedNotificationCenter.default().removeObserver(ipcReceiver)
        closeAllEphemeralPopups()
        settingsWindow?.orderOut(nil)
        welcomeWindow?.orderOut(nil)
        panel?.orderOut(nil)
        offscreenWebWindow?.orderOut(nil)
    }

    private func installHibernateTimer() {
        hibernateTimer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                _ = self.runIdleHibernationPass()
            }
        }
    }

    @discardableResult
    public func runIdleHibernationPass(now: Date = Date()) -> [UUID] {
        let hibernatedIDs = PadWorkspaceEngine.hibernateIdlePads(
            in: &state,
            now: now,
            protectedPadIDs: activePiPPadIDs
        )
        if !hibernatedIDs.isEmpty {
            unloadHibernatedControllers(hibernatedIDs)
        }
        return hibernatedIDs
    }

    public func setPageRetention(autoHibernateMinutes: Int? = nil, maxLivePads: Int? = nil) {
        if let autoHibernateMinutes {
            state.settings.autoHibernateMinutes = AppSettings.sanitizedAutoHibernateMinutes(autoHibernateMinutes)
        }
        if let maxLivePads {
            state.settings.maxLivePads = AppSettings.sanitizedMaxLivePads(maxLivePads)
        }
        _ = enforceLivePadCapacityIfNeeded()
        persistState()
        writeLiveUIState()
    }

    @discardableResult
    public func enforceLivePadCapacityIfNeeded(protectedPadIDs extraProtected: Set<UUID> = []) -> [UUID] {
        let protected = activePiPPadIDs.union(extraProtected)
        let evicted = PadWorkspaceEngine.evictExcessLivePadsForCapacity(
            in: &state,
            livePadIDs: Set(webControllers.keys),
            protectedPadIDs: protected
        )
        if !evicted.isEmpty {
            diagnostics.capacityEvictions &+= evicted.count
            unloadHibernatedControllers(evicted)
        }
        return evicted
    }

    private func installMemoryPressureMonitor() {
        memoryPressureSource?.cancel()
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let event = source.data
                if event.contains(.critical) {
                    _ = self.handleSystemMemoryPressure(.critical)
                } else if event.contains(.warning) {
                    _ = self.handleSystemMemoryPressure(.warning)
                }
            }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Production memory-pressure degradation handler (`t455`).
    /// Never evicts the currently selected pad or active PiP pads; honors Always Keep on `.warning`
    /// while safely shedding background pads on `.critical` pressure.
    @discardableResult
    public func handleSystemMemoryPressure(_ severity: MemoryPressureSeverity) -> [UUID] {
        let evicted = PadWorkspaceEngine.evictPadsForMemoryPressure(
            in: &state,
            livePadIDs: Set(webControllers.keys),
            protectedPadIDs: activePiPPadIDs,
            severity: severity
        )
        if !evicted.isEmpty {
            diagnostics.memoryPressureEvictions &+= evicted.count
            unloadHibernatedControllers(evicted)
            statusMessage = L10n.format("panel.status.memory_pressure_evicted", evicted.count)
        }
        return evicted
    }

    public func handleWebContentProcessTerminated(for padID: UUID, now: Date = Date()) {
        diagnostics.webContentProcessTerminations &+= 1
        guard let wc = webControllers[padID] else {
            writeLiveUIState()
            return
        }
        // Only auto-recover immediately if the pad is currently foreground/selected;
        // background terminated pads defer recovery until the user switches back (`selectPad`).
        if state.selectedPadID == padID {
            let decision = wc.recoverIfNeededAfterProcessTermination(now: now)
            applyWebContentRecoveryDecision(decision)
        }
        writeLiveUIState()
    }

    private func applyWebContentRecoveryDecision(_ decision: WebContentRecoveryDecision) {
        switch decision {
        case .notNeeded:
            break
        case .autoReload:
            diagnostics.webContentAutoRecoveries &+= 1
            statusMessage = L10n.string("panel.status.web_process_reloading")
        case .suppressedManualReloadRequired:
            statusMessage = L10n.string("panel.status.web_process_manual_reload")
        }
    }

    private func unloadHibernatedControllers(_ padIDs: [UUID]) {
        for id in padIDs {
            if let wc = webControllers.removeValue(forKey: id) {
                wc.webView.removeFromSuperview()
            }
        }
        extensionManager.syncTabsWithWorkspace()
        webStateRevision &+= 1
        persistState()
        writeLiveUIState()
    }

    private func installDistributedIPCObserver() {
        ipcReceiver.onAction = { [weak self] action in
            self?.handleAutomationAction(action)
        }
        DistributedNotificationCenter.default().addObserver(
            ipcReceiver,
            selector: #selector(DistributedIPCReceiver.handleDistributedNotification(_:)),
            name: VeypaneIPC.distributedNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    private func installAppleEventURLHandler() {
        urlEventReceiver.onURL = { [weak self] url in
            if let action = VeypaneURLCommand.parse(url) {
                self?.handleAutomationAction(action)
            }
        }
        NSAppleEventManager.shared().setEventHandler(
            urlEventReceiver,
            andSelector: #selector(AppleEventURLReceiver.handleGetURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }
}

// MARK: - Bridge from LocalAutomationServer to MainActor AppModel

public final class AppAutomationBridge: AutomationRuntimeBridge, @unchecked Sendable {
    private weak var model: AppModel?

    public init(model: AppModel) {
        self.model = model
    }

    public func listPads() async -> [AutomationPadSummary] {
        await MainActor.run {
            guard let model else { return [] }
            return model.state.pads.map { pad in
                AutomationPadSummary(
                    id: pad.id.uuidString,
                    title: pad.title,
                    url: pad.url.absoluteString,
                    isSelected: pad.id == model.state.selectedPadID,
                    isHibernated: pad.isHibernated,
                    isMuted: pad.isMuted,
                    badge: pad.formattedBadge
                )
            }
        }
    }

    public func getPageSnapshot(padQuery: String?) async throws -> AutomationPageSnapshot {
        await MainActor.run {
            if let model, !model.areExtensionsReady {
                Task { @MainActor in
                    await model.extensionManager.loadEnabledExtensionsAtStartup()
                    model.areExtensionsReady = true
                }
            }
        }
        let (pad, controller) = try await MainActor.run { () throws -> (Pad, PadWebController) in
            guard let model else { throw AutomationBridgeError.padNotFound(padQuery ?? "") }
            let resolvedPad: Pad?
            if let padQuery, !padQuery.isEmpty {
                resolvedPad = PadWorkspaceEngine.findPad(matching: padQuery, in: model.state.pads)
            } else {
                resolvedPad = model.selectedPad
            }
            guard let pad = resolvedPad else {
                throw AutomationBridgeError.padNotFound(padQuery ?? "active")
            }
            if pad.isHibernated {
                model.setHibernated(false, for: pad.id)
            }
            let updatedPad = model.state.pads.first(where: { $0.id == pad.id }) ?? pad
            let wc = model.webController(for: updatedPad)
            return (updatedPad, wc)
        }

        return try await PageContentExtractor.extractSnapshot(
            padID: pad.id.uuidString,
            fallbackTitle: pad.title,
            fallbackURL: pad.url,
            session: controller,
            timeoutSeconds: PageContentExtractor.defaultTimeoutSeconds,
            maxCharacters: PageContentExtractor.maxTextLength
        )
    }

    public func navigate(padQuery: String?, to url: URL) async throws -> AutomationPadSummary {
        try await MainActor.run {
            guard let model else { throw AutomationBridgeError.padNotFound(padQuery ?? "") }
            let targetPad: Pad?
            if let padQuery, !padQuery.isEmpty {
                targetPad = PadWorkspaceEngine.findPad(matching: padQuery, in: model.state.pads)
            } else {
                targetPad = model.selectedPad
            }
            guard let pad = targetPad else {
                throw AutomationBridgeError.padNotFound(padQuery ?? "active")
            }
            model.selectPad(pad.id)
            model.navigateSelectedPad(to: url)
            let updated = model.state.pads.first(where: { $0.id == pad.id }) ?? pad
            return AutomationPadSummary(
                id: updated.id.uuidString,
                title: updated.title,
                url: updated.url.absoluteString,
                isSelected: true,
                isHibernated: updated.isHibernated,
                isMuted: updated.isMuted,
                badge: updated.formattedBadge
            )
        }
    }

    public func evaluateLimitedJS(padQuery: String?, script: String) async throws -> String {
        let controller = try await MainActor.run { () throws -> PadWebController in
            guard let model else { throw AutomationBridgeError.padNotFound(padQuery ?? "") }
            let targetPad: Pad?
            if let padQuery, !padQuery.isEmpty {
                targetPad = PadWorkspaceEngine.findPad(matching: padQuery, in: model.state.pads)
            } else {
                targetPad = model.selectedPad
            }
            guard let pad = targetPad else {
                throw AutomationBridgeError.padNotFound(padQuery ?? "active")
            }
            if pad.isHibernated {
                model.setHibernated(false, for: pad.id)
            }
            let updated = model.state.pads.first(where: { $0.id == pad.id }) ?? pad
            return model.webController(for: updated)
        }
        return try await controller.evaluateLimitedScript(script)
    }

    public func togglePanel(visible: Bool?) async -> Bool {
        await MainActor.run {
            guard let model else { return false }
            if let visible {
                if visible {
                    model.showPanel(activateFocus: true, openedFromEdge: false)
                } else {
                    model.hidePanel()
                }
            } else {
                model.togglePanel(activateFocus: true)
            }
            return model.isPanelVisible
        }
    }

    public func listExtensions() async -> [AutomationExtensionSummary] {
        await MainActor.run {
            guard let model else { return [] }
            return model.extensionManager.listAutomationSummaries()
        }
    }

    public func performExtensionCommand(
        extensionQuery: String,
        commandID: String,
        padQuery: String?
    ) async throws -> AutomationExtensionCommandResult {
        try await MainActor.run {
            guard let model else {
                throw AutomationBridgeError.extensionNotFound(extensionQuery)
            }
            return try model.extensionManager.performAutomationCommand(
                extensionQuery: extensionQuery,
                commandID: commandID,
                padQuery: padQuery
            )
        }
    }
}
