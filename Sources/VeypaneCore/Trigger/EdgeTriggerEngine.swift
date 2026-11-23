import Foundation
import CoreGraphics

public enum EdgeTriggerPhase: Equatable, Sendable {
    case hidden
    case dwelling(startedAt: TimeInterval)
    case visible
    case dismissGrace(startedAt: TimeInterval)
}

public enum EdgeTriggerDecision: Equatable, Sendable {
    case none
    case showPanel
    case hidePanel
}

public struct PointerContext: Equatable, Sendable {
    public var location: CGPoint
    public var timestamp: TimeInterval
    public var screenFrame: CGRect
    public var visiblePanelFrame: CGRect
    public var activeModifiers: HotkeyModifiers
    public var isDragging: Bool
    public var isFullScreenAppActive: Bool
    public var isPinnedOpen: Bool

    public init(
        location: CGPoint,
        timestamp: TimeInterval,
        screenFrame: CGRect,
        visiblePanelFrame: CGRect,
        activeModifiers: HotkeyModifiers = [],
        isDragging: Bool = false,
        isFullScreenAppActive: Bool = false,
        isPinnedOpen: Bool = false
    ) {
        self.location = location
        self.timestamp = timestamp
        self.screenFrame = screenFrame
        self.visiblePanelFrame = visiblePanelFrame
        self.activeModifiers = activeModifiers
        self.isDragging = isDragging
        self.isFullScreenAppActive = isFullScreenAppActive
        self.isPinnedOpen = isPinnedOpen
    }
}

/// Deterministic state machine for edge/corner dwell triggering and grace-delay auto-dismissal with hysteresis.
/// Note: when opened via CLI, hotkey, or menu bar (`pointerEnteredSinceShow == false`), the panel stays open
/// until the user moves the pointer into the panel and subsequently leaves it for longer than `dismissGraceMilliseconds`.
public struct EdgeTriggerEngine: Equatable, Sendable {
    public private(set) var phase: EdgeTriggerPhase
    public private(set) var hasPointerEnteredSinceShow: Bool
    public private(set) var mustExitTriggerZoneBeforeNextShow: Bool
    public var retentionPadding: CGFloat

    public init(
        initialPhase: EdgeTriggerPhase = .hidden,
        retentionPadding: CGFloat = 14.0
    ) {
        self.phase = initialPhase
        self.hasPointerEnteredSinceShow = (initialPhase == .visible)
        self.mustExitTriggerZoneBeforeNextShow = false
        self.retentionPadding = retentionPadding
    }

    public var isPanelVisible: Bool {
        switch phase {
        case .visible, .dismissGrace:
            return true
        case .hidden, .dwelling:
            return false
        }
    }

    public mutating func setPanelVisible(
        _ visible: Bool,
        pointerAlreadyInside: Bool = false,
        requireTriggerExitBeforeReshow: Bool = false
    ) {
        phase = visible ? .visible : .hidden
        hasPointerEnteredSinceShow = visible ? pointerAlreadyInside : false
        mustExitTriggerZoneBeforeNextShow = (!visible && requireTriggerExitBeforeReshow)
    }

    public mutating func evaluate(
        context: PointerContext,
        anchor: AnchorPosition,
        settings: EdgeTriggerSettings
    ) -> EdgeTriggerDecision {
        switch phase {
        case .hidden, .dwelling:
            guard settings.isEnabled else {
                phase = .hidden
                return .none
            }
            if settings.ignoreWhileDragging && context.isDragging {
                phase = .hidden
                return .none
            }
            if settings.ignoreInFullScreenApps && context.isFullScreenAppActive {
                phase = .hidden
                return .none
            }
            if !settings.requiredModifiers.isEmpty &&
                !context.activeModifiers.isSuperset(of: settings.requiredModifiers) {
                phase = .hidden
                return .none
            }

            let zone = PanelGeometry.triggerZone(
                screenFrame: context.screenFrame,
                anchor: anchor,
                thickness: settings.triggerThickness,
                cornerSpan: settings.cornerSpan
            )

            let hitZone = zone.insetBy(dx: -1.0, dy: -1.0)
            guard hitZone.contains(context.location) else {
                mustExitTriggerZoneBeforeNextShow = false
                phase = .hidden
                return .none
            }
            if mustExitTriggerZoneBeforeNextShow {
                phase = .hidden
                return .none
            }

            let dwellSeconds = Double(max(0, settings.dwellMilliseconds)) / 1000.0
            if dwellSeconds <= 0.001 {
                phase = .visible
                hasPointerEnteredSinceShow = true
                return .showPanel
            }

            switch phase {
            case .hidden:
                phase = .dwelling(startedAt: context.timestamp)
                return .none
            case .dwelling(let startedAt):
                if context.timestamp - startedAt >= dwellSeconds {
                    phase = .visible
                    hasPointerEnteredSinceShow = true
                    return .showPanel
                }
                return .none
            default:
                return .none
            }

        case .visible, .dismissGrace:
            if context.isPinnedOpen || context.isDragging {
                phase = .visible
                return .none
            }

            let keepAliveZone = context.visiblePanelFrame
                .insetBy(dx: -retentionPadding, dy: -retentionPadding)
                .union(
                    PanelGeometry.triggerZone(
                        screenFrame: context.screenFrame,
                        anchor: anchor,
                        thickness: max(settings.triggerThickness, 8.0),
                        cornerSpan: settings.cornerSpan
                    )
                )

            if keepAliveZone.contains(context.location) {
                hasPointerEnteredSinceShow = true
                phase = .visible
                return .none
            }

            // Do not auto-dismiss a hotkey/CLI/menu-summoned panel until the pointer has actually visited it
            guard hasPointerEnteredSinceShow else {
                phase = .visible
                return .none
            }

            let graceSeconds = Double(max(0, settings.dismissGraceMilliseconds)) / 1000.0
            if graceSeconds <= 0.001 {
                phase = .hidden
                hasPointerEnteredSinceShow = false
                return .hidePanel
            }

            switch phase {
            case .visible:
                phase = .dismissGrace(startedAt: context.timestamp)
                return .none
            case .dismissGrace(let startedAt):
                if context.timestamp - startedAt >= graceSeconds {
                    phase = .hidden
                    hasPointerEnteredSinceShow = false
                    return .hidePanel
                }
                return .none
            default:
                return .none
            }
        }
    }
}
