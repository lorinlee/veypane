import Foundation
import CoreGraphics

public struct DisplayDescriptor: Equatable, Sendable, Identifiable {
    public var id: UInt32
    public var name: String
    public var frame: CGRect
    public var visibleFrame: CGRect
    public var isMain: Bool

    public init(
        id: UInt32,
        name: String,
        frame: CGRect,
        visibleFrame: CGRect? = nil,
        isMain: Bool = false
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.visibleFrame = visibleFrame ?? frame
        self.isMain = isMain
    }
}

public enum DisplaySelector {
    /// Selects the target display for the slide-over panel based on `DisplayTargetMode` and current pointer position.
    public static func selectDisplay(
        from displays: [DisplayDescriptor],
        mode: DisplayTargetMode,
        mouseLocation: CGPoint
    ) -> DisplayDescriptor? {
        guard !displays.isEmpty else { return nil }

        switch mode {
        case .pinnedDisplay(let targetID, _):
            if let exact = displays.first(where: { $0.id == targetID }) {
                return exact
            }
            // Fallback to display containing cursor, or main display
            return displayContaining(point: mouseLocation, in: displays)
                ?? displays.first(where: \.isMain)
                ?? displays.first

        case .followMouse:
            return displayContaining(point: mouseLocation, in: displays)
                ?? displays.first(where: \.isMain)
                ?? displays.first
        }
    }

    public static func displayContaining(point: CGPoint, in displays: [DisplayDescriptor]) -> DisplayDescriptor? {
        if let hit = displays.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(point) }) {
            return hit
        }
        return nil
    }

    /// Resolves the live `DisplayDescriptor` matching a previously locked display ID (or largest intersection with `panelFrame`).
    public static func resolveLockedDisplay(
        locked: DisplayDescriptor?,
        panelFrame: CGRect,
        in displays: [DisplayDescriptor]
    ) -> DisplayDescriptor? {
        if let locked {
            if let exact = displays.first(where: { $0.id == locked.id }) {
                return exact
            }
            // If display list is empty (e.g. headless test), keep the locked descriptor
            if displays.isEmpty {
                return locked
            }
        }
        if panelFrame.width > 10 && panelFrame.height > 10 {
            let best = displays
                .map { desc -> (DisplayDescriptor, CGFloat) in
                    let inter = desc.frame.intersection(panelFrame)
                    let area = inter.isNull ? 0 : inter.width * inter.height
                    return (desc, area)
                }
                .max(by: { $0.1 < $1.1 })
            if let best, best.1 > 0 {
                return best.0
            }
        }
        return locked
    }
}

public enum SiteSizeRuleMatcher {
    /// Resolves effective size override for a pad: explicit per-pad override wins over matching host rules.
    public static func effectiveOverride(
        for pad: Pad,
        rules: [SiteSizeRule]
    ) -> PanelSizeOverride? {
        if let padOverride = pad.sizeOverride, !padOverride.isEmpty {
            return padOverride
        }
        guard let host = pad.url.host?.lowercased(), !host.isEmpty else {
            return nil
        }
        for rule in rules where rule.isEnabled && !rule.sizeOverride.isEmpty {
            if matchesHost(host, pattern: rule.hostPattern) {
                return rule.sizeOverride
            }
        }
        return nil
    }

    public static func matchesHost(_ host: String, pattern: String) -> Bool {
        let cleanHost = host.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanPattern = pattern.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, !cleanPattern.isEmpty else { return false }

        if cleanPattern == "*" { return true }
        if cleanPattern.hasPrefix("*.") {
            let suffix = String(cleanPattern.dropFirst(2))
            return cleanHost == suffix || cleanHost.hasSuffix("." + suffix)
        }
        return cleanHost == cleanPattern || cleanHost.hasSuffix("." + cleanPattern)
    }
}

public enum PanelResizeHandle: String, CaseIterable, Equatable, Sendable {
    case top
    case bottom
    case left
    case right
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    public var resizesHorizontally: Bool {
        switch self {
        case .left, .right, .topLeft, .topRight, .bottomLeft, .bottomRight: true
        case .top, .bottom: false
        }
    }

    public var resizesVertically: Bool {
        switch self {
        case .top, .bottom, .topLeft, .topRight, .bottomLeft, .bottomRight: true
        case .left, .right: false
        }
    }

    public var isCorner: Bool {
        resizesHorizontally && resizesVertically
    }
}

