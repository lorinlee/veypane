import Foundation
import CoreGraphics

public enum SwipeGesturePhase: Sendable {
    case began
    case changed
    case ended
    case cancelled
}

public enum PanelGestureAction: Equatable, Sendable {
    case none
    case nextPad
    case previousPad
    case hidePanel
}

/// Evaluates horizontal trackpad scroll/swipe sequences on the slide-over panel header/sidebar
/// to cycle pads or dismiss toward the anchored screen edge (SPEC.md #11).
public struct GestureRecognizerEngine: Equatable, Sendable {
    public private(set) var accumulatedDeltaX: CGFloat = 0
    public private(set) var accumulatedDeltaY: CGFloat = 0
    public private(set) var hasTriggeredInCurrentSequence: Bool = false

    public var threshold: CGFloat

    public init(threshold: CGFloat = 55.0) {
        self.threshold = threshold
    }

    public mutating func reset() {
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        hasTriggeredInCurrentSequence = false
    }

    /// Processes a scrollWheel event sample (`scrollingDeltaX`, `scrollingDeltaY`) or direct `swipeWithEvent` delta.
    /// Positive `deltaX` = finger moving right; negative `deltaX` = finger moving left.
    public mutating func handleScroll(
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: SwipeGesturePhase,
        anchor: AnchorPosition,
        onChromeArea: Bool
    ) -> PanelGestureAction {
        switch phase {
        case .began:
            accumulatedDeltaX = deltaX
            accumulatedDeltaY = deltaY
            hasTriggeredInCurrentSequence = false
            return evaluateThreshold(anchor: anchor, onChromeArea: onChromeArea)

        case .changed:
            guard !hasTriggeredInCurrentSequence else { return .none }
            accumulatedDeltaX += deltaX
            accumulatedDeltaY += deltaY
            return evaluateThreshold(anchor: anchor, onChromeArea: onChromeArea)

        case .ended, .cancelled:
            defer { reset() }
            guard !hasTriggeredInCurrentSequence else { return .none }
            accumulatedDeltaX += deltaX
            accumulatedDeltaY += deltaY
            return evaluateThreshold(anchor: anchor, onChromeArea: onChromeArea)
        }
    }

    /// Processes discrete 3-finger `NSEvent.swipe(with:)` events (`deltaX` is typically `-1` right or `+1` left in AppKit).
    public static func handleDiscreteSwipe(
        appKitDeltaX: CGFloat,
        anchor: AnchorPosition
    ) -> PanelGestureAction {
        guard abs(appKitDeltaX) > 0.1 else { return .none }
        // In AppKit `swipeWithEvent:`, negative deltaX means swipe right, positive deltaX means swipe left.
        let movingRight = appKitDeltaX < 0
        let movingTowardAnchorEdge = anchor.isLeftAligned ? !movingRight : movingRight
        if movingTowardAnchorEdge {
            return .hidePanel
        }
        return movingRight ? .previousPad : .nextPad
    }

    private mutating func evaluateThreshold(
        anchor: AnchorPosition,
        onChromeArea: Bool
    ) -> PanelGestureAction {
        // Ignore predominantly vertical scrolling
        guard abs(accumulatedDeltaX) >= threshold,
              abs(accumulatedDeltaX) > abs(accumulatedDeltaY) * 1.4 else {
            return .none
        }

        hasTriggeredInCurrentSequence = true
        let movingRight = accumulatedDeltaX > 0

        if onChromeArea {
            // On toolbar/chrome strip: horizontal swipe cycles pads; strong swipe on sidebar toward edge hides
            return movingRight ? .previousPad : .nextPad
        } else {
            // On edge border strip: swipe toward anchored screen edge hides the panel
            let movingTowardEdge = anchor.isLeftAligned ? !movingRight : movingRight
            return movingTowardEdge ? .hidePanel : .none
        }
    }
}
