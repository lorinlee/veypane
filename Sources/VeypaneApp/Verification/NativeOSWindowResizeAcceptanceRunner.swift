import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI
import WebKit
import VeypaneCore

public struct PublicCursorSignature: Codable, Equatable, Sendable {
    public var imageWidth: Double
    public var imageHeight: Double
    public var hotSpotX: Double
    public var hotSpotY: Double
    public var pixelHashHex: String
}

public struct NativeOSWindowResizeCaseResult: Codable, Sendable {
    public var caseName: String
    public var expectedHandle: String
    public var startAppKit: String
    public var endAppKit: String
    public var preDragPanelOnscreenConfirmed: Bool
    public var targetOwnedBySelfPIDConfirmed: Bool
    public var osHIDEventsDequeued: Int
    public var hoveredHandleAfterOSMove: String
    public var observedCursorSignature: PublicCursorSignature
    public var expectedCursorSignature: PublicCursorSignature
    public var cursorDistinctFromArrow: Bool
    public var cursorDistinctFromSingleAxisCounterparts: Bool
    public var cursorMatchesExpectedPublicFrameResize: Bool
    public var frameBefore: String
    public var frameAfter: String
    public var widthDelta: Double
    public var heightDelta: Double
    public var oppositeSideAnchored: Bool
    public var settingsWidthPercentAfter: Double
    public var settingsHeightPercentAfter: Double
    public var passed: Bool
}

public struct NativeOSWindowResizeAcceptanceReport: Codable, Sendable {
    public var generatedAt: Date
    public var headSourceUnderTest: String
    public var executionMode: String
    public var appIsRunningMainLoop: Bool
    public var axTrusted: Bool
    public var cgPostEventAccess: Bool
    public var isolatedTemporaryStore: Bool
    public var nonPersistentWebDataStore: Bool
    public var selfOwnedBackdropVerified: Bool
    public var interiorHoverRestoresArrowVerified: Bool
    public var leftEdgePositiveWidthControlVerified: Bool
    public var topEdgeVerticalGrowAndShrinkVerified: Bool
    public var topLeftCornerDiagonalGrowAndShrinkVerified: Bool
    public var minSizeAndScreenBoundsClampVerified: Bool
    public var persistenceAcrossPadSwitchAndHideShowVerified: Bool
    public var midResizeHideCancelsSessionCleanlyVerified: Bool
    public var totalDragCases: Int
    public var passedDragCases: Int
    public var passedAllChecks: Bool
    public var arrowReferenceSignature: PublicCursorSignature
    public var cases: [NativeOSWindowResizeCaseResult]
}

/// Real OS `CGEvent` hover & drag acceptance runner (`t315`/`t316`/`t319`).
/// Exercises the actual production `AppModel` + `SlideOverPanel` + `NSHostingView<PanelRootView>` +
/// `PanelResizePerimeterCursorView` in an isolated temporary store with `WKWebsiteDataStore.nonPersistent()`,
/// targeting a visible self-owned window over a self-owned backdrop window and restoring cursor + frontmost app on exit.
/// Requires an active `NSApplication.shared.run()` event loop (`--native-os-window-resize-probe <outputDir>`).
@MainActor
public enum NativeOSWindowResizeAcceptanceRunner {
    public static let defaultReportFilename = "native-os-window-resize-acceptance.json"

    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // Strict 60s watchdog so OS fixture can never hang
        DispatchQueue.global().asyncAfter(deadline: .now() + 60.0) {
            FileHandle.standardError.write(Data("Native OS window resize acceptance timed out after 60s\n".utf8))
            Darwin.exit(2)
        }

