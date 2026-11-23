import AppKit
import Foundation
import VeypaneCore

public struct AnchorAnimationProbeEntry: Codable, Sendable {
    public var anchor: String
    public var displayName: String
    public var screenFrame: String
    public var screenVisibleFrame: String
    public var hiddenFrame: String
    public var visibleFrame: String
    public var showDeltaX: Double
    public var showDeltaY: Double
    public var hideDeltaX: Double
    public var hideDeltaY: Double
    public var clampedInsideVisibleFrame: Bool
    public var directionMatchesAnchor: Bool
}

public struct MidFlightReversalProbeSummary: Codable, Sendable {
    public var anchor: String
    public var hiddenOriginX: Double
    public var hiddenOriginY: Double
    public var visibleOriginX: Double
    public var visibleOriginY: Double
    public var interruptedShowPresentationX: Double
    public var interruptedShowPresentationY: Double
    public var reverseHideStartOriginX: Double
    public var reverseHideStartOriginY: Double
    public var reverseShowStartOriginX: Double
    public var reverseShowStartOriginY: Double
    public var noJumpFromModelTarget: Bool
    public var staleHideCompletionRejected: Bool
}

public struct PanelAnimationProbeReport: Codable, Sendable {
    public var generatedAt: Date
    public var isolatedTempStore: Bool
    public var anchorChecks: [AnchorAnimationProbeEntry]
    public var multiDisplayLockVerified: Bool
    public var midFlightReversal: MidFlightReversalProbeSummary
    public var reduceMotionVerified: Bool
    public var allChecksPassed: Bool
}

/// Isolated `--panel-animation-probe <outputDir>` diagnostic mode (Feedback B `t265u`).
/// Uses an isolated temporary store without touching saved user config or opening visible UI windows,
/// verifying all 6 edge/corner anchors (including negative multi-display origins), display locking across
/// show/hide, mid-flight reversal from current presentation frame, stale-completion suppression, and Reduce Motion.
@MainActor
public enum PanelAnimationProbeRunner {
    public static func runAndExit(outputDirectoryPath: String) {
        do {
            let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
            try runProbe(into: outDir)
            Darwin.exit(0)
        } catch {
            FileHandle.standardError.write(Data("Panel animation probe failed: \(error.localizedDescription)\n".utf8))
            Darwin.exit(1)
        }
    }