public enum PanelGeometry {
    public static let minPanelWidth: CGFloat = 320
    public static let minPanelHeight: CGFloat = 340
    public static let minPercent: Double = 15.0
    public static let maxPercent: Double = 96.0
    public static let defaultResizeEdgeBand: CGFloat = 5.0
    public static let defaultResizeCornerSpan: CGFloat = 15.0
    public static let defaultResizeExteriorSlop: CGFloat = 3.0

    /// Computes the on-screen visible frame for the slide-over panel in macOS screen coordinates (origin bottom-left).
    /// Insets the floating card by `edgeInset` (default 14 pt) from the trigger screen edge and from top/bottom of `screenVisibleFrame`.
    public static func visibleFrame(
        screenVisibleFrame: CGRect,
        anchor: AnchorPosition,
        defaultWidthPercent: Double = AppSettings.defaultWidthPercent,
        defaultHeightPercent: Double = AppSettings.defaultHeightPercent,
        override: PanelSizeOverride? = nil,
        edgeInset: Double = AppSettings.defaultEdgeInset
    ) -> CGRect {
        let inset = CGFloat(max(0, edgeInset))
        let effectiveInsetX = min(inset, max(0, (screenVisibleFrame.width - 64) / 2.0))
        let effectiveInsetY = min(inset, max(0, (screenVisibleFrame.height - 64) / 2.0))
        let availableWidth = max(64, (screenVisibleFrame.width - effectiveInsetX * 2).rounded(.down))
        let availableHeight = max(64, (screenVisibleFrame.height - effectiveInsetY * 2).rounded(.down))

        let rawWidth: CGFloat
        if let fixedW = override?.fixedWidth, fixedW > 0 {
            rawWidth = CGFloat(fixedW)
        } else {
            let pct = clamp(override?.widthPercent ?? defaultWidthPercent, min: minPercent, max: maxPercent)
            rawWidth = screenVisibleFrame.width * CGFloat(pct / 100.0)
        }

        let rawHeight: CGFloat
        if let fixedH = override?.fixedHeight, fixedH > 0 {
            rawHeight = CGFloat(fixedH)
        } else {
            let pct = clamp(override?.heightPercent ?? defaultHeightPercent, min: minPercent, max: maxPercent)
            rawHeight = screenVisibleFrame.height * CGFloat(pct / 100.0)
        }

        let minW = min(minPanelWidth, availableWidth)
        let minH = min(minPanelHeight, availableHeight)
        let width = min(max(rawWidth.rounded(), minW), availableWidth)
        let height = min(max(rawHeight.rounded(), minH), availableHeight)

        let minXAllowed = screenVisibleFrame.minX + effectiveInsetX
        let maxXAllowed = max(minXAllowed, screenVisibleFrame.maxX - width - effectiveInsetX)
        let x: CGFloat = anchor.isLeftAligned ? minXAllowed : maxXAllowed

        let minYAllowed = screenVisibleFrame.minY + effectiveInsetY
        let maxYAllowed = max(minYAllowed, screenVisibleFrame.maxY - height - effectiveInsetY)

        let y: CGFloat
        switch anchor {
        case .left, .right:
            let centered = (screenVisibleFrame.midY - height / 2.0).rounded()
            y = min(max(centered, minYAllowed), maxYAllowed)
        case .topLeft, .topRight:
            y = maxYAllowed
        case .bottomLeft, .bottomRight:
            y = minYAllowed
        }

        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Computes the off-screen frame from which the panel slides in (or to which it slides out).
    /// Side edges (`left`, `right`) translate purely horizontally; corners (`topLeft`, `topRight`,
    /// `bottomLeft`, `bottomRight`) translate diagonally from/toward that physical corner of `screenFrame`.
    public static func hiddenFrame(
        visibleFrame: CGRect,
        screenFrame: CGRect,
        anchor: AnchorPosition,
        offscreenGap: Double = 16.0
    ) -> CGRect {
        let gap = CGFloat(max(4.0, offscreenGap))
        var frame = visibleFrame
        if anchor.isLeftAligned {
            frame.origin.x = screenFrame.minX - visibleFrame.width - gap
        } else {
            frame.origin.x = screenFrame.maxX + gap
        }
        switch anchor {
        case .left, .right:
            frame.origin.y = visibleFrame.origin.y
        case .topLeft, .topRight:
            frame.origin.y = screenFrame.maxY + gap
        case .bottomLeft, .bottomRight:
            frame.origin.y = screenFrame.minY - visibleFrame.height - gap
        }
        return frame
    }

    /// Computes the hot-edge or hot-corner trigger rectangle on the physical `screenFrame` (origin bottom-left).
    public static func triggerZone(
        screenFrame: CGRect,
        anchor: AnchorPosition,
        thickness: Double = 4.0,
        cornerSpan: Double = 48.0
    ) -> CGRect {
        let strip = CGFloat(max(1.0, min(thickness, 32.0)))
        let span = CGFloat(max(16.0, min(cornerSpan, min(screenFrame.width, screenFrame.height) / 2.0)))

        switch anchor {
        case .left:
            // Center 80% of left edge so OS hot corners don't collide unintentionally
            let verticalMargin = (screenFrame.height * 0.08).rounded()
            return CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY + verticalMargin,
                width: strip,
                height: max(32.0, screenFrame.height - verticalMargin * 2)
            )
        case .right:
            let verticalMargin = (screenFrame.height * 0.08).rounded()
            return CGRect(
                x: screenFrame.maxX - strip,
                y: screenFrame.minY + verticalMargin,
                width: strip,
                height: max(32.0, screenFrame.height - verticalMargin * 2)
            )
        case .topLeft:
            return CGRect(
                x: screenFrame.minX,
                y: screenFrame.maxY - span,
                width: span,
                height: span
            )
        case .topRight:
            return CGRect(
                x: screenFrame.maxX - span,
                y: screenFrame.maxY - span,
                width: span,
                height: span
            )
        case .bottomLeft:
            return CGRect(
                x: screenFrame.minX,
                y: screenFrame.minY,
                width: span,
                height: span
            )
        case .bottomRight:
            return CGRect(
                x: screenFrame.maxX - span,
                y: screenFrame.minY,
                width: span,
                height: span
            )
        }
    }

