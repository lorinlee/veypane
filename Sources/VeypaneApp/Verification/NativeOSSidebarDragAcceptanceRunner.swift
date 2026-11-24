import ApplicationServices
import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI
import WebKit
import VeypaneCore

public struct NativeOSSidebarDragCaseResult: Codable, Sendable {
    public var caseName: String
    public var startAppKit: String
    public var endAppKit: String
    public var preActionPanelOnscreenConfirmed: Bool
    public var targetOwnedBySelfPIDConfirmed: Bool
    public var padCountBefore: Int
    public var padCountAfter: Int
    public var padIDsBefore: [String]
    public var padIDsAfter: [String]
    public var padTitlesBefore: [String]
    public var padTitlesAfter: [String]
    public var selectedPadIDBefore: String
    public var selectedPadIDAfter: String
    public var newlyCreatedPadURLs: [String]
    public var orderChanged: Bool
    public var expectedBehaviorSummary: String
    public var passed: Bool
}

public struct NativeOSSidebarDragAcceptanceReport: Codable, Sendable {
    public var generatedAt: Date
    public var headSourceUnderTest: String
    public var executionMode: String
    public var appIsRunningMainLoop: Bool
    public var axTrusted: Bool
    public var cgPostEventAccess: Bool
    public var isolatedTemporaryStore: Bool
    public var nonPersistentWebDataStore: Bool
    public var selfOwnedBackdropVerified: Bool
    public var singleClickSwitchesWithoutCreatingVerified: Bool
    public var shortDragNoNewPadVerified: Bool
    public var dragDownReordersWithoutCreatingVerified: Bool
    public var dragUpReordersWithoutCreatingVerified: Bool
    public var dragToBottomEmptyAreaNoNewPadVerified: Bool
    public var dragCancelEscapeNoNewPadVerified: Bool
    public var persistenceAcrossFreshModelReloadVerified: Bool
    public var initialPadIDs: [String]
    public var finalPadIDs: [String]
    public var reloadedPadIDs: [String]
    public var totalCases: Int
    public var passedCases: Int
    public var passedAllChecks: Bool
    public var cases: [NativeOSSidebarDragCaseResult]
}

/// Real OS `CGEvent` sidebar icon click & drag-to-reorder acceptance runner (`t329`).
/// Exercises the actual production `AppModel` + `SlideOverPanel` + `PanelRootView` + `SidebarStripView`
/// in an isolated temporary store with `WKWebsiteDataStore.nonPersistent()` over a self-owned backdrop window
/// under top-level `NSApplication.shared.run()`, restoring cursor + frontmost app on exit.
@MainActor
public enum NativeOSSidebarDragAcceptanceRunner {
    public static let defaultReportFilename = "native-os-sidebar-drag-acceptance.json"

    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        // Strict 60s watchdog so OS fixture can never hang
        DispatchQueue.global().asyncAfter(deadline: .now() + 60.0) {
            FileHandle.standardError.write(Data("Native OS sidebar drag acceptance timed out after 60s\n".utf8))
            Darwin.exit(2)
        }

