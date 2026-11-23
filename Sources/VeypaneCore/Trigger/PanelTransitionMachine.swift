import Foundation
import CoreGraphics

public enum PanelTransitionPhase: String, Codable, Equatable, Sendable {
    case hidden
    case showing
    case visible
    case hiding
}

public struct PanelTransitionStep: Equatable, Sendable {
    public var generation: UInt64
    public var shouldPerformTransition: Bool
    public var reversedInFlight: Bool

    public init(generation: UInt64, shouldPerformTransition: Bool, reversedInFlight: Bool) {
        self.generation = generation
        self.shouldPerformTransition = shouldPerformTransition
        self.reversedInFlight = reversedInFlight
    }
}

/// Coherent generation-guarded panel transition state machine (Round 5 Outcome 1).
/// Prevents stale `slideOut` completion handlers from ordering out or ghosting a panel
/// when rapid show/hide toggles reverse an in-flight animation.
public struct PanelTransitionController: Equatable, Sendable {
    public private(set) var phase: PanelTransitionPhase = .hidden
    public private(set) var generation: UInt64 = 0
    public private(set) var showCount: Int = 0
    public private(set) var hideCount: Int = 0
    public private(set) var interruptedTransitions: Int = 0

    public init() {}

    public var isTargetVisible: Bool {
        phase == .showing || phase == .visible
    }

    public var isAnimating: Bool {
        phase == .showing || phase == .hiding
    }

    public mutating func beginShow() -> PanelTransitionStep {
        switch phase {
        case .visible, .showing:
            return PanelTransitionStep(
                generation: generation,
                shouldPerformTransition: false,
                reversedInFlight: false
            )
        case .hiding:
            generation &+= 1
            showCount &+= 1
            interruptedTransitions &+= 1
            phase = .showing
            return PanelTransitionStep(
                generation: generation,
                shouldPerformTransition: true,
                reversedInFlight: true
            )
        case .hidden:
            generation &+= 1
            showCount &+= 1
            phase = .showing
            return PanelTransitionStep(
                generation: generation,
                shouldPerformTransition: true,
                reversedInFlight: false
            )
        }
    }

    @discardableResult
    public mutating func completeShow(generation completedGen: UInt64) -> Bool {
        guard generation == completedGen, phase == .showing else {
            return false
        }
        phase = .visible
        return true
    }

    public mutating func beginHide() -> PanelTransitionStep {
        switch phase {
        case .hidden, .hiding:
            return PanelTransitionStep(
                generation: generation,
                shouldPerformTransition: false,
                reversedInFlight: false
            )
        case .showing:
            generation &+= 1
            hideCount &+= 1
            interruptedTransitions &+= 1
            phase = .hiding
            return PanelTransitionStep(
                generation: generation,
                shouldPerformTransition: true,
                reversedInFlight: true
            )
        case .visible:
            generation &+= 1
            hideCount &+= 1
            phase = .hiding
            return PanelTransitionStep(
                generation: generation,
                shouldPerformTransition: true,
                reversedInFlight: false
            )
        }
    }

    /// Returns `true` ONLY if `completedGen` still matches the active `.hiding` transition,
    /// authorizing `orderOut(nil)` without racing against a newer `beginShow()`.
    @discardableResult
    public mutating func completeHide(generation completedGen: UInt64) -> Bool {
        guard generation == completedGen, phase == .hiding else {
            return false
        }
        phase = .hidden
        return true
    }
}

public struct RuntimeDiagnosticsCounters: Codable, Equatable, Sendable {
    public var webViewCreations: Int
    public var loadRequests: Int
    public var reloadRequests: Int
    public var padSwitchCount: Int
    public var panelShowCount: Int
    public var panelHideCount: Int
    public var panelInterruptedTransitions: Int
    public var transitionPhase: PanelTransitionPhase
    public var memoryPressureEvictions: Int
    public var capacityEvictions: Int
    public var webContentProcessTerminations: Int
    public var webContentAutoRecoveries: Int

    public init(
        webViewCreations: Int = 0,
        loadRequests: Int = 0,
        reloadRequests: Int = 0,
        padSwitchCount: Int = 0,
        panelShowCount: Int = 0,
        panelHideCount: Int = 0,
        panelInterruptedTransitions: Int = 0,
        transitionPhase: PanelTransitionPhase = .hidden,
        memoryPressureEvictions: Int = 0,
        capacityEvictions: Int = 0,
        webContentProcessTerminations: Int = 0,
        webContentAutoRecoveries: Int = 0
    ) {
        self.webViewCreations = webViewCreations
        self.loadRequests = loadRequests
        self.reloadRequests = reloadRequests
        self.padSwitchCount = padSwitchCount
        self.panelShowCount = panelShowCount
        self.panelHideCount = panelHideCount
        self.panelInterruptedTransitions = panelInterruptedTransitions
        self.transitionPhase = transitionPhase
        self.memoryPressureEvictions = memoryPressureEvictions
        self.capacityEvictions = capacityEvictions
        self.webContentProcessTerminations = webContentProcessTerminations
        self.webContentAutoRecoveries = webContentAutoRecoveries
    }