        Task { @MainActor in
            do {
                let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
                _ = try await runAcceptance(
                    into: outDir,
                    executionMode: "Standalone AppKit NSApplication.run() process (--native-os-window-resize-probe)"
                )
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Native OS window resize acceptance failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    public static func samplePublicCursorSignature(_ cursor: NSCursor) -> PublicCursorSignature {
        let img = cursor.image
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 32,
            pixelsHigh: 32,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 32 * 4,
            bitsPerPixel: 32
        )
        var hash: UInt64 = 0xcbf29ce484222325
        if let rep, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: 32, height: 32).fill()
            img.draw(
                in: NSRect(x: 0, y: 0, width: 32, height: 32),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )
            ctx.flushGraphics()
            NSGraphicsContext.restoreGraphicsState()
            if let ptr = rep.bitmapData {
                let byteCount = 32 * 32 * 4
                for i in 0..<byteCount {
                    hash ^= UInt64(ptr[i])
                    hash &*= 0x100000001b3
                }
            }
        }
        return PublicCursorSignature(
            imageWidth: Double(img.size.width),
            imageHeight: Double(img.size.height),
            hotSpotX: Double(cursor.hotSpot.x),
            hotSpotY: Double(cursor.hotSpot.y),
            pixelHashHex: String(format: "%016llx", hash)
        )
    }

    public static func runAcceptance(
        into outputDir: URL,
        reportFilename: String = defaultReportFilename,
        executionMode: String = "Opt-in Swift Testing (VEYPANE_RUN_OS_RESIZE_TESTS=1)"
    ) async throws -> NativeOSWindowResizeAcceptanceReport {
        let app = NSApplication.shared
        guard app.isRunning else {
            throw NSError(
                domain: "NativeOSWindowResizeAcceptance",
                code: 9,
                userInfo: [
                    NSLocalizedDescriptionKey: "NSApplication.shared.isRunning is false: swiftpm-testing-helper executes @Test on DispatchQueue.main without NSApplication.run() (WindowServer HID mouseMoved/leftMouseDragged CGEvents are not translated into NSEvents under Task.sleep alone, nested app.run() deadlocks DispatchQueue.main, and calling app.nextEvent without app.run() terminates xctest). Execute via standalone VeypaneApp --native-os-window-resize-probe <outputDir>."
                ]
            )
        }

        let axTrusted = AXIsProcessTrusted()
        let postAccess = CGPreflightPostEventAccess()
        guard postAccess else {
            throw NSError(
                domain: "NativeOSWindowResizeAcceptance",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "CGPreflightPostEventAccess() is false; real OS CGEvent resize verification cannot run."]
            )
        }

        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let savedPolicy = app.activationPolicy()
        let savedFrontApp = NSWorkspace.shared.frontmostApplication
        let screen = NSScreen.screens.first
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visFrame = screen?.visibleFrame ?? CGRect(x: 0, y: 40, width: 1920, height: 1016)
        let initialMouseCG = CGEvent(source: nil)?.location ?? CGPoint(x: screenFrame.midX, y: screenFrame.midY)

        func toCG(_ appKitPoint: CGPoint) -> CGPoint {
            CGPoint(x: appKitPoint.x, y: screenFrame.height - appKitPoint.y)
        }

        app.setActivationPolicy(.regular)

        // Self-owned backdrop window covering `visFrame` so 100% of hover/drag coordinates belong to `selfPID`
        let backdropRect = visFrame.insetBy(dx: 4, dy: 4)
        let backdropWindow = NSWindow(
            contentRect: backdropRect,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backdropWindow.backgroundColor = .underPageBackgroundColor
        backdropWindow.level = .normal
        backdropWindow.isReleasedWhenClosed = false
        backdropWindow.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        let tempStoreRoot = fm.temporaryDirectory.appendingPathComponent(
            "VeypaneOSResizeStore-\(UUID().uuidString)",
            isDirectory: true
        )

        defer {
            backdropWindow.orderOut(nil)
            CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: initialMouseCG,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
            _ = app.setActivationPolicy(savedPolicy)
            savedFrontApp?.activate()
            try? fm.removeItem(at: tempStoreRoot)
        }

        let selfPID = Int(ProcessInfo.processInfo.processIdentifier)

        func topOwnerPID(at cgPoint: CGPoint) -> Int {
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                return -1
            }
            for entry in list {
                if (entry[kCGWindowLayer as String] as? Int ?? 0) >= 20 { continue }
                var bounds = CGRect.zero
                if let dict = entry[kCGWindowBounds as String] as? NSDictionary {
                    CGRectMakeWithDictionaryRepresentation(dict, &bounds)
                }
                if bounds.contains(cgPoint) {
                    return entry[kCGWindowOwnerPID as String] as? Int ?? -1
                }
            }
            return -1
        }

        func isWindowOnscreen(_ windowNumber: Int) -> Bool {
            guard windowNumber > 0,
                  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                return false
            }
            return list.contains { entry in
                (entry[kCGWindowNumber as String] as? Int) == windowNumber
                    && ((entry[kCGWindowIsOnscreen as String] as? Bool) ?? true)
            }
        }

        let backdropVerifyPt = toCG(CGPoint(x: backdropRect.minX + 60, y: backdropRect.midY))
        let backdropDeadline = Date().addingTimeInterval(4.0)
        while topOwnerPID(at: backdropVerifyPt) != selfPID && Date() < backdropDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let backdropOK = (topOwnerPID(at: backdropVerifyPt) == selfPID)
        guard backdropOK else {
            throw NSError(
                domain: "NativeOSWindowResizeAcceptance",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Self-owned backdrop window did not become topmost at \(backdropVerifyPt); refusing to inject OS CGEvents."]
            )
        }

        let store = VeypaneStore(directoryURL: tempStoreRoot)
        var initialState = WorkspaceState(pads: [
            Pad(title: "Synthetic Alpha", url: URL(string: "about:blank")!),
            Pad(title: "Synthetic Beta", url: URL(string: "about:blank")!)
        ])
        initialState.settings.hasCompletedOnboarding = true
        initialState.settings.isPinnedOpen = true
        initialState.settings.anchor = .right
        initialState.settings.widthPercent = 58.0
        initialState.settings.heightPercent = 64.0
        initialState.settings.animationDuration = 0.10
        try store.save(initialState)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.startRuntimeServices {
            PanelRootView.makeHostingView(model: model)
        }
        defer { model.stopRuntimeServices() }

        guard let panel = model.panel else {
            throw NSError(domain: "NativeOSWindowResizeAcceptance", code: 12, userInfo: [NSLocalizedDescriptionKey: "Missing production SlideOverPanel"])
        }
        panel.reduceMotionOverride = false

        model.showPanel(activateFocus: true, openedFromEdge: false)
        try await Task.sleep(nanoseconds: 250_000_000)

        let arrowSig = samplePublicCursorSignature(.arrow)
        let leftExpectedSig = samplePublicCursorSignature(SlideOverPanel.resizeCursor(for: .left))
        let topExpectedSig = samplePublicCursorSignature(SlideOverPanel.resizeCursor(for: .top))
        let tlExpectedSig = samplePublicCursorSignature(SlideOverPanel.resizeCursor(for: .topLeft))

        // Verify interior hover via real OS CGEvent(.mouseMoved) selects arrow cursor (`hoveredResizeHandle == nil`)
        let interiorAppKit = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let interiorCG = toCG(interiorAppKit)
        guard topOwnerPID(at: interiorCG) == selfPID else {
            throw NSError(domain: "NativeOSWindowResizeAcceptance", code: 13, userInfo: [NSLocalizedDescriptionKey: "Interior panel point not owned by selfPID"])
        }
        // First hover top edge then return to interior so arrow restoration is genuinely exercised via OS events
        let preTopCG = toCG(CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 3.5))
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: preTopCG, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 50_000_000)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: interiorCG, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 60_000_000)
        let interiorSigAfterMove = samplePublicCursorSignature(NSCursor.current)
        let interiorArrowOK = (panel.hoveredResizeHandle == nil) && (interiorSigAfterMove.pixelHashHex == arrowSig.pixelHashHex)

        let baselineNominalFrame = panel.frame

        func resetToBaselineFrame() async throws {
            model.state.settings.anchor = .right
            model.state.settings.widthPercent = 58.0
            model.state.settings.heightPercent = 64.0
            panel.setFrame(baselineNominalFrame, display: true)
            panel.syncPerimeterCursorOverlayFrame()
            // Move to neutral interior before each hover/drag case so cursor starts from `.arrow`
            let neutralCG = toCG(CGPoint(x: baselineNominalFrame.midX, y: baselineNominalFrame.midY))
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: neutralCG, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 40_000_000)
        }

        func executeOSDragCase(
            name: String,
            expectedHandle: PanelResizeHandle,
            startProvider: (CGRect) -> CGPoint,
            deltaAppKit: CGPoint,
            resetBefore: Bool = true,
            validateGeometry: (CGRect, CGRect) -> (anchored: Bool, sizeOK: Bool)
        ) async throws -> NativeOSWindowResizeCaseResult {
            if resetBefore {
                try await resetToBaselineFrame()
            }
            let before = panel.frame
            let preOnscreen = isWindowOnscreen(panel.windowNumber) && panel.isVisible && model.isPanelVisible
            let startPt = startProvider(before)
            let endPt = CGPoint(x: startPt.x + deltaAppKit.x, y: startPt.y + deltaAppKit.y)
            let startCG = toCG(startPt)
            let endCG = toCG(endPt)

            let ownerAtStart = topOwnerPID(at: startCG)
            let ownedOK = (ownerAtStart == selfPID)
            guard preOnscreen && ownedOK else {
                throw NSError(
                    domain: "NativeOSWindowResizeAcceptance",
                    code: 14,
                    userInfo: [NSLocalizedDescriptionKey: "Precondition failed in \(name): onscreen=\(preOnscreen), ownerPID=\(ownerAtStart) vs selfPID=\(selfPID)"]
                )
            }

            let osCountBefore = panel.osBackedEventsReceivedCount

            // 1. Real OS CGEvent hover (`mouseMoved` with 1pt pre-nudge so WindowServer always emits a fresh move)
            let nudgeCG = CGPoint(x: startCG.x, y: startCG.y + 1.0)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: nudgeCG, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 25_000_000)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: startCG, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 55_000_000)

            let hoveredAfterMove = panel.hoveredResizeHandle
            let observedSig = samplePublicCursorSignature(NSCursor.current)
            let expectedSig = samplePublicCursorSignature(SlideOverPanel.resizeCursor(for: expectedHandle))
            let distinctFromArrow = (observedSig.pixelHashHex != arrowSig.pixelHashHex)
            let distinctFromCounterparts: Bool = switch expectedHandle {
            case .left, .right:
                observedSig.pixelHashHex != topExpectedSig.pixelHashHex
                    && observedSig.pixelHashHex != tlExpectedSig.pixelHashHex
            case .top, .bottom:
                observedSig.pixelHashHex != leftExpectedSig.pixelHashHex
                    && observedSig.pixelHashHex != tlExpectedSig.pixelHashHex
            case .topLeft, .bottomRight, .topRight, .bottomLeft:
                observedSig.pixelHashHex != leftExpectedSig.pixelHashHex
                    && observedSig.pixelHashHex != topExpectedSig.pixelHashHex
            }
            let cursorMatchesExpected = (observedSig.pixelHashHex == expectedSig.pixelHashHex)
                && distinctFromArrow
                && distinctFromCounterparts

            // 2. Real OS CGEvent press -> 8-step drag -> release
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: startCG, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 35_000_000)

            for step in 1...8 {
                let t = CGFloat(step) / 8.0
                let curCG = CGPoint(
                    x: startCG.x + (endCG.x - startCG.x) * t,
                    y: startCG.y + (endCG.y - startCG.y) * t
                )
                CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: curCG, mouseButton: .left)?.post(tap: .cghidEventTap)
                try await Task.sleep(nanoseconds: 20_000_000)
            }

            CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: endCG, mouseButton: .left)?.post(tap: .cghidEventTap)
            try await Task.sleep(nanoseconds: 45_000_000)

            let osEventsCount = panel.osBackedEventsReceivedCount - osCountBefore
            let after = panel.frame
            let (anchored, sizeOK) = validateGeometry(before, after)
            let casePassed = preOnscreen
                && ownedOK
                && osEventsCount >= 8
                && (hoveredAfterMove == expectedHandle)
                && cursorMatchesExpected
                && anchored
                && sizeOK

            return NativeOSWindowResizeCaseResult(
                caseName: name,
                expectedHandle: expectedHandle.rawValue,
                startAppKit: NSStringFromPoint(startPt),
                endAppKit: NSStringFromPoint(endPt),
                preDragPanelOnscreenConfirmed: preOnscreen,
                targetOwnedBySelfPIDConfirmed: ownedOK,
                osHIDEventsDequeued: osEventsCount,
                hoveredHandleAfterOSMove: hoveredAfterMove?.rawValue ?? "nil",
                observedCursorSignature: observedSig,
                expectedCursorSignature: expectedSig,
                cursorDistinctFromArrow: distinctFromArrow,
                cursorDistinctFromSingleAxisCounterparts: distinctFromCounterparts,
                cursorMatchesExpectedPublicFrameResize: cursorMatchesExpected,
                frameBefore: NSStringFromRect(before),
                frameAfter: NSStringFromRect(after),
                widthDelta: Double(after.width - before.width),
                heightDelta: Double(after.height - before.height),
                oppositeSideAnchored: anchored,
                settingsWidthPercentAfter: model.state.settings.widthPercent,
                settingsHeightPercentAfter: model.state.settings.heightPercent,
                passed: casePassed
            )
        }

        var cases: [NativeOSWindowResizeCaseResult] = []

        // 1 & 2: Positive WIDTH control — LEFT EDGE grow & shrink (`minX + 3.5` inside 5pt strip, clear of 2pt NSThemeFrame border)
        let c1 = try await executeOSDragCase(
            name: "1_control_left_edge_grow",
            expectedHandle: .left,
            startProvider: { CGPoint(x: $0.minX + 3.5, y: $0.midY) },
            deltaAppKit: CGPoint(x: -72, y: 0)
        ) { b, a in
            (abs(a.maxX - b.maxX) <= 1 && abs(a.minY - b.minY) <= 1, abs((a.width - b.width) - 72) <= 3 && abs(a.height - b.height) <= 1)
        }
        cases.append(c1)

        let c2 = try await executeOSDragCase(
            name: "2_control_left_edge_shrink",
            expectedHandle: .left,
            startProvider: { CGPoint(x: $0.minX + 3.5, y: $0.midY) },
            deltaAppKit: CGPoint(x: 64, y: 0)
        ) { b, a in
            (abs(a.maxX - b.maxX) <= 1 && abs(a.minY - b.minY) <= 1, abs((a.width - b.width) + 64) <= 3 && abs(a.height - b.height) <= 1)
        }
        cases.append(c2)

        // 3 & 4: TOP EDGE (`maxY - 3.5` inside 32pt titlebar zone) vertical grow & shrink
        let c3 = try await executeOSDragCase(
            name: "3_top_edge_vertical_grow",
            expectedHandle: .top,
            startProvider: { CGPoint(x: $0.midX, y: $0.maxY - 3.5) },
            deltaAppKit: CGPoint(x: 0, y: 76)
        ) { b, a in
            (abs(a.minY - b.minY) <= 1 && abs(a.minX - b.minX) <= 1, abs((a.height - b.height) - 76) <= 3 && abs(a.width - b.width) <= 1)
        }
        cases.append(c3)

        let c4 = try await executeOSDragCase(
            name: "4_top_edge_vertical_shrink",
            expectedHandle: .top,
            startProvider: { CGPoint(x: $0.midX, y: $0.maxY - 3.5) },
            deltaAppKit: CGPoint(x: 0, y: -84)
        ) { b, a in
            (abs(a.minY - b.minY) <= 1 && abs(a.minX - b.minX) <= 1, abs((a.height - b.height) + 84) <= 3 && abs(a.width - b.width) <= 1)
        }
        cases.append(c4)

        // 5 & 6: TOP-LEFT CORNER diagonal grow & shrink (strictly inside 12pt rounded-corner alpha & 15x15 corner zone)
        let c5 = try await executeOSDragCase(
            name: "5_top_left_corner_diagonal_grow",
            expectedHandle: .topLeft,
            startProvider: { CGPoint(x: $0.minX + 3.5, y: $0.maxY - 10.0) },
            deltaAppKit: CGPoint(x: -80, y: 68)
        ) { b, a in
            (abs(a.maxX - b.maxX) <= 1 && abs(a.minY - b.minY) <= 1, abs((a.width - b.width) - 80) <= 3 && abs((a.height - b.height) - 68) <= 3)
        }
        cases.append(c5)

        let c6 = try await executeOSDragCase(
            name: "6_top_left_corner_diagonal_shrink",
            expectedHandle: .topLeft,
            startProvider: { CGPoint(x: $0.minX + 10.0, y: $0.maxY - 3.5) },
            deltaAppKit: CGPoint(x: 66, y: -62)
        ) { b, a in
            (abs(a.maxX - b.maxX) <= 1 && abs(a.minY - b.minY) <= 1, abs((a.width - b.width) + 66) <= 3 && abs((a.height - b.height) + 62) <= 3)
        }
        cases.append(c6)

        // 7: TOP-LEFT CORNER min-size clamp (`320 x 340`) with opposite `(maxX, minY)` anchored
        let c7 = try await executeOSDragCase(
            name: "7_top_left_corner_min_size_clamp",
            expectedHandle: .topLeft,
            startProvider: { CGPoint(x: $0.minX + 4.5, y: $0.maxY - 4.5) },
            deltaAppKit: CGPoint(x: 1200, y: -1100)
        ) { b, a in
            (
                abs(a.maxX - b.maxX) <= 1 && abs(a.minY - b.minY) <= 1,
                abs(a.width - PanelGeometry.minPanelWidth) <= 1 && abs(a.height - PanelGeometry.minPanelHeight) <= 1
            )
        }
        cases.append(c7)

        // 8: Persistence across pad switch (`selectPad`) and hide/show (`topRight` corner slide-out/in) after real OS diagonal resize
        let c8 = try await executeOSDragCase(
            name: "8_top_left_diagonal_resize_for_persistence_check",
            expectedHandle: .topLeft,
            startProvider: { CGPoint(x: $0.minX + 4.5, y: $0.maxY - 4.5) },
            deltaAppKit: CGPoint(x: -60, y: 54)
        ) { b, a in
            (abs(a.maxX - b.maxX) <= 1 && abs(a.minY - b.minY) <= 1, abs((a.width - b.width) - 60) <= 3 && abs((a.height - b.height) - 54) <= 3)
        }
        cases.append(c8)

        let targetSizeAfterOSDrag = panel.frame.size
        let reloadedDisk = store.load().state
        let diskPersistedOK = abs(reloadedDisk.settings.widthPercent - model.state.settings.widthPercent) < 0.05
            && abs(reloadedDisk.settings.heightPercent - model.state.settings.heightPercent) < 0.05
            && reloadedDisk.settings.panelSizeUserCustomized

        model.selectPad(model.state.pads[1].id)
        try await Task.sleep(nanoseconds: 220_000_000)
        let padSwitchKeptOK = abs(panel.frame.width - targetSizeAfterOSDrag.width) <= 3
            && abs(panel.frame.height - targetSizeAfterOSDrag.height) <= 3

        model.state.settings.anchor = .topRight
        model.refreshPanelGeometryAndAppearance()
        try await Task.sleep(nanoseconds: 220_000_000)
        model.hidePanel()
        try await Task.sleep(nanoseconds: 220_000_000)
        let hiddenOK = !panel.isVisible && !model.isPanelVisible
        model.showPanel(activateFocus: true, openedFromEdge: false)
        try await Task.sleep(nanoseconds: 220_000_000)
        let reshowKeptOK = panel.isVisible
            && abs(panel.frame.width - targetSizeAfterOSDrag.width) <= 3
            && abs(panel.frame.height - targetSizeAfterOSDrag.height) <= 3
        let persistenceOK = c8.passed && diskPersistedOK && padSwitchKeptOK && hiddenOK && reshowKeptOK

        // 9: Mid-interactive-resize `hidePanel()` state-transition check (ensures `activeResizeSession` cancels cleanly)
        let midStartCG = toCG(CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 3.5))
        guard topOwnerPID(at: midStartCG) == selfPID else {
            throw NSError(domain: "NativeOSWindowResizeAcceptance", code: 15, userInfo: [NSLocalizedDescriptionKey: "Mid-resize start not owned by selfPID"])
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: midStartCG, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 35_000_000)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: midStartCG, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 35_000_000)
        let sessionStartedBeforeHide = (panel.activeResizeSession != nil)
        model.hidePanel()
        let sessionClearedImmediatelyOnHide = (panel.activeResizeSession == nil) && !panel.isInInteractiveResize
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: midStartCG, mouseButton: .left)?.post(tap: .cghidEventTap)
        try await Task.sleep(nanoseconds: 220_000_000)
        model.showPanel(activateFocus: true, openedFromEdge: false)
        try await Task.sleep(nanoseconds: 220_000_000)
        let midResizeHideTransitionOK = sessionStartedBeforeHide
            && sessionClearedImmediatelyOnHide
            && !panel.isInInteractiveResize
            && panel.isVisible

        let leftControlOK = c1.passed && c2.passed && c1.widthDelta >= 69 && c2.widthDelta <= -61
        let topVerticalOK = c3.passed && c4.passed && c3.heightDelta >= 73 && c4.heightDelta <= -81
        let topLeftDiagonalOK = c5.passed && c6.passed
            && c5.widthDelta >= 77 && c5.heightDelta >= 65
            && c6.widthDelta <= -63 && c6.heightDelta <= -59
        let minBoundsOK = c7.passed
        let passedCasesCount = cases.filter(\.passed).count
        let allPassed = backdropOK
            && interiorArrowOK
            && leftControlOK
            && topVerticalOK
            && topLeftDiagonalOK
            && minBoundsOK
            && persistenceOK
            && midResizeHideTransitionOK
            && (passedCasesCount == cases.count)

        let report = NativeOSWindowResizeAcceptanceReport(
            generatedAt: Date(),
            headSourceUnderTest: "Production AppModel + SlideOverPanel + NSHostingView<PanelRootView> + PanelResizePerimeterCursorView",
            executionMode: executionMode,
            appIsRunningMainLoop: app.isRunning,
            axTrusted: axTrusted,
            cgPostEventAccess: postAccess,
            isolatedTemporaryStore: true,
            nonPersistentWebDataStore: true,
            selfOwnedBackdropVerified: backdropOK,
            interiorHoverRestoresArrowVerified: interiorArrowOK,
            leftEdgePositiveWidthControlVerified: leftControlOK,
            topEdgeVerticalGrowAndShrinkVerified: topVerticalOK,
            topLeftCornerDiagonalGrowAndShrinkVerified: topLeftDiagonalOK,
            minSizeAndScreenBoundsClampVerified: minBoundsOK,
            persistenceAcrossPadSwitchAndHideShowVerified: persistenceOK,
            midResizeHideCancelsSessionCleanlyVerified: midResizeHideTransitionOK,
            totalDragCases: cases.count,
            passedDragCases: passedCasesCount,
            passedAllChecks: allPassed,
            arrowReferenceSignature: arrowSig,
            cases: cases
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let outFile = outputDir.appendingPathComponent(reportFilename)
        try data.write(to: outFile, options: .atomic)
        print(outFile.path)

        if !allPassed {
            let failedNames = cases.filter { !$0.passed }.map(\.caseName).joined(separator: ", ")
            throw NSError(
                domain: "NativeOSWindowResizeAcceptance",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Native OS window resize acceptance failed (passedCases=\(passedCasesCount)/\(cases.count), interiorArrow=\(interiorArrowOK), persistence=\(persistenceOK), midResizeHide=\(midResizeHideTransitionOK); failedCases=[\(failedNames)])"]
            )
        }

        return report
    }
}