        Task { @MainActor in
            do {
                let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
                _ = try await runAcceptance(
                    into: outDir,
                    executionMode: "Standalone AppKit NSApplication.run() process (--native-os-sidebar-drag-probe)"
                )
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Native OS sidebar drag acceptance failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    public static func runAcceptance(
        into outputDir: URL,
        reportFilename: String = defaultReportFilename,
        executionMode: String = "Standalone AppKit NSApplication.run() process (--native-os-sidebar-drag-probe)"
    ) async throws -> NativeOSSidebarDragAcceptanceReport {
        let app = NSApplication.shared
        guard app.isRunning else {
            throw NSError(
                domain: "NativeOSSidebarDragAcceptance",
                code: 9,
                userInfo: [NSLocalizedDescriptionKey: "NSApplication.shared.isRunning is false; execute via standalone VeypaneApp --native-os-sidebar-drag-probe <outputDir>."]
            )
        }

        let axTrusted = AXIsProcessTrusted()
        let postAccess = CGPreflightPostEventAccess()
        guard postAccess else {
            throw NSError(
                domain: "NativeOSSidebarDragAcceptance",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "CGPreflightPostEventAccess() is false; real OS CGEvent sidebar verification cannot run."]
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
            "VeypaneOSSidebarDragStore-\(UUID().uuidString)",
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
                domain: "NativeOSSidebarDragAcceptance",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Self-owned backdrop window did not become topmost; refusing to inject OS CGEvents."]
            )
        }

        let padA = Pad(title: "Alpha", hasCustomTitle: true, url: URL(string: "about:blank")!)
        let padB = Pad(title: "Beta", hasCustomTitle: true, url: URL(string: "about:blank")!)
        let padC = Pad(title: "Gamma", hasCustomTitle: true, url: URL(string: "about:blank")!)
        let padD = Pad(title: "Delta", hasCustomTitle: true, url: URL(string: "about:blank")!)
        let padE = Pad(title: "Epsilon", hasCustomTitle: true, url: URL(string: "about:blank")!)
        let initialPads = [padA, padB, padC, padD, padE]
        let initialPadIDSet = Set(initialPads.map { $0.id.uuidString })

        let store = VeypaneStore(directoryURL: tempStoreRoot)
        var initialState = WorkspaceState(pads: initialPads)
        initialState.selectedPadID = padA.id
        initialState.settings.hasCompletedOnboarding = true
        initialState.settings.isPinnedOpen = true
        initialState.settings.anchor = .right
        initialState.settings.widthPercent = 58.0
        initialState.settings.heightPercent = 66.0
        initialState.settings.animationDuration = 0.08
        initialState.settings.appearance.compactSidebar = false
        try store.save(initialState)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.startRuntimeServices {
            PanelRootView.makeHostingView(model: model)
        }
        defer { model.stopRuntimeServices() }

        guard let panel = model.panel else {
            throw NSError(domain: "NativeOSSidebarDragAcceptance", code: 12, userInfo: [NSLocalizedDescriptionKey: "Missing production SlideOverPanel"])
        }
        panel.reduceMotionOverride = false
        model.showPanel(activateFocus: true, openedFromEdge: false)
        try await Task.sleep(nanoseconds: 250_000_000)

        // Resolve real mounted AppKit screen coordinates from live `SidebarStripView` layout (`sidebarPadFramesInWindow`)
        let chromeMetrics = PanelChromeMetrics.forAppearance(model.state.settings.appearance)
        func iconCenterAppKit(index: Int) -> CGPoint {
            if model.state.pads.indices.contains(index),
               let rectInWin = model.sidebarPadFramesInWindow[model.state.pads[index].id] {
                let rectOnScreen = panel.convertToScreen(rectInWin)
                return CGPoint(x: rectOnScreen.midX, y: rectOnScreen.midY)
            }
            let f = panel.frame
            let ptInWin = chromeMetrics.fallbackPadCenterInWindow(index: index, panelHeight: f.height)
            return CGPoint(x: f.minX + ptInWin.x, y: f.minY + ptInWin.y)
        }

        func emptyBelowLastIconAppKit(padCount: Int) -> CGPoint {
            if let lastPad = model.state.pads.last,
               let lastRectInWin = model.sidebarPadFramesInWindow[lastPad.id] {
                let lastOnScreen = panel.convertToScreen(lastRectInWin)
                return CGPoint(x: lastOnScreen.midX, y: lastOnScreen.minY - 32.0)
            }
            let f = panel.frame
            let ptInWin = chromeMetrics.fallbackEmptyBelowLastPadInWindow(padCount: padCount, panelHeight: f.height)
            return CGPoint(x: f.minX + ptInWin.x, y: f.minY + ptInWin.y)
        }

        func postMove(_ pt: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: toCG(pt), mouseButton: .left)?.post(tap: .cghidEventTap)
        }

        func postMouse(_ type: CGEventType, _ pt: CGPoint) {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: toCG(pt), mouseButton: .left)?.post(tap: .cghidEventTap)
        }