    /// Hit-tests perimeter resize handles in AppKit window coordinates (`(0, 0)` at bottom-left, `(width, height)` at top-right).
    /// Evaluates `cornerSpan × cornerSpan` corner regions BEFORE single-edge bands so rounded-corner hover/drag
    /// (including `topLeft` with `cornerRadius = 12`) never falls into single-axis `left` or `top` resize.
    public static func hitTestResizeHandle(
        pointInWindow point: CGPoint,
        windowSize: CGSize,
        edgeBand: CGFloat = defaultResizeEdgeBand,
        cornerSpan: CGFloat = defaultResizeCornerSpan,
        exteriorSlop: CGFloat = defaultResizeExteriorSlop
    ) -> PanelResizeHandle? {
        guard windowSize.width > cornerSpan * 2, windowSize.height > cornerSpan * 2 else {
            return nil
        }
        let slop = max(0, exteriorSlop)
        let expandedBounds = CGRect(origin: .zero, size: windowSize).insetBy(dx: -slop, dy: -slop)
        guard expandedBounds.contains(point) else {
            return nil
        }

        let inLeftCorner = point.x <= cornerSpan
        let inRightCorner = point.x >= (windowSize.width - cornerSpan)
        let inTopCorner = point.y >= (windowSize.height - cornerSpan)
        let inBottomCorner = point.y <= cornerSpan

        // 1. Strict corner priority across the full rounded-corner arc
        if inLeftCorner && inTopCorner { return .topLeft }
        if inRightCorner && inTopCorner { return .topRight }
        if inLeftCorner && inBottomCorner { return .bottomLeft }
        if inRightCorner && inBottomCorner { return .bottomRight }

        // 2. Single-edge perimeter bands
        if point.y >= (windowSize.height - edgeBand) { return .top }
        if point.y <= edgeBand { return .bottom }
        if point.x <= edgeBand { return .left }
        if point.x >= (windowSize.width - edgeBand) { return .right }

        return nil
    }

