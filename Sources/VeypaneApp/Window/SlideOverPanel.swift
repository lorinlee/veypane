import AppKit
import VeypaneCore

public struct ActivePanelResizeSession: Equatable, Sendable {
    public var handle: PanelResizeHandle
    public var initialFrame: CGRect
    public var initialMouseScreen: CGPoint
    public var screenVisibleFrame: CGRect

    public init(
        handle: PanelResizeHandle,
        initialFrame: CGRect,
        initialMouseScreen: CGPoint,
        screenVisibleFrame: CGRect
    ) {
        self.handle = handle
        self.initialFrame = initialFrame
        self.initialMouseScreen = initialMouseScreen
        self.screenVisibleFrame = screenVisibleFrame
    }
}

@MainActor
private final class PanelResizeWindowDelegate: NSObject, NSWindowDelegate {
    weak var panel: SlideOverPanel?

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let vis = panel?.resolvedResizeScreenBounds() ?? sender.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 4096, height: 4096)
        let minW = min(PanelGeometry.minPanelWidth, vis.width)
        let minH = min(PanelGeometry.minPanelHeight, vis.height)
        return NSSize(
            width: min(max(frameSize.width, minW), vis.width),
            height: min(max(frameSize.height, minH), vis.height)
        )
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        guard let panel, panel.activeResizeSession == nil else { return }
        panel.onInteractiveResizeEnded?(panel.frame)
    }

    func windowDidResize(_ notification: Notification) {
        if let panel {
            panel.syncPerimeterCursorOverlayFrame()
            if panel.activeResizeSession == nil {
                panel.invalidateShadow()
            }
        }
    }
}

/// Lightweight topmost perimeter cursor/hit-test sibling mounted above `contentView` inside the window frame view.
/// Passes 100% of interior content points (`hitTest == nil`) through untouched while registering authoritative,
/// pairwise-disjoint `addCursorRect(_:cursor:)` rectangles for all 4 corners and 4 edges.
@MainActor
public final class PanelResizePerimeterCursorView: NSView {
    public private(set) var lastRegisteredCursorRects: [(handle: PanelResizeHandle, rect: CGRect, cursor: NSCursor)] = []
    private var trackingAreaRef: NSTrackingArea?