        func postEscapeKey() {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: false)?.post(tap: .cghidEventTap)
        }

        func runCase(
            name: String,
            startAppKit: CGPoint,
            endAppKit: CGPoint,
            summary: String,
            action: () async throws -> Void,
            evaluate: ([Pad], [Pad], UUID?, UUID?) -> Bool
        ) async throws -> NativeOSSidebarDragCaseResult {
            let preOnscreen = isWindowOnscreen(panel.windowNumber) && panel.isVisible && model.isPanelVisible
            let ownerOK = (topOwnerPID(at: toCG(startAppKit)) == selfPID) && (topOwnerPID(at: toCG(endAppKit)) == selfPID)
            guard preOnscreen && ownerOK else {
                throw NSError(
                    domain: "NativeOSSidebarDragAcceptance",
                    code: 14,
                    userInfo: [NSLocalizedDescriptionKey: "Precondition failed in \(name): onscreen=\(preOnscreen), ownerOK=\(ownerOK)"]
                )
            }

            let padsBefore = model.state.pads
            let selectedBefore = model.state.selectedPadID
            let idsBeforeSet = Set(padsBefore.map(\.id))

            try await action()
            try await Task.sleep(nanoseconds: 180_000_000)

            let padsAfter = model.state.pads
            let selectedAfter = model.state.selectedPadID
            let newPads = padsAfter.filter { !idsBeforeSet.contains($0.id) }
            let orderChanged = padsBefore.map(\.id) != padsAfter.map(\.id)
            let passed = preOnscreen && ownerOK && evaluate(padsBefore, padsAfter, selectedBefore, selectedAfter)

            return NativeOSSidebarDragCaseResult(
                caseName: name,
                startAppKit: NSStringFromPoint(startAppKit),
                endAppKit: NSStringFromPoint(endAppKit),
                preActionPanelOnscreenConfirmed: preOnscreen,
                targetOwnedBySelfPIDConfirmed: ownerOK,
                padCountBefore: padsBefore.count,
                padCountAfter: padsAfter.count,
                padIDsBefore: padsBefore.map { $0.id.uuidString },
                padIDsAfter: padsAfter.map { $0.id.uuidString },
                padTitlesBefore: padsBefore.map(\.title),
                padTitlesAfter: padsAfter.map(\.title),
                selectedPadIDBefore: selectedBefore?.uuidString ?? "nil",
                selectedPadIDAfter: selectedAfter?.uuidString ?? "nil",
                newlyCreatedPadURLs: newPads.map(\.url.absoluteString),
                orderChanged: orderChanged,
                expectedBehaviorSummary: summary,
                passed: passed
            )
        }

        func performOSHoldDragRelease(from startPt: CGPoint, to endPt: CGPoint, steps: Int = 14, holdMs: UInt64 = 120, cancelEscape: Bool = false) async throws {
            postMove(startPt)
            try await Task.sleep(nanoseconds: 45_000_000)
            postMouse(.leftMouseDown, startPt)
            try await Task.sleep(nanoseconds: holdMs * 1_000_000)
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let cur = CGPoint(
                    x: startPt.x + (endPt.x - startPt.x) * t,
                    y: startPt.y + (endPt.y - startPt.y) * t
                )
                postMouse(.leftMouseDragged, cur)
                try await Task.sleep(nanoseconds: 22_000_000)
            }
            if cancelEscape {
                try await Task.sleep(nanoseconds: 40_000_000)
                postEscapeKey()
                try await Task.sleep(nanoseconds: 60_000_000)
            }
            postMouse(.leftMouseUp, endPt)
            try await Task.sleep(nanoseconds: 120_000_000)
        }

        var cases: [NativeOSSidebarDragCaseResult] = []

        // Case 1: Single click on icon index 3 ("Delta") switches selection without reordering or creating a pad
        let clickPt = iconCenterAppKit(index: 3)
        let c1 = try await runCase(
            name: "1_single_click_switches_pad",
            startAppKit: clickPt,
            endAppKit: clickPt,
            summary: "Single click switches active pad to Delta without reordering or adding a pad"
        ) {
            postMove(clickPt)
            try await Task.sleep(nanoseconds: 45_000_000)
            postMouse(.leftMouseDown, clickPt)
            try await Task.sleep(nanoseconds: 35_000_000)
            postMouse(.leftMouseUp, clickPt)
        } evaluate: { before, after, _, selAfter in
            after.count == before.count
                && after.map(\.id) == before.map(\.id)
                && selAfter == padD.id
        }
        cases.append(c1)

        // Case 2: Short-distance drag (~3pt) on icon index 1 ("Beta") never creates a new pad
        let shortStart = iconCenterAppKit(index: 1)
        let shortEnd = CGPoint(x: shortStart.x, y: shortStart.y - 3.0)
        let c2 = try await runCase(
            name: "2_short_drag_does_not_create_pad",
            startAppKit: shortStart,
            endAppKit: shortEnd,
            summary: "Short 3pt drag never creates a new pad and preserves exact pad IDs"
        ) {
            try await performOSHoldDragRelease(from: shortStart, to: shortEnd, steps: 3, holdMs: 60)
        } evaluate: { before, after, _, _ in
            after.count == before.count
                && after.map(\.id) == before.map(\.id)
        }
        cases.append(c2)

        // Case 3: Drag icon index 0 ("Alpha") DOWN onto icon index 3 ("Delta") -> reorders downward, zero new pads
        let downStart = iconCenterAppKit(index: 0)
        let downEnd = iconCenterAppKit(index: 3)
        let c3 = try await runCase(
            name: "3_drag_down_reorders_icon",
            startAppKit: downStart,
            endAppKit: downEnd,
            summary: "Hold+drag Alpha down onto index 3 moves Alpha down without creating any new pad"
        ) {
            try await performOSHoldDragRelease(from: downStart, to: downEnd, steps: 16, holdMs: 140)
        } evaluate: { before, after, _, _ in
            guard after.count == 5,
                  Set(after.map { $0.id.uuidString }) == initialPadIDSet,
                  let oldIdx = before.firstIndex(where: { $0.id == padA.id }),
                  let newIdx = after.firstIndex(where: { $0.id == padA.id }) else {
                return false
            }
            return newIdx > oldIdx && newIdx >= 2
        }
        cases.append(c3)

        // Case 4: Drag bottom icon (index 4, "Epsilon") UP onto icon index 1 -> reorders upward, zero new pads
        let upStart = iconCenterAppKit(index: 4)
        let upEnd = iconCenterAppKit(index: 1)
        let movingUpID = model.state.pads.indices.contains(4) ? model.state.pads[4].id : padE.id
        let c4 = try await runCase(
            name: "4_drag_up_reorders_icon",
            startAppKit: upStart,
            endAppKit: upEnd,
            summary: "Hold+drag bottom icon up onto index 1 moves it upward without creating any new pad"
        ) {
            try await performOSHoldDragRelease(from: upStart, to: upEnd, steps: 16, holdMs: 140)
        } evaluate: { before, after, _, _ in
            guard after.count == 5,
                  Set(after.map { $0.id.uuidString }) == initialPadIDSet,
                  let oldIdx = before.firstIndex(where: { $0.id == movingUpID }),
                  let newIdx = after.firstIndex(where: { $0.id == movingUpID }) else {
                return false
            }
            return newIdx < oldIdx && newIdx <= 1
        }
        cases.append(c4)

        // Case 5: Drag top icon (index 0) DOWN into empty sidebar space below the last icon -> moves to bottom, zero new pads
        let bottomStart = iconCenterAppKit(index: 0)
        let bottomEnd = emptyBelowLastIconAppKit(padCount: model.state.pads.count)
        let topIDBeforeCase5 = model.state.pads.first?.id
        let c5 = try await runCase(
            name: "5_drag_to_bottom_empty_sidebar_no_new_pad",
            startAppKit: bottomStart,
            endAppKit: bottomEnd,
            summary: "Hold+drag top icon into empty sidebar area below last icon moves it to end and NEVER creates a new tab/pad"
        ) {
            try await performOSHoldDragRelease(from: bottomStart, to: bottomEnd, steps: 18, holdMs: 140)
        } evaluate: { _, after, _, _ in
            guard after.count == 5,
                  Set(after.map { $0.id.uuidString }) == initialPadIDSet,
                  let topID = topIDBeforeCase5 else {
                return false
            }
            return after.last?.id == topID
        }
        cases.append(c5)

        // Case 6: Hold+drag icon index 2 then press Escape before release -> cancels cleanly, zero new pads, order unchanged
        let cancelStart = iconCenterAppKit(index: 2)
        let cancelEnd = iconCenterAppKit(index: 0)
        let c6 = try await runCase(
            name: "6_drag_cancel_with_escape_no_new_pad",
            startAppKit: cancelStart,
            endAppKit: cancelEnd,
            summary: "Dragging then pressing Escape cancels cleanly without creating pads or mutating order"
        ) {
            try await performOSHoldDragRelease(from: cancelStart, to: cancelEnd, steps: 12, holdMs: 140, cancelEscape: true)
        } evaluate: { before, after, _, _ in
            after.count == before.count
                && after.map(\.id) == before.map(\.id)
        }
        cases.append(c6)

        // Persistence verification: reload from the exact same temporary store into a fresh AppModel
        let finalPadIDs = model.state.pads.map { $0.id.uuidString }
        let freshModel = AppModel(store: VeypaneStore(directoryURL: tempStoreRoot), allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        let reloadedPadIDs = freshModel.state.pads.map { $0.id.uuidString }
        let persistenceOK = (reloadedPadIDs == finalPadIDs)
            && (reloadedPadIDs.count == 5)
            && (Set(reloadedPadIDs) == initialPadIDSet)
            && (reloadedPadIDs != initialPads.map { $0.id.uuidString })

        let passedCount = cases.filter(\.passed).count
        let allPassed = backdropOK
            && c1.passed
            && c2.passed
            && c3.passed
            && c4.passed
            && c5.passed
            && c6.passed
            && persistenceOK
            && (passedCount == cases.count)

        let report = NativeOSSidebarDragAcceptanceReport(
            generatedAt: Date(),
            headSourceUnderTest: "Production AppModel + SlideOverPanel + PanelRootView + SidebarStripView",
            executionMode: executionMode,
            appIsRunningMainLoop: app.isRunning,
            axTrusted: axTrusted,
            cgPostEventAccess: postAccess,
            isolatedTemporaryStore: true,
            nonPersistentWebDataStore: true,
            selfOwnedBackdropVerified: backdropOK,
            singleClickSwitchesWithoutCreatingVerified: c1.passed,
            shortDragNoNewPadVerified: c2.passed,
            dragDownReordersWithoutCreatingVerified: c3.passed,
            dragUpReordersWithoutCreatingVerified: c4.passed,
            dragToBottomEmptyAreaNoNewPadVerified: c5.passed,
            dragCancelEscapeNoNewPadVerified: c6.passed,
            persistenceAcrossFreshModelReloadVerified: persistenceOK,
            initialPadIDs: initialPads.map { $0.id.uuidString },
            finalPadIDs: finalPadIDs,
            reloadedPadIDs: reloadedPadIDs,
            totalCases: cases.count,
            passedCases: passedCount,
            passedAllChecks: allPassed,
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
                domain: "NativeOSSidebarDragAcceptance",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Native OS sidebar drag acceptance failed (passedCases=\(passedCount)/\(cases.count), persistence=\(persistenceOK); failedCases=[\(failedNames)])"]
            )
        }

        return report
    }
}