    public static func runProbe(into outputDir: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let tempStoreDir = fm.temporaryDirectory.appendingPathComponent("VeypaneAnimProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempStoreDir) }

        let tempStore = VeypaneStore(directoryURL: tempStoreDir)
        var initial = WorkspaceState.makeDefault()
        initial.settings.hasCompletedOnboarding = true
        initial.settings.anchor = .bottomRight
        try tempStore.save(initial)

        let primaryDisplay = DisplayDescriptor(
            id: 1,
            name: "Primary Retina",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 54, width: 1512, height: 890),
            isMain: true
        )
        let negativeSecondaryDisplay = DisplayDescriptor(
            id: 2,
            name: "Secondary Left-Lower",
            frame: CGRect(x: -1920, y: -360, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: -310, width: 1920, height: 1005),
            isMain: false
        )

        var anchorEntries: [AnchorAnimationProbeEntry] = []
        for display in [primaryDisplay, negativeSecondaryDisplay] {
            for anchor in AnchorPosition.allCases {
                let vis = PanelGeometry.visibleFrame(
                    screenVisibleFrame: display.visibleFrame,
                    anchor: anchor,
                    defaultWidthPercent: 48,
                    defaultHeightPercent: 84,
                    edgeInset: 14
                )
                let hid = PanelGeometry.hiddenFrame(
                    visibleFrame: vis,
                    screenFrame: display.frame,
                    anchor: anchor
                )
                let showDX = Double(vis.origin.x - hid.origin.x)
                let showDY = Double(vis.origin.y - hid.origin.y)
                let hideDX = Double(hid.origin.x - vis.origin.x)
                let hideDY = Double(hid.origin.y - vis.origin.y)

                let horizOK = anchor.isLeftAligned ? (showDX > 0 && hideDX < 0) : (showDX < 0 && hideDX > 0)
                let vertOK: Bool = switch anchor {
                case .left, .right:
                    abs(showDY) < 0.001 && abs(hideDY) < 0.001
                case .topLeft, .topRight:
                    showDY < 0 && hideDY > 0
                case .bottomLeft, .bottomRight:
                    showDY > 0 && hideDY < 0
                }
                let clamped = display.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(vis)

                anchorEntries.append(
                    AnchorAnimationProbeEntry(
                        anchor: anchor.rawValue,
                        displayName: display.name,
                        screenFrame: NSStringFromRect(display.frame),
                        screenVisibleFrame: NSStringFromRect(display.visibleFrame),
                        hiddenFrame: NSStringFromRect(hid),
                        visibleFrame: NSStringFromRect(vis),
                        showDeltaX: showDX,
                        showDeltaY: showDY,
                        hideDeltaX: hideDX,
                        hideDeltaY: hideDY,
                        clampedInsideVisibleFrame: clamped,
                        directionMatchesAnchor: horizOK && vertOK
                    )
                )
            }
        }

        // Verify multi-display locking on AppModel without creating any visible NSWindow:
        // Showing on `negativeSecondaryDisplay` with `.bottomRight` locks `presentedDisplay` & `presentedAnchor`.
        let model = AppModel(
            store: tempStore,
            allowExtensionPrompts: false,
            useNonPersistentWebsiteDataStore: true
        )
        model.simulatedDisplaysOverride = [primaryDisplay, negativeSecondaryDisplay]
        model.state.settings.anchor = .bottomRight
        model.showPanel(activateFocus: false, openedFromEdge: true, triggeredOnDisplay: negativeSecondaryDisplay)
        let lockedOnShow = (model.presentedDisplay?.id == negativeSecondaryDisplay.id && model.presentedAnchor == .bottomRight)
        model.hidePanel()
        let clearedAfterHeadlessHide = (model.presentedDisplay == nil && model.presentedAnchor == nil)
        let multiDisplayLockOK = lockedOnShow && clearedAfterHeadlessHide

        // Verify mid-flight show -> hide -> show reversal on bottomRight using PanelAnimationPlanner + PanelTransitionController
        var tc = PanelTransitionController()
        let visBR = PanelGeometry.visibleFrame(
            screenVisibleFrame: primaryDisplay.visibleFrame,
            anchor: .bottomRight,
            defaultWidthPercent: 48,
            defaultHeightPercent: 84,
            edgeInset: 14
        )
        let hidBR = PanelGeometry.hiddenFrame(
            visibleFrame: visBR,
            screenFrame: primaryDisplay.frame,
            anchor: .bottomRight
        )

        let showStep1 = tc.beginShow()
        let flight1 = PanelAnimationPlanner.planShow(
            hiddenFrame: hidBR,
            visibleFrame: visBR,
            anchor: .bottomRight,
            generation: showStep1.generation,
            now: 100.0,
            baseDuration: 0.20,
            reduceMotion: false,
            reversedInFlight: showStep1.reversedInFlight
        )
        let midShowSample = flight1.presentationState(at: 100.07)

        let hideStep = tc.beginHide()
        let flight2 = PanelAnimationPlanner.planHide(
            visibleFrame: visBR,
            hiddenFrame: hidBR,
            anchor: .bottomRight,
            generation: hideStep.generation,
            now: 100.07,
            baseDuration: 0.20,
            reduceMotion: false,
            reversedInFlight: hideStep.reversedInFlight,
            inFlight: flight1,
            liveWindowFrame: visBR, // even if NSWindow model frame already holds target `visBR`, planner must use presentation frame!
            liveWindowAlpha: 1.0
        )
        let midHideSample = flight2.presentationState(at: 100.12)

        let showStep2 = tc.beginShow()
        let flight3 = PanelAnimationPlanner.planShow(
            hiddenFrame: hidBR,
            visibleFrame: visBR,
            anchor: .bottomRight,
            generation: showStep2.generation,
            now: 100.12,
            baseDuration: 0.20,
            reduceMotion: false,
            reversedInFlight: showStep2.reversedInFlight,
            inFlight: flight2,
            liveWindowFrame: hidBR,
            liveWindowAlpha: 0.0,
            isWindowCurrentlyVisible: true
        )

        let staleHideAllowed = tc.completeHide(generation: hideStep.generation)
        let finalShowCompleted = tc.completeShow(generation: showStep2.generation)

        let noJump = abs(flight2.fromFrame.origin.x - midShowSample.frame.origin.x) < 0.01
            && abs(flight2.fromFrame.origin.y - midShowSample.frame.origin.y) < 0.01
            && abs(flight3.fromFrame.origin.x - midHideSample.frame.origin.x) < 0.01
            && abs(flight3.fromFrame.origin.y - midHideSample.frame.origin.y) < 0.01
            && abs(flight2.fromFrame.origin.x - visBR.origin.x) > 5.0
            && abs(flight2.fromFrame.origin.y - visBR.origin.y) > 5.0

        let reversalSummary = MidFlightReversalProbeSummary(
            anchor: AnchorPosition.bottomRight.rawValue,
            hiddenOriginX: Double(hidBR.origin.x),
            hiddenOriginY: Double(hidBR.origin.y),
            visibleOriginX: Double(visBR.origin.x),
            visibleOriginY: Double(visBR.origin.y),
            interruptedShowPresentationX: Double(midShowSample.frame.origin.x),
            interruptedShowPresentationY: Double(midShowSample.frame.origin.y),
            reverseHideStartOriginX: Double(flight2.fromFrame.origin.x),
            reverseHideStartOriginY: Double(flight2.fromFrame.origin.y),
            reverseShowStartOriginX: Double(flight3.fromFrame.origin.x),
            reverseShowStartOriginY: Double(flight3.fromFrame.origin.y),
            noJumpFromModelTarget: noJump,
            staleHideCompletionRejected: (!staleHideAllowed && finalShowCompleted)
        )

        // Verify Reduce Motion keeps frame strictly pinned at visibleFrame while fading alpha only
        let rmShow = PanelAnimationPlanner.planShow(
            hiddenFrame: hidBR,
            visibleFrame: visBR,
            anchor: .bottomRight,
            generation: 99,
            now: 200.0,
            baseDuration: 0.20,
            reduceMotion: true
        )
        let rmHide = PanelAnimationPlanner.planHide(
            visibleFrame: visBR,
            hiddenFrame: hidBR,
            anchor: .bottomRight,
            generation: 100,
            now: 200.05,
            baseDuration: 0.20,
            reduceMotion: true,
            reversedInFlight: true,
            inFlight: rmShow
        )
        let rmOK = (rmShow.fromFrame == visBR && rmShow.toFrame == visBR && rmHide.fromFrame == visBR && rmHide.toFrame == visBR && rmHide.fromAlpha > 0 && rmHide.toAlpha == 0)

        let allPassed = anchorEntries.allSatisfy { $0.clampedInsideVisibleFrame && $0.directionMatchesAnchor }
            && multiDisplayLockOK
            && reversalSummary.noJumpFromModelTarget
            && reversalSummary.staleHideCompletionRejected
            && rmOK

        let report = PanelAnimationProbeReport(
            generatedAt: Date(),
            isolatedTempStore: true,
            anchorChecks: anchorEntries,
            multiDisplayLockVerified: multiDisplayLockOK,
            midFlightReversal: reversalSummary,
            reduceMotionVerified: rmOK,
            allChecksPassed: allPassed
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let outFile = outputDir.appendingPathComponent("panel-animation-probe.json")
        try data.write(to: outFile, options: .atomic)
        print(outFile.path)
    }
}