    private enum CodingKeys: String, CodingKey {
        case webViewCreations, loadRequests, reloadRequests, padSwitchCount
        case panelShowCount, panelHideCount, panelInterruptedTransitions, transitionPhase
        case memoryPressureEvictions, capacityEvictions
        case webContentProcessTerminations, webContentAutoRecoveries
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.webViewCreations = try c.decodeIfPresent(Int.self, forKey: .webViewCreations) ?? 0
        self.loadRequests = try c.decodeIfPresent(Int.self, forKey: .loadRequests) ?? 0
        self.reloadRequests = try c.decodeIfPresent(Int.self, forKey: .reloadRequests) ?? 0
        self.padSwitchCount = try c.decodeIfPresent(Int.self, forKey: .padSwitchCount) ?? 0
        self.panelShowCount = try c.decodeIfPresent(Int.self, forKey: .panelShowCount) ?? 0
        self.panelHideCount = try c.decodeIfPresent(Int.self, forKey: .panelHideCount) ?? 0
        self.panelInterruptedTransitions = try c.decodeIfPresent(Int.self, forKey: .panelInterruptedTransitions) ?? 0
        self.transitionPhase = try c.decodeIfPresent(PanelTransitionPhase.self, forKey: .transitionPhase) ?? .hidden
        self.memoryPressureEvictions = try c.decodeIfPresent(Int.self, forKey: .memoryPressureEvictions) ?? 0
        self.capacityEvictions = try c.decodeIfPresent(Int.self, forKey: .capacityEvictions) ?? 0
        self.webContentProcessTerminations = try c.decodeIfPresent(Int.self, forKey: .webContentProcessTerminations) ?? 0
        self.webContentAutoRecoveries = try c.decodeIfPresent(Int.self, forKey: .webContentAutoRecoveries) ?? 0
    }
}

// MARK: - Deterministic Presentation-Frame Animation Flight & Mid-Flight Reversal Planner

public enum PanelAnimationCurve: String, Codable, Equatable, Sendable {
    case showEaseOut      // CAMediaTimingFunction(controlPoints: 0.22, 1.0, 0.36, 1.0)
    case hideEaseInOut    // CAMediaTimingFunction(name: .easeInEaseOut) -> (0.42, 0.0, 0.58, 1.0)
    case reduceMotionFade // CAMediaTimingFunction(name: .easeOut) -> (0.0, 0.0, 0.58, 1.0)

    public func evaluate(normalizedTime t: Double) -> Double {
        let clamped = Swift.min(Swift.max(t, 0.0), 1.0)
        if clamped <= 0.0 { return 0.0 }
        if clamped >= 1.0 { return 1.0 }
        switch self {
        case .showEaseOut:
            return Self.solveCubicBezier(x1: 0.22, y1: 1.0, x2: 0.36, y2: 1.0, x: clamped)
        case .hideEaseInOut:
            return Self.solveCubicBezier(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0, x: clamped)
        case .reduceMotionFade:
            return Self.solveCubicBezier(x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0, x: clamped)
        }
    }

    private static func sampleCurve(_ a: Double, _ b: Double, _ c: Double, _ u: Double) -> Double {
        ((a * u + b) * u + c) * u
    }

    private static func sampleDerivative(_ a: Double, _ b: Double, _ c: Double, _ u: Double) -> Double {
        (3.0 * a * u + 2.0 * b) * u + c
    }

    public static func solveCubicBezier(x1: Double, y1: Double, x2: Double, y2: Double, x: Double) -> Double {
        let cx = 3.0 * x1
        let bx = 3.0 * (x2 - x1) - cx
        let ax = 1.0 - cx - bx

        let cy = 3.0 * y1
        let by = 3.0 * (y2 - y1) - cy
        let ay = 1.0 - cy - by

        var u = x
        for _ in 0..<8 {
            let xEst = sampleCurve(ax, bx, cx, u) - x
            if abs(xEst) < 1e-6 { break }
            let d = sampleDerivative(ax, bx, cx, u)
            if abs(d) < 1e-6 { break }
            u -= xEst / d
        }
        u = Swift.min(Swift.max(u, 0.0), 1.0)
        if abs(sampleCurve(ax, bx, cx, u) - x) > 1e-5 {
            var lo = 0.0
            var hi = 1.0
            u = x
            for _ in 0..<16 {
                let xEst = sampleCurve(ax, bx, cx, u)
                if abs(xEst - x) < 1e-6 { break }
                if x > xEst {
                    lo = u
                } else {
                    hi = u
                }
                u = 0.5 * (lo + hi)
            }
        }
        return Swift.min(Swift.max(sampleCurve(ay, by, cy, u), 0.0), 1.0)
    }
}

