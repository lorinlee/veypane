import AppKit
import CoreGraphics
import VeypaneCore

@MainActor
public final class EdgeMonitorController {
    private var timer: Timer?
    private var triggerEngine = EdgeTriggerEngine()
    private var cachedDisplays: [DisplayDescriptor] = []
    private var cachedFullScreenState: (timestamp: TimeInterval, screenFrame: CGRect, isFullScreen: Bool)?
    private var screenObserver: NSObjectProtocol?
    private var workspaceObserver: NSObjectProtocol?

    public var settingsProvider: (() -> AppSettings)?
    public var currentPanelFrameProvider: (() -> CGRect)?
    public var presentedDisplayProvider: (() -> DisplayDescriptor?)?
    public var presentedAnchorProvider: (() -> AnchorPosition?)?
    public var isPanelAnimatingInProvider: (() -> Bool)?
    public var onShowRequested: ((DisplayDescriptor) -> Void)?
    public var onHideRequested: (() -> Void)?

    public init() {}

    public func start() {
        stop()
        cachedDisplays = Self.currentDisplays()

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cachedDisplays = Self.currentDisplays()
                self?.cachedFullScreenState = nil
            }
        }

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cachedFullScreenState = nil
            }
        }

        let newTimer = Timer.scheduledTimer(withTimeInterval: 0.045, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        self.timer = newTimer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
            self.workspaceObserver = nil
        }
    }

    public func syncPanelVisibility(
        _ visible: Bool,
        pointerAlreadyInside: Bool = false,
        requireTriggerExitBeforeReshow: Bool = false
    ) {
        triggerEngine.setPanelVisible(
            visible,
            pointerAlreadyInside: pointerAlreadyInside,
            requireTriggerExitBeforeReshow: requireTriggerExitBeforeReshow
        )
    }

    public static func currentDisplays() -> [DisplayDescriptor] {
        let mainScreen = NSScreen.main
        return NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return DisplayDescriptor(
                id: number.uint32Value,
                name: screen.localizedName,
                frame: screen.frame,
                visibleFrame: screen.visibleFrame,
                isMain: screen == mainScreen
            )
        }
    }

    public static func activeModifiers(from flags: NSEvent.ModifierFlags) -> HotkeyModifiers {
        var out: HotkeyModifiers = []
        if flags.contains(.control) { out.insert(.control) }
        if flags.contains(.option)  { out.insert(.option) }
        if flags.contains(.shift)   { out.insert(.shift) }
        if flags.contains(.command) { out.insert(.command) }
        return out
    }

    /// Heuristic for active full-screen app / full-screen game on a given screen.
    public static func isFullScreenAppCovering(screenFrame: CGRect) -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return false
        }
        // Check if menu bar is hidden in full screen or if frontmost app has a window covering full screen bounds
        let presentationOptions = NSApplication.shared.currentSystemPresentationOptions
        if presentationOptions.contains(.fullScreen) || presentationOptions.contains(.autoHideMenuBar) {
            return true
        }

        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        let frontPID = Int(frontApp.processIdentifier)
        for entry in windowList {
            guard let ownerPID = entry[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == frontPID,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary else {
                continue
            }
            var rect = CGRect.zero
            if CGRectMakeWithDictionaryRepresentation(boundsDict, &rect) {
                if rect.width >= screenFrame.width - 2 && rect.height >= screenFrame.height - 2 {
                    return true
                }
            }
        }
        return false
    }

    private func tick() {
        guard let appSettings = settingsProvider?() else { return }
        if isPanelAnimatingInProvider?() == true {
            return
        }

        let mouseLoc = NSEvent.mouseLocation
        if cachedDisplays.isEmpty {
            cachedDisplays = Self.currentDisplays()
        }
        let targetDisplay: DisplayDescriptor
        if triggerEngine.isPanelVisible,
           let locked = DisplaySelector.resolveLockedDisplay(
               locked: presentedDisplayProvider?(),
               panelFrame: currentPanelFrameProvider?() ?? .zero,
               in: cachedDisplays
           ) {
            targetDisplay = locked
        } else if let selected = DisplaySelector.selectDisplay(
            from: cachedDisplays,
            mode: appSettings.displayTarget,
            mouseLocation: mouseLoc
        ) {
            targetDisplay = selected
        } else {
            return
        }

        let effectiveAnchor = (triggerEngine.isPanelVisible ? presentedAnchorProvider?() : nil) ?? appSettings.anchor

        let fallbackVisibleRect = PanelGeometry.visibleFrame(
            screenVisibleFrame: targetDisplay.visibleFrame,
            anchor: effectiveAnchor,
            defaultWidthPercent: appSettings.widthPercent,
            defaultHeightPercent: appSettings.heightPercent,
            edgeInset: appSettings.edgeInset
        )
        let providedRect = currentPanelFrameProvider?() ?? .zero
        let visiblePanelRect = (providedRect.width > 10 && providedRect.height > 10)
            ? providedRect
            : fallbackVisibleRect

        let now = ProcessInfo.processInfo.systemUptime
        let isMouseButtonDown = NSEvent.pressedMouseButtons != 0
        let modifiers = Self.activeModifiers(from: NSEvent.modifierFlags)

        // Only query WindowServer for full-screen windows when panel is hidden AND pointer is inside the narrow trigger strip!
        let isFullScreen: Bool
        if !triggerEngine.isPanelVisible && appSettings.edgeTrigger.ignoreInFullScreenApps {
            let zone = PanelGeometry.triggerZone(
                screenFrame: targetDisplay.frame,
                anchor: effectiveAnchor,
                thickness: appSettings.edgeTrigger.triggerThickness,
                cornerSpan: appSettings.edgeTrigger.cornerSpan
            )
            if zone.contains(mouseLoc) {
                if let cached = cachedFullScreenState,
                   cached.screenFrame == targetDisplay.frame,
                   now - cached.timestamp < 1.0 {
                    isFullScreen = cached.isFullScreen
                } else {
                    let computed = Self.isFullScreenAppCovering(screenFrame: targetDisplay.frame)
                    cachedFullScreenState = (now, targetDisplay.frame, computed)
                    isFullScreen = computed
                }
            } else {
                isFullScreen = false
            }
        } else {
            isFullScreen = false
        }

        let context = PointerContext(
            location: mouseLoc,
            timestamp: now,
            screenFrame: targetDisplay.frame,
            visiblePanelFrame: visiblePanelRect,
            activeModifiers: modifiers,
            isDragging: isMouseButtonDown,
            isFullScreenAppActive: isFullScreen,
            isPinnedOpen: appSettings.isPinnedOpen
        )

        let decision = triggerEngine.evaluate(
            context: context,
            anchor: effectiveAnchor,
            settings: appSettings.edgeTrigger
        )

        switch decision {
        case .none:
            break
        case .showPanel:
            onShowRequested?(targetDisplay)
        case .hidePanel:
            onHideRequested?()
        }
    }
}
