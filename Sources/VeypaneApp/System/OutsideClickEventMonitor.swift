import AppKit
import CoreGraphics
import Foundation

public final class OutsideClickEventMonitor: @unchecked Sendable {
    private final class TapContextBox: @unchecked Sendable {
        weak var monitor: OutsideClickEventMonitor?
        init(monitor: OutsideClickEventMonitor) {
            self.monitor = monitor
        }
    }

    private var tapContextBox: TapContextBox?
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var lastTapEventUptimeNs: UInt64 = 0
    private var lastTapAppKitPoint: CGPoint = .zero

    public private(set) var isUsingCGEventTap: Bool = false
    public var backendDescription: String {
        if isUsingCGEventTap {
            return "cgEventTap+nsEventFallback"
        }
        if globalMonitor != nil || localMonitor != nil {
            return "nsEventOnly"
        }
        return "stopped"
    }

    public var onMouseDown: (@MainActor (_ targetWindow: NSWindow?, _ appKitScreenLocation: CGPoint, _ fromFallbackLocal: Bool) -> Void)?

    public init() {}

    deinit {
        stop()
    }

    @MainActor
    public func start() {
        stop()

        let box = TapContextBox(monitor: self)
        self.tapContextBox = box

        let mask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)

        let createdTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }
                let box = Unmanaged<TapContextBox>.fromOpaque(userInfo).takeUnretainedValue()
                guard let monitor = box.monitor else {
                    return Unmanaged.passUnretained(event)
                }

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let tap = monitor.eventTap {
                        CGEvent.tapEnable(tap: tap, enable: true)
                    }
                    return Unmanaged.passUnretained(event)
                }

                guard type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown else {
                    return Unmanaged.passUnretained(event)
                }

                let cgLocation = event.location
                if Thread.isMainThread {
                    MainActor.assumeIsolated {
                        monitor.handleTapMouseDown(cgLocation: cgLocation)
                    }
                } else {
                    Task { @MainActor [weak monitor] in
                        monitor?.handleTapMouseDown(cgLocation: cgLocation)
                    }
                }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(box).toOpaque()
        )

        if let createdTap,
           let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, createdTap, 0) {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: createdTap, enable: true)
            self.eventTap = createdTap
            self.runLoopSource = source
            self.isUsingCGEventTap = CGEvent.tapIsEnabled(tap: createdTap)
        } else {
            self.tapContextBox = nil
            self.isUsingCGEventTap = false
        }

        let mouseDownMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDownMask) { [weak self] _ in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.handleFallbackGlobalMouseDown(location: NSEvent.mouseLocation)
                }
            } else {
                Task { @MainActor [weak self] in
                    self?.handleFallbackGlobalMouseDown(location: NSEvent.mouseLocation)
                }
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDownMask) { [weak self] event in
            guard let self else { return event }
            self.handleFallbackLocalMouseDown(window: event.window, location: NSEvent.mouseLocation)
            return event
        }
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = nil
        }
        tapContextBox = nil
        isUsingCGEventTap = false

        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    @MainActor
    private func handleTapMouseDown(cgLocation: CGPoint) {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let appKitPoint = primaryHeight > 0
            ? CGPoint(x: cgLocation.x, y: primaryHeight - cgLocation.y)
            : NSEvent.mouseLocation

        lastTapEventUptimeNs = DispatchTime.now().uptimeNanoseconds
        lastTapAppKitPoint = appKitPoint

        let topWindowNumber = NSWindow.windowNumber(at: appKitPoint, belowWindowWithWindowNumber: 0)
        let ownWindow: NSWindow? = (topWindowNumber > 0) ? NSApp.window(withWindowNumber: topWindowNumber) : nil
        onMouseDown?(ownWindow, appKitPoint, false)
    }

    @MainActor
    private func isDuplicateOfRecentTapEvent(at location: CGPoint) -> Bool {
        guard lastTapEventUptimeNs > 0 else { return false }
        let nowNs = DispatchTime.now().uptimeNanoseconds
        guard nowNs >= lastTapEventUptimeNs, (nowNs - lastTapEventUptimeNs) < 120_000_000 else {
            return false
        }
        return hypot(location.x - lastTapAppKitPoint.x, location.y - lastTapAppKitPoint.y) < 12.0
    }

    @MainActor
    private func handleFallbackGlobalMouseDown(location: CGPoint) {
        guard !isDuplicateOfRecentTapEvent(at: location) else { return }
        onMouseDown?(nil, location, false)
    }

    @MainActor
    private func handleFallbackLocalMouseDown(window: NSWindow?, location: CGPoint) {
        guard !isDuplicateOfRecentTapEvent(at: location) else { return }
        onMouseDown?(window, location, true)
    }
}