    /// Returns 8 pairwise-disjoint AppKit cursor rectangles (origin bottom-left) for `resetCursorRects()`,
    /// giving `cornerSpan × cornerSpan` corners strict non-overlapping priority over single-edge strips.
    public static func perimeterResizeCursorRects(
        for windowSize: CGSize,
        edgeBand: CGFloat = defaultResizeEdgeBand,
        cornerSpan: CGFloat = defaultResizeCornerSpan
    ) -> [(handle: PanelResizeHandle, rect: CGRect)] {
        let w = windowSize.width
        let h = windowSize.height
        guard w > cornerSpan * 2, h > cornerSpan * 2 else {
            return []
        }
        let c = cornerSpan
        let e = min(edgeBand, c)
        let horizSpan = max(0, w - c * 2)
        let vertSpan = max(0, h - c * 2)

        return [
            (.topLeft,     CGRect(x: 0,     y: h - c, width: c,         height: c)),
            (.topRight,    CGRect(x: w - c, y: h - c, width: c,         height: c)),
            (.bottomLeft,  CGRect(x: 0,     y: 0,     width: c,         height: c)),
            (.bottomRight, CGRect(x: w - c, y: 0,     width: c,         height: c)),
            (.top,         CGRect(x: c,     y: h - e, width: horizSpan, height: e)),
            (.bottom,      CGRect(x: c,     y: 0,     width: horizSpan, height: e)),
            (.left,        CGRect(x: 0,     y: c,     width: e,         height: vertSpan)),
            (.right,       CGRect(x: w - e, y: c,     width: e,         height: vertSpan))
        ]
    }

    /// Computes a live-resized window frame in AppKit screen coordinates (`(0, 0)` bottom-left),
    /// keeping the opposite edge/corner anchored while clamping strictly to `minWidth × minHeight` and `screenVisibleFrame`.
    public static func resizedFrame(
        initialFrame: CGRect,
        handle: PanelResizeHandle,
        initialMouseScreen: CGPoint,
        currentMouseScreen: CGPoint,
        screenVisibleFrame: CGRect,
        minWidth: CGFloat = minPanelWidth,
        minHeight: CGFloat = minPanelHeight
    ) -> CGRect {
        let dx = currentMouseScreen.x - initialMouseScreen.x
        let dy = currentMouseScreen.y - initialMouseScreen.y

        let effMinW = min(max(64, minWidth), screenVisibleFrame.width)
        let effMinH = min(max(64, minHeight), screenVisibleFrame.height)

        var minX = initialFrame.minX
        var maxX = initialFrame.maxX
        var minY = initialFrame.minY
        var maxY = initialFrame.maxY

        switch handle {
        case .left, .topLeft, .bottomLeft:
            let clampedMaxX = min(maxX, screenVisibleFrame.maxX)
            maxX = clampedMaxX
            minX = min(max(initialFrame.minX + dx, screenVisibleFrame.minX), maxX - effMinW)
        case .right, .topRight, .bottomRight:
            let clampedMinX = max(minX, screenVisibleFrame.minX)
            minX = clampedMinX
            maxX = max(min(initialFrame.maxX + dx, screenVisibleFrame.maxX), minX + effMinW)
        case .top, .bottom:
            break
        }

        switch handle {
        case .top, .topLeft, .topRight:
            let clampedMinY = max(minY, screenVisibleFrame.minY)
            minY = clampedMinY
            maxY = max(min(initialFrame.maxY + dy, screenVisibleFrame.maxY), minY + effMinH)
        case .bottom, .bottomLeft, .bottomRight:
            let clampedMaxY = min(maxY, screenVisibleFrame.maxY)
            maxY = clampedMaxY
            minY = min(max(initialFrame.minY + dy, screenVisibleFrame.minY), maxY - effMinH)
        case .left, .right:
            break
        }

        let rx = minX.rounded()
        let ry = minY.rounded()
        let rw = max(effMinW, (maxX - rx).rounded())
        let rh = max(effMinH, (maxY - ry).rounded())
        return CGRect(x: rx, y: ry, width: rw, height: rh)
    }

    /// Converts a resized panel frame back into clamped `(widthPercent, heightPercent)` relative to `screenVisibleFrame`.
    public static func sizePercents(
        forFrame frame: CGRect,
        in screenVisibleFrame: CGRect
    ) -> (widthPercent: Double, heightPercent: Double) {
        let rawW = Double(frame.width / max(1.0, screenVisibleFrame.width)) * 100.0
        let rawH = Double(frame.height / max(1.0, screenVisibleFrame.height)) * 100.0
        let wPct = (clamp(rawW, min: minPercent, max: maxPercent) * 10.0).rounded() / 10.0
        let hPct = (clamp(rawH, min: minPercent, max: maxPercent) * 10.0).rounded() / 10.0
        return (wPct, hPct)
    }

    private static func clamp(_ value: Double, min minVal: Double, max maxVal: Double) -> Double {
        Swift.min(Swift.max(value, minVal), maxVal)
    }
}