public struct PanelPresentationSample: Equatable, Sendable {
    public var frame: CGRect
    public var alpha: CGFloat
    public var timeFraction: Double
    public var easedProgress: Double

    public init(frame: CGRect, alpha: CGFloat, timeFraction: Double, easedProgress: Double) {
        self.frame = frame
        self.alpha = alpha
        self.timeFraction = timeFraction
        self.easedProgress = easedProgress
    }
}

public struct PanelAnimationFlight: Equatable, Sendable {
    public var generation: UInt64
    public var isShowing: Bool
    public var anchor: AnchorPosition
    public var fromFrame: CGRect
    public var toFrame: CGRect
    public var fromAlpha: CGFloat
    public var toAlpha: CGFloat
    public var startedAt: TimeInterval
    public var duration: TimeInterval
    public var curve: PanelAnimationCurve
    public var reduceMotion: Bool

    public init(
        generation: UInt64,
        isShowing: Bool,
        anchor: AnchorPosition,
        fromFrame: CGRect,
        toFrame: CGRect,
        fromAlpha: CGFloat,
        toAlpha: CGFloat,
        startedAt: TimeInterval,
        duration: TimeInterval,
        curve: PanelAnimationCurve,
        reduceMotion: Bool
    ) {
        self.generation = generation
        self.isShowing = isShowing
        self.anchor = anchor
        self.fromFrame = fromFrame
        self.toFrame = toFrame
        self.fromAlpha = fromAlpha
        self.toAlpha = toAlpha
        self.startedAt = startedAt
        self.duration = Swift.max(0.001, duration)
        self.curve = curve
        self.reduceMotion = reduceMotion
    }

    public func presentationState(at timestamp: TimeInterval) -> PanelPresentationSample {
        let rawT = (timestamp - startedAt) / duration
        let clampedT = Swift.min(Swift.max(rawT, 0.0), 1.0)
        let p = curve.evaluate(normalizedTime: clampedT)
        let cgP = CGFloat(p)

        let frame: CGRect
        if reduceMotion {
            frame = toFrame
        } else {
            frame = CGRect(
                x: fromFrame.origin.x + (toFrame.origin.x - fromFrame.origin.x) * cgP,
                y: fromFrame.origin.y + (toFrame.origin.y - fromFrame.origin.y) * cgP,
                width: fromFrame.size.width + (toFrame.size.width - fromFrame.size.width) * cgP,
                height: fromFrame.size.height + (toFrame.size.height - fromFrame.size.height) * cgP
            )
        }
        let alpha = Swift.min(Swift.max(fromAlpha + (toAlpha - fromAlpha) * cgP, 0.0), 1.0)
        return PanelPresentationSample(
            frame: frame,
            alpha: alpha,
            timeFraction: clampedT,
            easedProgress: p
        )
    }
}

