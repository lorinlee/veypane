import Foundation
import CoreGraphics

public enum OutsideClickEventOrigin: String, Codable, Equatable, Sendable {
    /// Mouse-down delivered to an external process or the desktop (`NSEvent.addGlobalMonitorForEvents`).
    case externalApplicationOrDesktop
    /// Mouse-down inside `SlideOverPanel` itself (`event.window === panel`).
    case sameApplicationPanel
    /// Mouse-down inside a child window, attached sheet, or `NSPopover` anchored to `SlideOverPanel`.
    case sameApplicationPanelChildOrPopover
    /// Mouse-down inside an `NSMenu` popup window or `NSStatusItem` menu bar button window.
    case sameApplicationMenuOrStatusItem
    /// Mouse-down inside an ephemeral child popup window (`EphemeralPopupWindowController`).
    case sameApplicationEphemeralChildPopup
    /// Mouse-down inside a detached WebKit Web Inspector window.
    case sameApplicationInspectorWindow
    /// Mouse-down inside another standalone window in the same process (e.g. `Settings` or `Welcome` window).
    case sameApplicationOtherStandardWindow
}

public enum OutsideClickKeepOpenReason: String, Codable, Equatable, Sendable {
    case panelNotVisible
    case panelPinnedOpen
    case activeModalOrSheetOrFileDialog
    case activeEphemeralChildPopup
    case insidePanelWindow
    case insideChildOrPopoverWindow
    case activeMenuOrStatusItemWindow
    case activeInspectorWindow
}

public enum OutsideClickDismissReason: String, Codable, Equatable, Sendable {
    case externalClick
    case midAnimationExternalClick
    case sameApplicationOtherWindowClick
    case midAnimationSameApplicationOtherWindowClick
}

public enum OutsideClickDecision: Codable, Equatable, Sendable {
    case keepOpen(OutsideClickKeepOpenReason)
    case dismissPanel(OutsideClickDismissReason)

    public var shouldDismiss: Bool {
        if case .dismissPanel = self { return true }
        return false
    }
}

public struct OutsideClickContext: Equatable, Sendable {
    public var isPanelTargetVisible: Bool
    public var transitionPhase: PanelTransitionPhase
    public var isPinnedOpen: Bool
    public var isAlwaysOnTop: Bool
    public var hasActiveModalOrSheetOrFileDialog: Bool
    public var hasActiveEphemeralChildPopup: Bool
    public var origin: OutsideClickEventOrigin
    public var screenLocation: CGPoint
    public var livePanelFrame: CGRect

    public init(
        isPanelTargetVisible: Bool,
        transitionPhase: PanelTransitionPhase,
        isPinnedOpen: Bool,
        isAlwaysOnTop: Bool = false,
        hasActiveModalOrSheetOrFileDialog: Bool = false,
        hasActiveEphemeralChildPopup: Bool = false,
        origin: OutsideClickEventOrigin,
        screenLocation: CGPoint = .zero,
        livePanelFrame: CGRect = .zero
    ) {
        self.isPanelTargetVisible = isPanelTargetVisible
        self.transitionPhase = transitionPhase
        self.isPinnedOpen = isPinnedOpen
        self.isAlwaysOnTop = isAlwaysOnTop
        self.hasActiveModalOrSheetOrFileDialog = hasActiveModalOrSheetOrFileDialog
        self.hasActiveEphemeralChildPopup = hasActiveEphemeralChildPopup
        self.origin = origin
        self.screenLocation = screenLocation
        self.livePanelFrame = livePanelFrame
    }
}

/// Deterministic clean-room policy for dismissing Veypane's slide-over panel on outside clicks (`t304`),
/// while preserving pinned state, child popovers, menus/status items, modal sheets/file dialogs,
/// ephemeral child auth popups, and Web Inspector windows.
public enum OutsideClickDismissalPolicy {
    public static func evaluate(_ context: OutsideClickContext) -> OutsideClickDecision {
        guard context.isPanelTargetVisible else {
            return .keepOpen(.panelNotVisible)
        }
        if context.isPinnedOpen {
            return .keepOpen(.panelPinnedOpen)
        }
        if context.hasActiveModalOrSheetOrFileDialog {
            return .keepOpen(.activeModalOrSheetOrFileDialog)
        }
        if context.hasActiveEphemeralChildPopup {
            return .keepOpen(.activeEphemeralChildPopup)
        }

        let isMidShowAnimation = (context.transitionPhase == .showing)

        switch context.origin {
        case .sameApplicationPanel:
            return .keepOpen(.insidePanelWindow)
        case .sameApplicationPanelChildOrPopover:
            return .keepOpen(.insideChildOrPopoverWindow)
        case .sameApplicationMenuOrStatusItem:
            return .keepOpen(.activeMenuOrStatusItemWindow)
        case .sameApplicationEphemeralChildPopup:
            return .keepOpen(.activeEphemeralChildPopup)
        case .sameApplicationInspectorWindow:
            return .keepOpen(.activeInspectorWindow)
        case .sameApplicationOtherStandardWindow:
            return .dismissPanel(
                isMidShowAnimation
                    ? .midAnimationSameApplicationOtherWindowClick
                    : .sameApplicationOtherWindowClick
            )
        case .externalApplicationOrDesktop:
            return .dismissPanel(
                isMidShowAnimation
                    ? .midAnimationExternalClick
                    : .externalClick
            )
        }
    }
}