/// Single authoritative source of truth (in macOS points) for Veypane's sidebar rail,
/// top header bar, visual icon footprint vs. interactive hit-target bounds, and
/// chrome-only gesture boundaries (`t393`/`t396`/`t398`).
public struct PanelChromeMetrics: Equatable, Sendable {
    public static let headerBarHeight: CGFloat = 34.0
    public static let topResizeEdgeThickness: CGFloat = PanelGeometry.defaultResizeEdgeBand
    public static let sidebarDividerWidth: CGFloat = 1.0

    public static let defaultRegularSidebarWidth: CGFloat = 36.0
    public static let defaultRegularIconSize: CGFloat = 18.0
    public static let defaultCompactSidebarWidth: CGFloat = 32.0
    public static let defaultCompactIconSize: CGFloat = 16.0

    public static let minSidebarWidth: CGFloat = 28.0
    public static let maxSidebarWidth: CGFloat = 64.0
    public static let minPadIconSize: CGFloat = 12.0
    public static let maxPadIconSize: CGFloat = 36.0
    /// Minimum combined horizontal margin around visual icon (6 pt per side) so icons never touch the leading indicator or divider.
    public static let minIconHorizontalClearance: CGFloat = 12.0

    public let isCompact: Bool
    public let sidebarStripWidth: CGFloat
    public let padHitTargetWidth: CGFloat
    public let padHitTargetHeight: CGFloat
    public let padRowSpacing: CGFloat
    public let padVisualIconSize: CGFloat
    public let padIconCornerRadius: CGFloat
    public let padHighlightSize: CGFloat
    public let padHighlightCornerRadius: CGFloat
    public let selectionIndicatorWidth: CGFloat
    public let selectionIndicatorSelectedHeight: CGFloat
    public let selectionIndicatorHoveredHeight: CGFloat
    public let selectionIndicatorLeadingInset: CGFloat
    public let padListTopPadding: CGFloat
    public let padListBottomPadding: CGFloat
    public let addButtonVisualSize: CGFloat
    public let addButtonHitHeight: CGFloat
    public let addButtonGlyphSize: CGFloat
    public let bottomActionHitHeight: CGFloat
    public let bottomActionVisualSize: CGFloat
    public let bottomActionGlyphSize: CGFloat
    public let bottomPadding: CGFloat
    public let dividerHorizontalInset: CGFloat

    public var padRowPitch: CGFloat { padHitTargetHeight + padRowSpacing }
    public var totalSidebarRailWidth: CGFloat { sidebarStripWidth + Self.sidebarDividerWidth }
    public var padHitHorizontalInset: CGFloat { (sidebarStripWidth - padHitTargetWidth) / 2.0 }
    public var padVisualHorizontalInset: CGFloat { (sidebarStripWidth - padVisualIconSize) / 2.0 }

    public static func defaultSidebarWidth(compactSidebar: Bool) -> CGFloat {
        compactSidebar ? defaultCompactSidebarWidth : defaultRegularSidebarWidth
    }

    public static func defaultIconSize(compactSidebar: Bool) -> CGFloat {
        compactSidebar ? defaultCompactIconSize : defaultRegularIconSize
    }

    public static func clampedSidebarWidth(_ raw: Double?, compactSidebar: Bool) -> CGFloat {
        let fallback = defaultSidebarWidth(compactSidebar: compactSidebar)
        guard let raw, raw.isFinite else { return fallback }
        return min(max(CGFloat(raw.rounded()), minSidebarWidth), maxSidebarWidth)
    }

    public static func maxIconSize(forSidebarWidth width: CGFloat) -> CGFloat {
        let clampedW = min(max(width, minSidebarWidth), maxSidebarWidth)
        return min(maxPadIconSize, max(minPadIconSize, clampedW - minIconHorizontalClearance))
    }

    public static func clampedIconSize(_ raw: Double?, forSidebarWidth width: CGFloat, compactSidebar: Bool) -> CGFloat {
        let fallback = defaultIconSize(compactSidebar: compactSidebar)
        let upper = maxIconSize(forSidebarWidth: width)
        let candidate: CGFloat = if let raw, raw.isFinite { CGFloat(raw.rounded()) } else { fallback }
        return min(max(candidate, minPadIconSize), upper)
    }

    private static func roundToHalf(_ value: CGFloat) -> CGFloat {
        (value * 2.0).rounded() / 2.0
    }

    public static func forAppearance(compactSidebar: Bool) -> PanelChromeMetrics {
        forAppearance(AppearanceSettings(compactSidebar: compactSidebar))
    }