    public override var isOpaque: Bool { false }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingAreaRef {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
    }

    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, window != nil else { return nil }
        let localPt = convert(point, from: superview)
        guard PanelGeometry.hitTestResizeHandle(pointInWindow: localPt, windowSize: bounds.size) != nil else {
            return nil
        }
        return self
    }

    public override func resetCursorRects() {
        super.resetCursorRects()
        discardCursorRects()
        var applied: [(handle: PanelResizeHandle, rect: CGRect, cursor: NSCursor)] = []
        for entry in PanelGeometry.perimeterResizeCursorRects(for: bounds.size) {
            let cursor = SlideOverPanel.resizeCursor(for: entry.handle)
            addCursorRect(entry.rect, cursor: cursor)
            applied.append((entry.handle, entry.rect, cursor))
        }
        lastRegisteredCursorRects = applied
        if let panel = window as? SlideOverPanel {
            panel.reconcileResizeCursorIfNeeded()
        }
    }

    public override func cursorUpdate(with event: NSEvent) {
        guard let panel = window as? SlideOverPanel else {
            super.cursorUpdate(with: event)
            return
        }
        let winPt = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        if panel.evaluateResizeHover(atWindowPoint: winPt) == nil {
            super.cursorUpdate(with: event)
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        guard let panel = window as? SlideOverPanel else {
            super.mouseEntered(with: event)
            return
        }
        let winPt = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        if panel.evaluateResizeHover(atWindowPoint: winPt) == nil {
            super.mouseEntered(with: event)
        }
    }

    public override func mouseMoved(with event: NSEvent) {
        guard let panel = window as? SlideOverPanel else {
            super.mouseMoved(with: event)
            return
        }
        let winPt = (event.window === panel)
            ? event.locationInWindow
            : panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        if panel.evaluateResizeHover(atWindowPoint: winPt) == nil {
            super.mouseMoved(with: event)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        guard let panel = window as? SlideOverPanel else {
            super.mouseExited(with: event)
            return
        }
        let winPt = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        if panel.evaluateResizeHover(atWindowPoint: winPt) == nil {
            super.mouseExited(with: event)
        }
    }
}

@MainActor
public final class SlideOverPanel: NSPanel {
    public var onEscapePressed: (() -> Void)?
    public var onEscapeDuringDrag: (() -> Bool)?
    public var onGestureAction: ((PanelGestureAction) -> Void)?
    public var screenVisibleFrameForResizeProvider: (() -> CGRect)?
    public var onInteractiveResizeEnded: ((CGRect) -> Void)?
    public var gestureEngine = GestureRecognizerEngine()
    public var activeAnchor: AnchorPosition = .right
    public var gesturesEnabled: Bool = true
    public var animationsDisabled: Bool = false
    public var sidebarStripWidth: CGFloat = PanelChromeMetrics.forAppearance(compactSidebar: false).sidebarStripWidth
    public var headerBarHeight: CGFloat = PanelChromeMetrics.headerBarHeight
    public private(set) var activeAnimationFlight: PanelAnimationFlight?
    public private(set) var hoveredResizeHandle: PanelResizeHandle?
    public private(set) var activeResizeSession: ActivePanelResizeSession?
    public private(set) var lastAppliedResizeCursor: NSCursor?
    public private(set) var osBackedEventsReceivedCount: Int = 0
    public var reduceMotionOverride: Bool?
    public var simulatedKeyWindowOverride: Bool?

    private let resizeWindowDelegate = PanelResizeWindowDelegate()
    private var cursorReconcileObserver: CFRunLoopObserver?
    private var cursorEventMonitor: Any?
    private var isResettingCursorRects = false
    public private(set) var perimeterCursorOverlayView: PanelResizePerimeterCursorView?

    public var isInInteractiveResize: Bool {
        activeResizeSession != nil || inLiveResize
    }

    public init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .resizable],
            backing: .buffered,
            defer: false
        )

        self.isFloatingPanel = true
        self.level = .floating
        self.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary
        ]
        self.hidesOnDeactivate = false
        self.isOpaque = false
        // Fully clear window backing + borderless mask ensures zero standalone top titlebar band,
        // zero extra top ledge, and a single continuous rounded shadow contour around PanelRootView.
        self.backgroundColor = .clear
        self.hasShadow = true
        self.isMovable = false
        self.isMovableByWindowBackground = false
        self.acceptsMouseMovedEvents = true
        self.animationBehavior = .none
        self.minSize = NSSize(width: PanelGeometry.minPanelWidth, height: PanelGeometry.minPanelHeight)
        self.title = AppBrandIdentity.productName
        self.isReleasedWhenClosed = false

        resizeWindowDelegate.panel = self
        self.delegate = resizeWindowDelegate
        installActiveAlwaysResizeTrackingAreas()

        setAccessibilityRole(.window)
        setAccessibilitySubrole(.floatingWindow)
        setAccessibilityTitle(AppBrandIdentity.productName)
    }

    public override var contentView: NSView? {
        didSet {
            installActiveAlwaysResizeTrackingAreas()
        }
    }

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }
    public override var isKeyWindow: Bool { simulatedKeyWindowOverride ?? super.isKeyWindow }

    private func installActiveAlwaysResizeTrackingAreas() {
        if let cv = contentView, let frameView = cv.superview {
            let overlay: PanelResizePerimeterCursorView
            if let existing = perimeterCursorOverlayView {
                overlay = existing
            } else {
                overlay = PanelResizePerimeterCursorView(frame: frameView.bounds)
                overlay.autoresizingMask = [.width, .height]
                perimeterCursorOverlayView = overlay
            }
            overlay.frame = frameView.bounds
            if overlay.superview !== frameView || frameView.subviews.last !== overlay {
                overlay.removeFromSuperview()
                frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
            }
            invalidateCursorRects(for: overlay)
        }
    }

    public func syncPerimeterCursorOverlayFrame() {
        guard let overlay = perimeterCursorOverlayView, let frameView = overlay.superview else { return }
        if overlay.frame != frameView.bounds {
            overlay.frame = frameView.bounds
        }
        if frameView.subviews.last !== overlay {
            frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
        }
        invalidateCursorRects(for: overlay)
        if activeResizeSession == nil && !isResettingCursorRects {
            resetCursorRects()
        }
    }

    public override func resetCursorRects() {
        guard !isResettingCursorRects else { return }
        isResettingCursorRects = true
        super.resetCursorRects()
        isResettingCursorRects = false
        reconcileResizeCursorIfNeeded()
    }

    public func registeredResizeCursorRects() -> [(handle: PanelResizeHandle, rect: CGRect, cursor: NSCursor)] {
        if let overlay = perimeterCursorOverlayView {
            overlay.resetCursorRects()
            return overlay.lastRegisteredCursorRects
        }
        return PanelGeometry.perimeterResizeCursorRects(for: frame.size).map {
            ($0.handle, $0.rect, Self.resizeCursor(for: $0.handle))
        }
    }

    public override func cursorUpdate(with event: NSEvent) {
        let winPt = convertPoint(fromScreen: NSEvent.mouseLocation)
        if evaluateResizeHover(atWindowPoint: winPt) == nil {
            super.cursorUpdate(with: event)
        }
    }

    public override func mouseEntered(with event: NSEvent) {
        let winPt = convertPoint(fromScreen: NSEvent.mouseLocation)
        if evaluateResizeHover(atWindowPoint: winPt) == nil {
            super.mouseEntered(with: event)
        }
    }

    public override func mouseExited(with event: NSEvent) {
        let winPt = convertPoint(fromScreen: NSEvent.mouseLocation)
        if evaluateResizeHover(atWindowPoint: winPt) == nil {
            super.mouseExited(with: event)
        }
    }

    public func resolvedResizeScreenBounds() -> CGRect {
        if let provided = screenVisibleFrameForResizeProvider?(), provided.width > 64, provided.height > 64 {
            return provided
        }
        return screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? NSScreen.screens.first?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    /// Returns the official public AppKit resize cursor for `handle` (never calling private selectors).
    public static func resizeCursor(for handle: PanelResizeHandle) -> NSCursor {
        if #available(macOS 15.0, *) {
            let pos: NSCursor.FrameResizePosition = switch handle {
            case .top: .top
            case .bottom: .bottom
            case .left: .left
            case .right: .right
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return NSCursor.frameResize(position: pos, directions: .all)
        }
        switch handle {
        case .top, .bottom:
            return fallbackAxisCursor(vertical: true)
        case .left, .right:
            return fallbackAxisCursor(vertical: false)
        case .topLeft, .bottomRight:
            return fallbackDiagonalCursor(northWestSouthEast: true)
        case .topRight, .bottomLeft:
            return fallbackDiagonalCursor(northWestSouthEast: false)
        }
    }

    private static func fallbackAxisCursor(vertical: Bool) -> NSCursor {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.6
            if vertical {
                path.move(to: NSPoint(x: 9, y: 3))
                path.line(to: NSPoint(x: 9, y: 15))
            } else {
                path.move(to: NSPoint(x: 3, y: 9))
                path.line(to: NSPoint(x: 15, y: 9))
            }
            path.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 9, y: 9))
    }

    private static func fallbackDiagonalCursor(northWestSouthEast: Bool) -> NSCursor {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath()
            path.lineWidth = 1.6
            if northWestSouthEast {
                path.move(to: NSPoint(x: 4, y: 14))
                path.line(to: NSPoint(x: 14, y: 4))
            } else {
                path.move(to: NSPoint(x: 4, y: 4))
                path.line(to: NSPoint(x: 14, y: 14))
            }
            path.stroke()
            return true
        }
        return NSCursor(image: img, hotSpot: NSPoint(x: 9, y: 9))
    }

    public override func update() {
        super.update()
        reconcileResizeCursorIfNeeded()
    }

    private func updateCursorReconcileObserverState() {
        let shouldObserve = isVisible && activeAnimationFlight == nil && attachedSheet == nil
            && (activeResizeSession != nil || hoveredResizeHandle != nil)
        if shouldObserve {
            if cursorReconcileObserver == nil {
                let activities: CFRunLoopActivity = [
                    .beforeTimers,
                    .beforeSources,
                    .beforeWaiting,
                    .afterWaiting
                ]
                let observer = CFRunLoopObserverCreateWithHandler(
                    kCFAllocatorDefault,
                    activities.rawValue,
                    true,
                    0
                ) { [weak self] _, _ in
                    MainActor.assumeIsolated {
                        self?.reconcileResizeCursorIfNeeded()
                    }
                }
                if let observer {
                    CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                    cursorReconcileObserver = observer
                }
            }
            if cursorEventMonitor == nil {
                cursorEventMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.mouseEntered, .mouseExited, .cursorUpdate]
                ) { [weak self] event in
                    let shouldIntercept = MainActor.assumeIsolated {
                        self?.shouldInterceptProcessLocalCursorEvent() ?? false
                    }
                    return shouldIntercept ? nil : event
                }
            }
        } else {
            if let observer = cursorReconcileObserver {
                CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
                CFRunLoopObserverInvalidate(observer)
                cursorReconcileObserver = nil
            }
            if let monitor = cursorEventMonitor {
                NSEvent.removeMonitor(monitor)
                cursorEventMonitor = nil
            }
        }
    }

    private func shouldInterceptProcessLocalCursorEvent() -> Bool {
        guard isVisible, activeAnimationFlight == nil, attachedSheet == nil else {
            updateCursorReconcileObserverState()
            return false
        }
        if let session = activeResizeSession {
            let cursor = Self.resizeCursor(for: session.handle)
            hoveredResizeHandle = session.handle
            lastAppliedResizeCursor = cursor
            if NSCursor.current != cursor {
                cursor.set()
            }
            return true
        }
        guard hoveredResizeHandle != nil else {
            updateCursorReconcileObserverState()
            return false
        }
        let screenPt = NSEvent.mouseLocation
        let topWinNum = NSWindow.windowNumber(at: screenPt, belowWindowWithWindowNumber: 0)
        guard topWinNum == windowNumber else {
            hoveredResizeHandle = nil
            lastAppliedResizeCursor = nil
            updateCursorReconcileObserverState()
            return false
        }
        let liveWinPt = convertPoint(fromScreen: screenPt)
        if let handle = PanelGeometry.hitTestResizeHandle(pointInWindow: liveWinPt, windowSize: frame.size) {
            hoveredResizeHandle = handle
            let cursor = Self.resizeCursor(for: handle)
            lastAppliedResizeCursor = cursor
            if NSCursor.current != cursor {
                cursor.set()
            }
            return true
        }
        hoveredResizeHandle = nil
        lastAppliedResizeCursor = nil
        NSCursor.arrow.set()
        updateCursorReconcileObserverState()
        return false
    }

    /// Re-asserts the public resize cursor whenever an async AppKit/WebKit cursor pass (such as
    /// deferred `resetCursorRects()`, cross-window cursor updates, or out-of-process `WKWebView`
    /// cursor updates) overwrites `NSCursor.current` while the live pointer is still over this
    /// panel's resize perimeter.
    public func reconcileResizeCursorIfNeeded() {
        guard isVisible, activeAnimationFlight == nil, attachedSheet == nil else {
            updateCursorReconcileObserverState()
            return
        }
        if let session = activeResizeSession {
            let cursor = Self.resizeCursor(for: session.handle)
            hoveredResizeHandle = session.handle
            lastAppliedResizeCursor = cursor
            if NSCursor.current != cursor {
                cursor.set()
            }
            return
        }
        guard hoveredResizeHandle != nil else {
            updateCursorReconcileObserverState()
            return
        }
        let screenPt = NSEvent.mouseLocation
        let topWinNum = NSWindow.windowNumber(at: screenPt, belowWindowWithWindowNumber: 0)
        guard topWinNum == windowNumber else {
            hoveredResizeHandle = nil
            lastAppliedResizeCursor = nil
            updateCursorReconcileObserverState()
            return
        }
        let liveWinPt = convertPoint(fromScreen: screenPt)
        if let handle = PanelGeometry.hitTestResizeHandle(pointInWindow: liveWinPt, windowSize: frame.size) {
            hoveredResizeHandle = handle
            let cursor = Self.resizeCursor(for: handle)
            lastAppliedResizeCursor = cursor
            if NSCursor.current != cursor {
                cursor.set()
            }
        } else {
            hoveredResizeHandle = nil
            lastAppliedResizeCursor = nil
            NSCursor.arrow.set()
            updateCursorReconcileObserverState()
        }
    }

    @discardableResult
    public func evaluateResizeHover(atWindowPoint pointInWindow: CGPoint) -> PanelResizeHandle? {
        if let session = activeResizeSession {
            hoveredResizeHandle = session.handle
            let cursor = Self.resizeCursor(for: session.handle)
            lastAppliedResizeCursor = cursor
            cursor.set()
            updateCursorReconcileObserverState()
            return session.handle
        }
        let hit = PanelGeometry.hitTestResizeHandle(pointInWindow: pointInWindow, windowSize: frame.size)
        let previouslyHovering = (hoveredResizeHandle != nil)
        hoveredResizeHandle = hit
        if let hit {
            let cursor = Self.resizeCursor(for: hit)
            lastAppliedResizeCursor = cursor
            cursor.set()
        } else if previouslyHovering {
            lastAppliedResizeCursor = nil
            NSCursor.arrow.set()
        }
        updateCursorReconcileObserverState()
        return hit
    }

    @discardableResult
    public func beginInteractiveResize(
        atScreenPoint screenPoint: CGPoint,
        windowPointOverride: CGPoint? = nil
    ) -> PanelResizeHandle? {
        let winPt = windowPointOverride ?? convertPoint(fromScreen: screenPoint)
        guard let handle = PanelGeometry.hitTestResizeHandle(pointInWindow: winPt, windowSize: frame.size) else {
            return nil
        }
        let visBounds = resolvedResizeScreenBounds()
        activeResizeSession = ActivePanelResizeSession(
            handle: handle,
            initialFrame: frame,
            initialMouseScreen: screenPoint,
            screenVisibleFrame: visBounds
        )
        hoveredResizeHandle = handle
        let cursor = Self.resizeCursor(for: handle)
        lastAppliedResizeCursor = cursor
        cursor.set()
        updateCursorReconcileObserverState()
        return handle
    }

    private func applyResizedFramePreservingAnchor(_ targetFrame: CGRect, handle: PanelResizeHandle) -> CGRect {
        setFrame(targetFrame, display: true)
        var actual = frame
        var adjusted = actual
        if (handle == .left || handle == .topLeft || handle == .bottomLeft) && abs(actual.maxX - targetFrame.maxX) > 0.5 {
            adjusted.origin.x = (targetFrame.maxX - actual.width).rounded()
        }
        if (handle == .bottom || handle == .bottomLeft || handle == .bottomRight) && abs(actual.maxY - targetFrame.maxY) > 0.5 {
            adjusted.origin.y = (targetFrame.maxY - actual.height).rounded()
        }
        if adjusted != actual {
            setFrame(adjusted, display: true)
            actual = frame
        }
        return actual
    }

    @discardableResult
    public func updateInteractiveResize(toScreenPoint currentScreenPoint: CGPoint) -> CGRect? {
        guard let session = activeResizeSession else { return nil }
        let nextFrame = PanelGeometry.resizedFrame(
            initialFrame: session.initialFrame,
            handle: session.handle,
            initialMouseScreen: session.initialMouseScreen,
            currentMouseScreen: currentScreenPoint,
            screenVisibleFrame: session.screenVisibleFrame
        )
        let applied = applyResizedFramePreservingAnchor(nextFrame, handle: session.handle)
        let cursor = Self.resizeCursor(for: session.handle)
        lastAppliedResizeCursor = cursor
        cursor.set()
        return applied
    }

    @discardableResult
    public func endInteractiveResize(atScreenPoint releaseScreenPoint: CGPoint) -> CGRect? {
        guard let session = activeResizeSession else { return nil }
        let finalFrame = PanelGeometry.resizedFrame(
            initialFrame: session.initialFrame,
            handle: session.handle,
            initialMouseScreen: session.initialMouseScreen,
            currentMouseScreen: releaseScreenPoint,
            screenVisibleFrame: session.screenVisibleFrame
        )
        let applied = applyResizedFramePreservingAnchor(finalFrame, handle: session.handle)
        activeResizeSession = nil
        syncPerimeterCursorOverlayFrame()
        invalidateShadow()
        _ = evaluateResizeHover(atWindowPoint: convertPoint(fromScreen: releaseScreenPoint))
        onInteractiveResizeEnded?(applied)
        return applied
    }

    public func cancelInteractiveResizeIfNeeded() {
        let hadResizeState = (activeResizeSession != nil || hoveredResizeHandle != nil)
        activeResizeSession = nil
        hoveredResizeHandle = nil
        lastAppliedResizeCursor = nil
        updateCursorReconcileObserverState()
        if hadResizeState {
            NSCursor.arrow.set()
        }
    }

    public override func orderOut(_ sender: Any?) {
        cancelInteractiveResizeIfNeeded()
        super.orderOut(sender)
    }

    public override func close() {
        cancelInteractiveResizeIfNeeded()
        super.close()
    }

    public override func sendEvent(_ event: NSEvent) {
        if event.cgEvent != nil {
            osBackedEventsReceivedCount &+= 1
        }
        if event.type == .keyDown && event.keyCode == 53, onEscapeDuringDrag?() == true {
            return
        }
        if event.type == .leftMouseUp && activeResizeSession != nil && (!isVisible || activeAnimationFlight != nil || attachedSheet != nil) {
            cancelInteractiveResizeIfNeeded()
            super.sendEvent(event)
            return
        }
        if isVisible && activeAnimationFlight == nil && attachedSheet == nil {
            switch event.type {
            case .leftMouseDragged:
                if activeResizeSession != nil {
                    let screenPt = (event.window === self)
                        ? convertPoint(toScreen: event.locationInWindow)
                        : NSEvent.mouseLocation
                    _ = updateInteractiveResize(toScreenPoint: screenPt)
                    return
                }

            case .leftMouseUp:
                if activeResizeSession != nil {
                    let screenPt = (event.window === self)
                        ? convertPoint(toScreen: event.locationInWindow)
                        : NSEvent.mouseLocation
                    _ = endInteractiveResize(atScreenPoint: screenPt)
                    return
                }

            case .leftMouseDown:
                let winPt = (event.window === self)
                    ? event.locationInWindow
                    : convertPoint(fromScreen: NSEvent.mouseLocation)
                if PanelGeometry.hitTestResizeHandle(pointInWindow: winPt, windowSize: frame.size) != nil {
                    let screenPt = (event.window === self)
                        ? convertPoint(toScreen: winPt)
                        : NSEvent.mouseLocation
                    _ = beginInteractiveResize(atScreenPoint: screenPt, windowPointOverride: winPt)
                    return
                }

            case .mouseMoved:
                if let session = activeResizeSession {
                    let cursor = Self.resizeCursor(for: session.handle)
                    hoveredResizeHandle = session.handle
                    lastAppliedResizeCursor = cursor
                    cursor.set()
                    return
                }
                let winPt = (event.window === self)
                    ? event.locationInWindow
                    : convertPoint(fromScreen: NSEvent.mouseLocation)
                if PanelGeometry.hitTestResizeHandle(pointInWindow: winPt, windowSize: frame.size) != nil {
                    _ = evaluateResizeHover(atWindowPoint: winPt)
                    return
                } else {
                    _ = evaluateResizeHover(atWindowPoint: winPt)
                }

            case .cursorUpdate, .mouseEntered, .mouseExited:
                if let session = activeResizeSession {
                    let cursor = Self.resizeCursor(for: session.handle)
                    hoveredResizeHandle = session.handle
                    lastAppliedResizeCursor = cursor
                    cursor.set()
                    return
                }
                let liveWinPt = convertPoint(fromScreen: NSEvent.mouseLocation)
                if evaluateResizeHover(atWindowPoint: liveWinPt) != nil {
                    return
                }

            default:
                break
            }
        }
        super.sendEvent(event)
        if isVisible && activeAnimationFlight == nil && attachedSheet == nil {
            if let session = activeResizeSession {
                let cursor = Self.resizeCursor(for: session.handle)
                lastAppliedResizeCursor = cursor
                cursor.set()
            } else if hoveredResizeHandle != nil {
                let liveWinPt = convertPoint(fromScreen: NSEvent.mouseLocation)
                if let handle = PanelGeometry.hitTestResizeHandle(pointInWindow: liveWinPt, windowSize: frame.size) {
                    let cursor = Self.resizeCursor(for: handle)
                    hoveredResizeHandle = handle
                    lastAppliedResizeCursor = cursor
                    cursor.set()
                }
            }
        }
    }

    public override func cancelOperation(_ sender: Any?) {
        onEscapePressed?()
    }

    private static func isUndoSelector(_ selector: Selector?) -> Bool {
        guard let selector else { return false }
        let name = NSStringFromSelector(selector)
        return name == "undo:" || name == "undo"
    }

    private static func isRedoSelector(_ selector: Selector?) -> Bool {
        guard let selector else { return false }
        let name = NSStringFromSelector(selector)
        return name == "redo:" || name == "redo"
    }

    @objc public func undo(_ sender: Any?) {
        (firstResponder?.undoManager ?? undoManager)?.undo()
    }

    @objc public func redo(_ sender: Any?) {
        (firstResponder?.undoManager ?? undoManager)?.redo()
    }

    public override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if Self.isUndoSelector(menuItem.action) {
            return (firstResponder?.undoManager ?? undoManager)?.canUndo == true
        }
        if Self.isRedoSelector(menuItem.action) {
            return (firstResponder?.undoManager ?? undoManager)?.canRedo == true
        }
        return super.validateMenuItem(menuItem)
    }

    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if Self.isUndoSelector(item.action) {
            return (firstResponder?.undoManager ?? undoManager)?.canUndo == true
        }
        if Self.isRedoSelector(item.action) {
            return (firstResponder?.undoManager ?? undoManager)?.canRedo == true
        }
        return super.validateUserInterfaceItem(item)
    }

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) {
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let mods = EdgeMonitorController.activeModifiers(from: flags)
        guard let editCommand = StandardEditCommand.match(
            modifiers: mods,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            keyCode: event.keyCode
        ) else {
            return false
        }

        // Standard AppKit path when NSApp recognizes this window as keyWindow:
        if NSApp.keyWindow === self,
           let mainMenu = NSApp.mainMenu,
           mainMenu.performKeyEquivalent(with: event) {
            return true
        }

        // Non-activating LSUIElement fallback: when `.nonactivatingPanel` receives key events while
        // `NSApp.isActive == false` (so `NSApp.keyWindow` may be nil), walk this panel's real `firstResponder`
        // chain using standard nil-target selector validation — never hard-routing to WKWebView.
        return dispatchStandardEditCommandToResponderChain(editCommand)
    }

    public func canDispatchSelectorInResponderChain(_ selector: Selector, menuItem: NSMenuItem) -> Bool {
        if Self.isUndoSelector(selector) {
            return (firstResponder?.undoManager ?? undoManager)?.canUndo == true
                || responderInChain(for: selector, menuItem: menuItem, skipSelf: true) != nil
        }
        if Self.isRedoSelector(selector) {
            return (firstResponder?.undoManager ?? undoManager)?.canRedo == true
                || responderInChain(for: selector, menuItem: menuItem, skipSelf: true) != nil
        }
        return responderInChain(for: selector, menuItem: menuItem, skipSelf: false) != nil
    }

    private func responderInChain(for selector: Selector, menuItem: NSMenuItem, skipSelf: Bool) -> NSResponder? {
        var candidate: NSResponder? = self.firstResponder
        while let responder = candidate {
            if skipSelf && responder === self {
                candidate = responder.nextResponder
                continue
            }
            if responder.responds(to: selector) {
                if let validator = responder as? any NSMenuItemValidation {
                    if !validator.validateMenuItem(menuItem) {
                        candidate = responder.nextResponder
                        continue
                    }
                } else if let validator = responder as? any NSUserInterfaceValidations {
                    if !validator.validateUserInterfaceItem(menuItem) {
                        candidate = responder.nextResponder
                        continue
                    }
                }
                return responder
            }
            candidate = responder.nextResponder
        }
        return nil
    }

    public func dispatchStandardEditCommandToResponderChain(_ command: StandardEditCommand) -> Bool {
        let selector = Selector((command.selectorName))
        let senderItem = MainMenuBuilder.editMenuItem(for: command, in: NSApp.mainMenu)
            ?? NSMenuItem(title: command.rawValue.capitalized, action: selector, keyEquivalent: command.keyEquivalent)
        senderItem.target = nil

        if let responder = responderInChain(for: selector, menuItem: senderItem, skipSelf: false) {
            return NSApp.sendAction(selector, to: responder, from: senderItem)
        }
        return false
    }

    public override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onEscapePressed?()
            return
        }
        super.keyDown(with: event)
    }

    public func shouldHandleChromeGesture(atWindowPoint locationInWindow: CGPoint) -> Bool {
        let chrome = isPointInPanelGestureChrome(locationInWindow)
        return chrome.inTopToolbar || chrome.inLeftStrip
    }

    private func isPointInPanelGestureChrome(_ locationInWindow: CGPoint) -> (inTopToolbar: Bool, inLeftStrip: Bool) {
        let inTopToolbar = locationInWindow.y >= (frame.height - headerBarHeight)
        let inLeftStrip = locationInWindow.x <= sidebarStripWidth
        return (inTopToolbar, inLeftStrip)
    }

    public override func swipe(with event: NSEvent) {
        guard gesturesEnabled else {
            super.swipe(with: event)
            return
        }
        let chrome = isPointInPanelGestureChrome(event.locationInWindow)
        // Never hijack horizontal swipes over the webpage viewport — let WKWebView perform native back/forward navigation.
        guard chrome.inTopToolbar || chrome.inLeftStrip else {
            super.swipe(with: event)
            return
        }
        let action = GestureRecognizerEngine.handleDiscreteSwipe(
            appKitDeltaX: event.deltaX,
            anchor: activeAnchor
        )
        if action != .none {
            onGestureAction?(action)
        } else {
            super.swipe(with: event)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        guard gesturesEnabled else {
            super.scrollWheel(with: event)
            return
        }
        let chrome = isPointInPanelGestureChrome(event.locationInWindow)

        if chrome.inTopToolbar || chrome.inLeftStrip {
            let phase: SwipeGesturePhase? = switch event.phase {
            case .began: .began
            case .changed: .changed
            case .ended: .ended
            case .cancelled: .cancelled
            default: nil
            }
            if let phase {
                let action = gestureEngine.handleScroll(
                    deltaX: event.scrollingDeltaX,
                    deltaY: event.scrollingDeltaY,
                    phase: phase,
                    anchor: activeAnchor,
                    onChromeArea: chrome.inTopToolbar
                )
                if action != .none {
                    onGestureAction?(action)
                    return
                }
            }
        }
        super.scrollWheel(with: event)
    }

    public func applyAppearance(_ appearanceSettings: AppearanceSettings, isAlwaysOnTop: Bool) {
        self.hasShadow = appearanceSettings.hasShadow
        self.level = isAlwaysOnTop ? .statusBar : .floating
        self.sidebarStripWidth = PanelChromeMetrics.forAppearance(appearanceSettings).sidebarStripWidth
        self.headerBarHeight = PanelChromeMetrics.headerBarHeight
        switch appearanceSettings.theme {
        case .system:
            self.appearance = nil
        case .light:
            self.appearance = NSAppearance(named: .aqua)
        case .dark:
            self.appearance = NSAppearance(named: .darkAqua)
        }
        if let cv = self.contentView {
            cv.wantsLayer = true
            cv.layer?.cornerRadius = CGFloat(appearanceSettings.cornerRadius)
            cv.layer?.cornerCurve = .continuous
            cv.layer?.masksToBounds = true
        }
        self.invalidateShadow()
    }

    private var effectiveReduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    public func currentPresentationSample(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PanelPresentationSample {
        if let flight = activeAnimationFlight {
            return flight.presentationState(at: timestamp)
        }
        return PanelPresentationSample(
            frame: frame,
            alpha: alphaValue,
            timeFraction: 1.0,
            easedProgress: 1.0
        )
    }

    public func slideIn(
        from hiddenFrame: NSRect,
        to visibleFrame: NSRect,
        generation: UInt64,
        reversedInFlight: Bool = false,
        duration: TimeInterval = AppSettings.defaultAnimationDuration,
        activateKeyFocus: Bool = true,
        onCompleted: (@MainActor (UInt64) -> Void)? = nil
    ) {
        cancelInteractiveResizeIfNeeded()
        if animationsDisabled || duration <= 0.001 {
            activeAnimationFlight = nil
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                self.setFrame(visibleFrame, display: true)
                self.alphaValue = 1.0
            }
            orderFrontRegardless()
            if activateKeyFocus {
                makeKey()
            }
            syncPerimeterCursorOverlayFrame()
            invalidateShadow()
            onCompleted?(generation)
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let reduceMotion = effectiveReduceMotion
        let flight = PanelAnimationPlanner.planShow(
            hiddenFrame: hiddenFrame,
            visibleFrame: visibleFrame,
            anchor: activeAnchor,
            generation: generation,
            now: now,
            baseDuration: duration,
            reduceMotion: reduceMotion,
            reversedInFlight: reversedInFlight,
            inFlight: activeAnimationFlight,
            liveWindowFrame: frame,
            liveWindowAlpha: alphaValue,
            isWindowCurrentlyVisible: isVisible
        )
        activeAnimationFlight = flight

        // Synchronously anchor the starting presentation frame/alpha before ordering front or reversing,
        // halting any superseded NSWindow move animation right at `flight.fromFrame` without jumping.
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0
            ctx.allowsImplicitAnimation = false
            self.setFrame(flight.fromFrame, display: self.isVisible && reversedInFlight)
            self.alphaValue = flight.fromAlpha
        }

        orderFrontRegardless()
        if activateKeyFocus {
            makeKey()
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = flight.duration
            switch flight.curve {
            case .showEaseOut:
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            case .hideEaseInOut:
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            case .reduceMotionFade:
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            }
            ctx.allowsImplicitAnimation = false
            if !flight.reduceMotion {
                self.animator().setFrame(flight.toFrame, display: true)
            }
            self.animator().alphaValue = flight.toAlpha
        } completionHandler: {
            Task { @MainActor [weak self] in
                if self?.activeAnimationFlight?.generation == generation {
                    self?.activeAnimationFlight = nil
                }
                self?.syncPerimeterCursorOverlayFrame()
                onCompleted?(generation)
            }
        }
    }

    public func resizeSmoothly(to newVisibleFrame: NSRect, duration: TimeInterval = 0.16) {
        if abs(frame.origin.x - newVisibleFrame.origin.x) < 0.5 &&
            abs(frame.origin.y - newVisibleFrame.origin.y) < 0.5 &&
            abs(frame.size.width - newVisibleFrame.size.width) < 0.5 &&
            abs(frame.size.height - newVisibleFrame.size.height) < 0.5 {
            return
        }
        guard isVisible else {
            setFrame(newVisibleFrame, display: false)
            return
        }
        if animationsDisabled || effectiveReduceMotion || duration <= 0.001 {
            setFrame(newVisibleFrame, display: true)
            invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = max(0.06, duration)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ctx.allowsImplicitAnimation = false
            self.animator().setFrame(newVisibleFrame, display: true)
        }
    }

    public func slideOut(
        from visibleFrame: NSRect? = nil,
        to hiddenFrame: NSRect,
        generation: UInt64,
        reversedInFlight: Bool = false,
        duration: TimeInterval = AppSettings.defaultAnimationDuration,
        shouldFinalizeHide: @escaping @MainActor (UInt64) -> Bool,
        completion: (@MainActor () -> Void)? = nil
    ) {
        cancelInteractiveResizeIfNeeded()
        guard isVisible else {
            activeAnimationFlight = nil
            _ = shouldFinalizeHide(generation)
            completion?()
            return
        }
        if animationsDisabled || duration <= 0.001 {
            activeAnimationFlight = nil
            guard shouldFinalizeHide(generation) else { return }
            self.alphaValue = 0.0
            self.orderOut(nil)
            completion?()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let reduceMotion = effectiveReduceMotion
        let nominalVisible = visibleFrame ?? frame
        let flight = PanelAnimationPlanner.planHide(
            visibleFrame: nominalVisible,
            hiddenFrame: hiddenFrame,
            anchor: activeAnchor,
            generation: generation,
            now: now,
            baseDuration: duration,
            reduceMotion: reduceMotion,
            reversedInFlight: reversedInFlight,
            inFlight: activeAnimationFlight,
            liveWindowFrame: frame,
            liveWindowAlpha: alphaValue
        )
        activeAnimationFlight = flight

        // When reversing an in-flight show, snap immediately to the interpolated presentation position
        // so AppKit never jumps to the interrupted show's target `visibleFrame` before sliding out.
        if reversedInFlight || reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                ctx.allowsImplicitAnimation = false
                self.setFrame(flight.fromFrame, display: true)
                self.alphaValue = flight.fromAlpha
            }
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = flight.duration
            switch flight.curve {
            case .hideEaseInOut:
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            case .reduceMotionFade:
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            case .showEaseOut:
                ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
            }
            ctx.allowsImplicitAnimation = false
            if !flight.reduceMotion {
                self.animator().setFrame(flight.toFrame, display: true)
            }
            self.animator().alphaValue = flight.toAlpha
        } completionHandler: {
            Task { @MainActor [weak self] in
                // Generation guard: if a newer `showPanel()` superseded this hide animation,
                // never orderOut, never reset alpha, and never clear the newer flight!
                guard shouldFinalizeHide(generation) else { return }
                if self?.activeAnimationFlight?.generation == generation {
                    self?.activeAnimationFlight = nil
                }
                // Keep alphaValue at 0.0 while ordering out so there is zero final-frame flash.
                self?.alphaValue = 0.0
                self?.orderOut(nil)
                completion?()
            }
        }
    }
}