public enum PanelAnimationPlanner {
    /// Plans a `show` flight from either `hiddenFrame` (when hidden) or the exact interpolated
    /// current presentation frame (when reversing an in-flight hide), honoring Reduce Motion.
    public static func planShow(
        hiddenFrame: CGRect,
        visibleFrame: CGRect,
        anchor: AnchorPosition,
        generation: UInt64,
        now: TimeInterval,
        baseDuration: TimeInterval = AppSettings.defaultAnimationDuration,
        reduceMotion: Bool = false,
        reversedInFlight: Bool = false,
        inFlight: PanelAnimationFlight? = nil,
        liveWindowFrame: CGRect = .zero,
        liveWindowAlpha: CGFloat = 0.0,
        isWindowCurrentlyVisible: Bool = false
    ) -> PanelAnimationFlight {
        let clampedBase = Swift.max(0.08, baseDuration)

        if reduceMotion {
            let startAlpha: CGFloat
            if reversedInFlight, let inFlight {
                startAlpha = inFlight.presentationState(at: now).alpha
            } else if isWindowCurrentlyVisible {
                startAlpha = liveWindowAlpha
            } else {
                startAlpha = 0.0
            }
            let remainingAlpha = Double(Swift.max(0.25, 1.0 - startAlpha))
            return PanelAnimationFlight(
                generation: generation,
                isShowing: true,
                anchor: anchor,
                fromFrame: visibleFrame,
                toFrame: visibleFrame,
                fromAlpha: startAlpha,
                toAlpha: 1.0,
                startedAt: now,
                duration: Swift.max(0.06, 0.12 * remainingAlpha),
                curve: .reduceMotionFade,
                reduceMotion: true
            )
        }

        if reversedInFlight, let inFlight {
            let current = inFlight.presentationState(at: now)
            let totalDist = hypot(
                visibleFrame.origin.x - hiddenFrame.origin.x,
                visibleFrame.origin.y - hiddenFrame.origin.y
            )
            let remDist = hypot(
                visibleFrame.origin.x - current.frame.origin.x,
                visibleFrame.origin.y - current.frame.origin.y
            )
            let ratio = totalDist > 1.0 ? Swift.min(1.0, Swift.max(0.30, Double(remDist / totalDist))) : 0.5
            return PanelAnimationFlight(
                generation: generation,
                isShowing: true,
                anchor: anchor,
                fromFrame: current.frame,
                toFrame: visibleFrame,
                fromAlpha: current.alpha,
                toAlpha: 1.0,
                startedAt: now,
                duration: Swift.max(0.08, clampedBase * ratio),
                curve: .showEaseOut,
                reduceMotion: false
            )
        }

        return PanelAnimationFlight(
            generation: generation,
            isShowing: true,
            anchor: anchor,
            fromFrame: hiddenFrame,
            toFrame: visibleFrame,
            fromAlpha: 0.0,
            toAlpha: 1.0,
            startedAt: now,
            duration: clampedBase,
            curve: .showEaseOut,
            reduceMotion: false
        )
    }

    /// Plans a `hide` flight toward `hiddenFrame` from either `visibleFrame`/`liveWindowFrame`
    /// or the exact interpolated current presentation frame (when reversing an in-flight show),
    /// never jumping to the interrupted show's target `visibleFrame` and honoring Reduce Motion.
    public static func planHide(
        visibleFrame: CGRect,
        hiddenFrame: CGRect,
        anchor: AnchorPosition,
        generation: UInt64,
        now: TimeInterval,
        baseDuration: TimeInterval = AppSettings.defaultAnimationDuration,
        reduceMotion: Bool = false,
        reversedInFlight: Bool = false,
        inFlight: PanelAnimationFlight? = nil,
        liveWindowFrame: CGRect = .zero,
        liveWindowAlpha: CGFloat = 1.0
    ) -> PanelAnimationFlight {
        let clampedBase = Swift.max(0.08, baseDuration)

        if reduceMotion {
            let startAlpha: CGFloat
            if reversedInFlight, let inFlight {
                startAlpha = inFlight.presentationState(at: now).alpha
            } else {
                startAlpha = Swift.max(0.05, liveWindowAlpha)
            }
            let remainingAlpha = Double(Swift.max(0.25, startAlpha))
            return PanelAnimationFlight(
                generation: generation,
                isShowing: false,
                anchor: anchor,
                fromFrame: visibleFrame,
                toFrame: visibleFrame,
                fromAlpha: startAlpha,
                toAlpha: 0.0,
                startedAt: now,
                duration: Swift.max(0.06, 0.11 * remainingAlpha),
                curve: .reduceMotionFade,
                reduceMotion: true
            )
        }

        if reversedInFlight, let inFlight {
            let current = inFlight.presentationState(at: now)
            let totalDist = hypot(
                hiddenFrame.origin.x - visibleFrame.origin.x,
                hiddenFrame.origin.y - visibleFrame.origin.y
            )
            let remDist = hypot(
                hiddenFrame.origin.x - current.frame.origin.x,
                hiddenFrame.origin.y - current.frame.origin.y
            )
            let ratio = totalDist > 1.0 ? Swift.min(1.0, Swift.max(0.30, Double(remDist / totalDist))) : 0.5
            return PanelAnimationFlight(
                generation: generation,
                isShowing: false,
                anchor: anchor,
                fromFrame: current.frame,
                toFrame: hiddenFrame,
                fromAlpha: current.alpha,
                toAlpha: 0.0,
                startedAt: now,
                duration: Swift.max(0.08, clampedBase * ratio),
                curve: .hideEaseInOut,
                reduceMotion: false
            )
        }

        let startRect = (liveWindowFrame.width > 10 && liveWindowFrame.height > 10)
            ? liveWindowFrame
            : visibleFrame
        return PanelAnimationFlight(
            generation: generation,
            isShowing: false,
            anchor: anchor,
            fromFrame: startRect,
            toFrame: hiddenFrame,
            fromAlpha: Swift.max(0.05, liveWindowAlpha),
            toAlpha: 0.0,
            startedAt: now,
            duration: clampedBase,
            curve: .hideEaseInOut,
            reduceMotion: false
        )
    }
}