    public static func forAppearance(_ appearance: AppearanceSettings) -> PanelChromeMetrics {
        let compact = appearance.compactSidebar
        let width = clampedSidebarWidth(appearance.activeSidebarWidthOverride, compactSidebar: compact)
        let iconSize = clampedIconSize(appearance.activeSidebarIconSizeOverride, forSidebarWidth: width, compactSidebar: compact)

        // Preserve full 5 pt left-edge resize clearance at every supported sidebar width (28..64 pt)
        let hitW = width - (PanelGeometry.defaultResizeEdgeBand * 2.0)
        let desiredHighlight = iconSize + (compact ? 5.0 : 6.0)
        let highlightInset: CGFloat = (!compact && width >= 34.0) ? 2.0 : 1.0
        let maxHighlight = max(iconSize + 1.0, hitW - highlightInset)
        let highlightSize = max(iconSize + 1.0, min(desiredHighlight, maxHighlight))

        let hitH = max(compact ? 26.0 : 30.0, iconSize + (compact ? 10.0 : 12.0))
        let rowSpacing: CGFloat = compact ? 3.0 : 4.0

        let iconRadius = roundToHalf(iconSize * 0.25)
        let highlightRadius = min(11.0, roundToHalf(highlightSize * 0.27))

        let indicatorW: CGFloat = width >= 44.0 ? 2.5 : 2.0
        let indicatorSelH = min(hitH - 6.0, max(12.0, (iconSize * 0.83).rounded()))
        let indicatorHovH = max(6.0, (indicatorSelH * 0.53).rounded())
        let indicatorInset: CGFloat = width >= 44.0 ? 1.5 : 1.0

        let bottomVisualInset: CGFloat = (!compact && width >= 34.0) ? 4.0 : (width >= 32.0 ? 2.0 : 1.0)
        let maxBottomVisual = max(16.0, hitW - bottomVisualInset)
        let addVisual = min(32.0, min(maxBottomVisual, max(compact ? 18.0 : 20.0, iconSize + 4.0)))
        let addHitH = max(compact ? 24.0 : 28.0, addVisual + (compact ? 4.0 : 6.0))
        let bottomHitH = max(compact ? 24.0 : 26.0, addVisual + 4.0)
        let addGlyph = min(14.0, max(10.0, roundToHalf(iconSize * 0.64)))
        let bottomGlyph = min(15.0, max(10.5, roundToHalf(iconSize * 0.67)))
        let dividerInset = max(5.0, min(12.0, (width * 0.22).rounded()))

        return PanelChromeMetrics(
            isCompact: compact,
            sidebarStripWidth: width,
            padHitTargetWidth: hitW,
            padHitTargetHeight: hitH,
            padRowSpacing: rowSpacing,
            padVisualIconSize: iconSize,
            padIconCornerRadius: iconRadius,
            padHighlightSize: highlightSize,
            padHighlightCornerRadius: highlightRadius,
            selectionIndicatorWidth: indicatorW,
            selectionIndicatorSelectedHeight: indicatorSelH,
            selectionIndicatorHoveredHeight: indicatorHovH,
            selectionIndicatorLeadingInset: indicatorInset,
            padListTopPadding: PanelGeometry.defaultResizeCornerSpan,
            padListBottomPadding: 5.0,
            addButtonVisualSize: addVisual,
            addButtonHitHeight: addHitH,
            addButtonGlyphSize: addGlyph,
            bottomActionHitHeight: bottomHitH,
            bottomActionVisualSize: addVisual,
            bottomActionGlyphSize: bottomGlyph,
            bottomPadding: 8.0,
            dividerHorizontalInset: dividerInset
        )
    }

    /// Fallback center point in AppKit window coordinates (`(0, 0)` bottom-left) for pad `index`.
    public func fallbackPadCenterInWindow(index: Int, panelHeight: CGFloat) -> CGPoint {
        let topOffset = padListTopPadding + CGFloat(index) * padRowPitch + (padHitTargetHeight / 2.0)
        return CGPoint(x: sidebarStripWidth / 2.0, y: panelHeight - topOffset)
    }

    /// Fallback point in empty sidebar space below `padCount` rows (AppKit window coordinates).
    public func fallbackEmptyBelowLastPadInWindow(padCount: Int, panelHeight: CGFloat) -> CGPoint {
        let topOffset = padListTopPadding + CGFloat(padCount) * padRowPitch + 24.0
        return CGPoint(x: sidebarStripWidth / 2.0, y: panelHeight - topOffset)
    }
}
