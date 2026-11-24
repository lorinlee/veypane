import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import WebKit
import VeypaneCore

public struct NativeOSOutsideClickSample: Codable, Sendable {
    public var ms: Int
    public var isPanelVisibleModel: Bool
    public var panelWindowVisible: Bool
    public var windowServerOnscreen: Bool
    public var transitionPhase: String
    public var panelFrame: String
}

public struct NativeOSOutsideClickCaseResult: Codable, Sendable {
    public var caseName: String
    public var sourceUnderTest: String
    public var injectionLevel: String
    public var actions: String
    public var preClickPanelOnscreenConfirmed: Bool
    public var expectedDismiss: Bool
    public var observedDismissed: Bool
    public var eventsObservedDelta: Int
    public var dismissalsTriggeredDelta: Int
    public var lastDecisionSummary: String
    public var passed: Bool
    public var samples: [NativeOSOutsideClickSample]
}

public struct NativeOSOutsideClickAcceptanceReport: Codable, Sendable {
    public var generatedAt: Date
    public var executionContext: String
    public var appIsRunningMainLoop: Bool
    public var axTrusted: Bool
    public var cgPostEventAccess: Bool
    public var monitorBackend: String
    public var isolatedTemporaryStore: Bool
    public var nonPersistentWebDataStore: Bool
    public var totalCases: Int
    public var passedCases: Int
    public var passedAllChecks: Bool
    public var cases: [NativeOSOutsideClickCaseResult]
}

/// Portable, self-contained real OS `CGEvent` mouse acceptance runner (`t304`).
/// Dynamically spawns a minimal empty helper window in `FileManager.default.temporaryDirectory`,
/// verifies target window ownership in `CGWindowListCopyWindowInfo` before every `CGEvent` post,
/// confirms pre-click `onscreen == true` panel visibility in WindowServer, and restores cursor +
/// frontmost application on exit. Never inspects titles/URLs/DOM of external applications.
@MainActor
public enum NativeOSOutsideClickAcceptanceRunner {
    public static let defaultReportFilename = "native-os-outside-click-acceptance.json"

    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Strict 55s watchdog so OS fixture can never hang
        DispatchQueue.global().asyncAfter(deadline: .now() + 55.0) {
            FileHandle.standardError.write(Data("Native OS outside-click acceptance timed out after 55s\n".utf8))
            Darwin.exit(2)
        }

        Task { @MainActor in
            do {
                let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
                _ = try await runAcceptance(
                    into: outDir,
                    executionContext: "Standalone AppKit NSApplication.run() process (--native-os-outside-click-probe)"
                )
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Native OS outside-click acceptance failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    public static func runAcceptance(
        into outputDir: URL,
        reportFilename: String = defaultReportFilename,
        executionContext: String = "Opt-in XCTest / Swift Testing (VEYPANE_RUN_OS_MOUSE_TESTS=1)"
    ) async throws -> NativeOSOutsideClickAcceptanceReport {
        let axTrusted = AXIsProcessTrusted()
        let postAccess = CGPreflightPostEventAccess()
        guard postAccess else {
            throw NSError(
                domain: "NativeOSOutsideClickAcceptance",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "CGPreflightPostEventAccess() is false; real OS CGEvent mouse injection is unavailable in this session."]
            )
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if !app.isRunning {
            app.finishLaunching()
        }

        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let screenFrame = NSScreen.screens.first?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visFrame = NSScreen.screens.first?.visibleFrame ?? screenFrame
        func toCG(_ appKitPoint: CGPoint) -> CGPoint {
            CGPoint(x: appKitPoint.x, y: screenFrame.height - appKitPoint.y)
        }

        let helperAppKitRect = CGRect(
            x: round(visFrame.minX + 36),
            y: round(visFrame.midY - 140),
            width: 260,
            height: 260
        )
        let safeOutsideCG = toCG(CGPoint(x: helperAppKitRect.midX, y: helperAppKitRect.midY))

        let savedFrontApp = NSWorkspace.shared.frontmostApplication
        let initialMouseCG = CGEvent(source: nil)?.location ?? CGPoint(x: screenFrame.midX, y: screenFrame.midY)

        let fixtureTempDir = fm.temporaryDirectory.appendingPathComponent(
            "VeypaneNativeOSOutsideClick-\(UUID().uuidString)",
            isDirectory: true
        )
        try fm.createDirectory(at: fixtureTempDir, withIntermediateDirectories: true)

        // Generate self-contained external target helper script in temporaryDirectory (zero hardcoded paths)
        let helperScriptURL = fixtureTempDir.appendingPathComponent("external_click_target_fixture.swift")
        let helperSource = """
        import AppKit
        import Foundation

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let win = NSWindow(
            contentRect: NSRect(x: \(Int(helperAppKitRect.origin.x)), y: \(Int(helperAppKitRect.origin.y)), width: \(Int(helperAppKitRect.width)), height: \(Int(helperAppKitRect.height))),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        win.title = "VeypaneExternalClickTargetFixture"
        win.backgroundColor = .underPageBackgroundColor
        win.isReleasedWhenClosed = false
        win.level = .normal
        win.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 35.0) { Darwin.exit(0) }
        app.run()
        """
        try helperSource.write(to: helperScriptURL, atomically: true, encoding: .utf8)

        let helperProc = Process()
        helperProc.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        helperProc.arguments = [helperScriptURL.path]
        try helperProc.run()

        defer {
            if helperProc.isRunning {
                helperProc.terminate()
            }
            CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: initialMouseCG,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
            savedFrontApp?.activate()
            try? fm.removeItem(at: fixtureTempDir)
        }

        let helperPID = Int(helperProc.processIdentifier)
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

        func isWindowOnscreenInWindowServer(_ windowNumber: Int) -> Bool {
            guard windowNumber > 0,
                  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
                return false
            }
            return list.contains { entry in
                (entry[kCGWindowNumber as String] as? Int) == windowNumber
                    && ((entry[kCGWindowIsOnscreen as String] as? Bool) ?? true)
            }
        }

        let helperDeadline = Date().addingTimeInterval(8.0)
        while topOwnerPID(at: safeOutsideCG) != helperPID && Date() < helperDeadline {
            try await Task.sleep(nanoseconds: 80_000_000)
        }
        guard topOwnerPID(at: safeOutsideCG) == helperPID else {
            throw NSError(
                domain: "NativeOSOutsideClickAcceptance",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Controlled external helper window (PID \(helperPID)) did not become topmost at \(safeOutsideCG); refusing to post CGEvent click."]
            )
        }

        let storeDir = fixtureTempDir.appendingPathComponent("store", isDirectory: true)
        let store = VeypaneStore(directoryURL: storeDir)
        var initialState = WorkspaceState(pads: [
            Pad(title: "Synthetic Acceptance Pad", url: URL(string: "about:blank")!)
        ])
        initialState.settings.hasCompletedOnboarding = true
        initialState.settings.isPinnedOpen = false
        initialState.settings.animationDuration = 0.20
        try store.save(initialState)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.startRuntimeServices {
            NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        }
        defer { model.stopRuntimeServices() }

        guard let pad = model.selectedPad else {
            throw NSError(domain: "NativeOSOutsideClickAcceptance", code: 12, userInfo: [NSLocalizedDescriptionKey: "Missing synthetic pad"])
        }
        let wc = model.webController(for: pad)
        wc.webView.loadHTMLString(
            "<!doctype html><html><body style='margin:0'><input id='inp' style='width:320px;height:64px' value='seed'></body></html>",
            baseURL: nil
        )
        if let cv = model.panel?.contentView {
            wc.webView.removeFromSuperview()
            wc.webView.frame = cv.bounds
            cv.addSubview(wc.webView)
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        let t0 = DispatchTime.now().uptimeNanoseconds
        func nowMs() -> Int { Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000) }
        func sample() -> NativeOSOutsideClickSample {
            let winNum = model.panel?.windowNumber ?? 0
            return NativeOSOutsideClickSample(
                ms: nowMs(),
                isPanelVisibleModel: model.isPanelVisible,
                panelWindowVisible: model.panel?.isVisible ?? false,
                windowServerOnscreen: isWindowOnscreenInWindowServer(winNum),
                transitionPhase: model.diagnostics.transitionPhase.rawValue,
                panelFrame: NSStringFromRect(model.panel?.frame ?? .zero)
            )
        }

        func postVerifiedClick(at cgPt: CGPoint, expectedPID: Int, rightButton: Bool = false) throws {
            CGEvent(
                mouseEventSource: nil,
                mouseType: .mouseMoved,
                mouseCursorPosition: cgPt,
                mouseButton: .left
            )?.post(tap: .cghidEventTap)
            usleep(25_000)
            let actualPID = topOwnerPID(at: cgPt)
            guard actualPID == expectedPID else {
                throw NSError(
                    domain: "NativeOSOutsideClickAcceptance",
                    code: 13,
                    userInfo: [NSLocalizedDescriptionKey: "Safety check aborted click at \(cgPt): expected owner PID \(expectedPID), found \(actualPID)"]
                )
            }
            let downType: CGEventType = rightButton ? .rightMouseDown : .leftMouseDown
            let upType: CGEventType = rightButton ? .rightMouseUp : .leftMouseUp
            let btn: CGMouseButton = rightButton ? .right : .left
            CGEvent(mouseEventSource: nil, mouseType: downType, mouseCursorPosition: cgPt, mouseButton: btn)?.post(tap: .cghidEventTap)
            usleep(35_000)
            CGEvent(mouseEventSource: nil, mouseType: upType, mouseCursorPosition: cgPt, mouseButton: btn)?.post(tap: .cghidEventTap)
        }

        func waitUntilFullyVisible(timeoutMs: UInt64 = 700) async -> Bool {
            let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMs * 1_000_000
            while (!model.isPanelVisible
                || model.panel?.isVisible != true
                || model.transitionController.phase != .visible
                || !isWindowOnscreenInWindowServer(model.panel?.windowNumber ?? 0))
                && DispatchTime.now().uptimeNanoseconds < deadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            return model.isPanelVisible
                && model.panel?.isVisible == true
                && isWindowOnscreenInWindowServer(model.panel?.windowNumber ?? 0)
        }

        func waitUntilFullyHidden(timeoutMs: UInt64 = 750) async -> Bool {
            let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMs * 1_000_000
            while (model.isPanelVisible
                || model.panel?.isVisible == true
                || model.transitionController.phase != .hidden)
                && DispatchTime.now().uptimeNanoseconds < deadline {
                try? await Task.sleep(nanoseconds: 30_000_000)
            }
            return !model.isPanelVisible
                && model.panel?.isVisible != true
                && model.transitionController.phase == .hidden
        }

        func decisionSummary(_ dec: OutsideClickDecision?) -> String {
            guard let dec else { return "nil" }
            return String(describing: dec)
        }

        var results: [NativeOSOutsideClickCaseResult] = []

        // Case 1 (repeated 3x): Hotkey/status-item/CLI show (`openedFromEdge: false`, pointer outside) -> real OS left-click on external helper PID
        for rep in 1...3 {
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: safeOutsideCG, mouseButton: .left)?.post(tap: .cghidEventTap)
            model.showPanel(activateFocus: true, openedFromEdge: false)
            let preOnscreen = await waitUntilFullyVisible()
            var samples = [sample()]
            let obsBefore = model.outsideClickEventsObserved
            let disBefore = model.outsideClickDismissalsTriggered
            try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
            for _ in 0..<4 {
                try await Task.sleep(nanoseconds: 65_000_000)
                samples.append(sample())
            }
            let hidden = await waitUntilFullyHidden()
            samples.append(sample())
            let obsDelta = model.outsideClickEventsObserved - obsBefore
            let disDelta = model.outsideClickDismissalsTriggered - disBefore
            results.append(NativeOSOutsideClickCaseResult(
                caseName: "1_hotkey_or_status_show_then_external_app_click_rep_\(rep)",
                sourceUnderTest: "Production AppModel + OutsideClickEventMonitor (\(model.outsideClickMonitorBackend))",
                injectionLevel: "Real OS CGEvent(.leftMouseDown/.leftMouseUp) onto external helper PID \(helperPID) at CG \(safeOutsideCG)",
                actions: "showPanel(openedFromEdge: false), confirm onscreen in WindowServer, OS left-click external window, verify hidden",
                preClickPanelOnscreenConfirmed: preOnscreen,
                expectedDismiss: true,
                observedDismissed: hidden,
                eventsObservedDelta: obsDelta,
                dismissalsTriggeredDelta: disDelta,
                lastDecisionSummary: decisionSummary(model.lastOutsideClickDecision),
                passed: preOnscreen && hidden && obsDelta >= 1 && disDelta >= 1,
                samples: samples
            ))
        }

        // Case 2: External right-click (`CGEvent(.rightMouseDown/.rightMouseUp)`) dismisses panel
        model.showPanel(activateFocus: true, openedFromEdge: false)
        let c2Pre = await waitUntilFullyVisible()
        var s2 = [sample()]
        let c2Obs0 = model.outsideClickEventsObserved
        let c2Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID, rightButton: true)
        let c2Hidden = await waitUntilFullyHidden()
        s2.append(sample())
        // Dismiss any context menu on helper by moving slightly & pressing Escape? No, helper plain NSView has no context menu.
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "2_external_app_right_click_dismisses",
            sourceUnderTest: "Production AppModel + OutsideClickEventMonitor",
            injectionLevel: "Real OS CGEvent(.rightMouseDown/.rightMouseUp) onto external helper PID \(helperPID)",
            actions: "showPanel(openedFromEdge: false), confirm onscreen, OS right-click external window, verify hidden",
            preClickPanelOnscreenConfirmed: c2Pre,
            expectedDismiss: true,
            observedDismissed: c2Hidden,
            eventsObservedDelta: model.outsideClickEventsObserved - c2Obs0,
            dismissalsTriggeredDelta: model.outsideClickDismissalsTriggered - c2Dis0,
            lastDecisionSummary: decisionSummary(model.lastOutsideClickDecision),
            passed: c2Pre && c2Hidden && (model.outsideClickDismissalsTriggered - c2Dis0) >= 1,
            samples: s2
        ))

        // Case 3: Edge show -> real OS outside click -> cursor moves back inside panel bounds within 120ms -> stays dismissed
        model.showPanel(activateFocus: true, openedFromEdge: true)
        let c3Pre = await waitUntilFullyVisible()
        let panelCenterCG = toCG(CGPoint(x: (model.panel?.frame ?? .zero).midX, y: (model.panel?.frame ?? .zero).midY))
        var s3 = [sample()]
        let c3Obs0 = model.outsideClickEventsObserved
        let c3Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        try await Task.sleep(nanoseconds: 100_000_000)
        s3.append(sample())
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: panelCenterCG, mouseButton: .left)?.post(tap: .cghidEventTap)
        let c3Hidden = await waitUntilFullyHidden()
        s3.append(sample())
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "3_edge_show_outside_click_then_cursor_returns_within_120ms",
            sourceUnderTest: "Production AppModel + OutsideClickEventMonitor",
            injectionLevel: "Real OS CGEvent left-click at \(safeOutsideCG) + mouseMoved to \(panelCenterCG) at +100ms",
            actions: "showPanel(openedFromEdge: true), OS click external window, return cursor to panel center at +100ms, verify hidden",
            preClickPanelOnscreenConfirmed: c3Pre,
            expectedDismiss: true,
            observedDismissed: c3Hidden,
            eventsObservedDelta: model.outsideClickEventsObserved - c3Obs0,
            dismissalsTriggeredDelta: model.outsideClickDismissalsTriggered - c3Dis0,
            lastDecisionSummary: decisionSummary(model.lastOutsideClickDecision),
            passed: c3Pre && c3Hidden && (model.outsideClickDismissalsTriggered - c3Dis0) >= 1,
            samples: s3
        ))

        // Case 4: Hot-edge trigger disabled (`edgeTrigger.isEnabled = false`) -> OS outside click still dismisses immediately
        model.state.settings.edgeTrigger.isEnabled = false
        model.showPanel(activateFocus: true, openedFromEdge: false)
        let c4Pre = await waitUntilFullyVisible()
        var s4 = [sample()]
        let c4Obs0 = model.outsideClickEventsObserved
        let c4Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        let c4Hidden = await waitUntilFullyHidden()
        s4.append(sample())
        model.state.settings.edgeTrigger.isEnabled = true
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "4_edge_trigger_disabled_external_click_dismisses",
            sourceUnderTest: "Production AppModel + OutsideClickEventMonitor",
            injectionLevel: "Real OS CGEvent left-click onto external helper PID \(helperPID) with edgeTrigger.isEnabled=false",
            actions: "disable edgeTrigger, showPanel, OS click external window, verify hidden",
            preClickPanelOnscreenConfirmed: c4Pre,
            expectedDismiss: true,
            observedDismissed: c4Hidden,
            eventsObservedDelta: model.outsideClickEventsObserved - c4Obs0,
            dismissalsTriggeredDelta: model.outsideClickDismissalsTriggered - c4Dis0,
            lastDecisionSummary: decisionSummary(model.lastOutsideClickDecision),
            passed: c4Pre && c4Hidden && (model.outsideClickDismissalsTriggered - c4Dis0) >= 1,
            samples: s4
        ))

        // Case 5: Mid-animation outside click (`70ms` into `200ms` slide-in, `phase == .showing`) -> immediate reversal to `.hidden`
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: safeOutsideCG, mouseButton: .left)?.post(tap: .cghidEventTap)
        model.showPanel(activateFocus: true, openedFromEdge: true)
        try await Task.sleep(nanoseconds: 70_000_000)
        let c5OnscreenMidAnim = isWindowOnscreenInWindowServer(model.panel?.windowNumber ?? 0) && (model.panel?.isVisible == true)
        let c5WasShowing = (model.transitionController.phase == .showing)
        var s5 = [sample()]
        let c5Obs0 = model.outsideClickEventsObserved
        let c5Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        let c5Hidden = await waitUntilFullyHidden()
        s5.append(sample())
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "5_mid_animation_outside_click_at_70ms",
            sourceUnderTest: "Production AppModel + PanelTransitionController + OutsideClickEventMonitor",
            injectionLevel: "Real OS CGEvent left-click at \(safeOutsideCG) 70ms into 200ms slide-in animation (phase=showing)",
            actions: "showPanel, wait 70ms (confirm phase==showing & onscreen), OS click external window, verify mid-flight reversal to hidden",
            preClickPanelOnscreenConfirmed: c5OnscreenMidAnim,
            expectedDismiss: true,
            observedDismissed: c5Hidden,
            eventsObservedDelta: model.outsideClickEventsObserved - c5Obs0,
            dismissalsTriggeredDelta: model.outsideClickDismissalsTriggered - c5Dis0,
            lastDecisionSummary: decisionSummary(model.lastOutsideClickDecision),
            passed: c5OnscreenMidAnim && c5WasShowing && c5Hidden && (model.outsideClickDismissalsTriggered - c5Dis0) >= 1,
            samples: s5
        ))

        // Case 6: Same-app `Settings` window positioned outside `SlideOverPanel` -> real OS click on `Settings` dismisses `SlideOverPanel`
        model.showPanel(activateFocus: true, openedFromEdge: false)
        let c6Pre = await waitUntilFullyVisible()
        model.openSettingsWindow()
        if let sw = model.activeSettingsWindow {
            sw.setFrame(helperAppKitRect, display: true)
            sw.orderFrontRegardless()
        }
        let settingsWait = Date().addingTimeInterval(2.0)
        while topOwnerPID(at: safeOutsideCG) != selfPID && Date() < settingsWait {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        var s6 = [sample()]
        let c6Obs0 = model.outsideClickEventsObserved
        let c6Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: safeOutsideCG, expectedPID: selfPID)
        let c6Hidden = await waitUntilFullyHidden()
        s6.append(sample())
        model.activeSettingsWindow?.orderOut(nil)
        // Restore helper window as front external target at `safeOutsideCG`
        NSRunningApplication(processIdentifier: pid_t(helperPID))?.activate()
        let restoreWait = Date().addingTimeInterval(2.0)
        while topOwnerPID(at: safeOutsideCG) != helperPID && Date() < restoreWait {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let c6DisDelta = model.outsideClickDismissalsTriggered - c6Dis0
        let c6EffectiveDecision: OutsideClickDecision? = (c6DisDelta >= 1 && model.lastOutsideClickDecision == .keepOpen(.panelNotVisible))
            ? model.lastOutsideClickDismissalDecision
            : model.lastOutsideClickDecision
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "6_same_app_settings_window_real_os_click_dismisses",
            sourceUnderTest: "Production AppModel + Settings NSWindow + OutsideClickEventMonitor",
            injectionLevel: "Real OS CGEvent left-click onto Veypane Settings NSWindow (selfPID \(selfPID)) outside SlideOverPanel",
            actions: "showPanel, openSettingsWindow at left of screen, OS click Settings window, verify SlideOverPanel dismisses",
            preClickPanelOnscreenConfirmed: c6Pre,
            expectedDismiss: true,
            observedDismissed: c6Hidden,
            eventsObservedDelta: model.outsideClickEventsObserved - c6Obs0,
            dismissalsTriggeredDelta: c6DisDelta,
            lastDecisionSummary: decisionSummary(c6EffectiveDecision),
            passed: c6Pre && c6Hidden && c6DisDelta >= 1 && (model.lastOutsideClickDismissalDecision == .dismissPanel(.sameApplicationOtherWindowClick)),
            samples: s6
        ))

        // Case 7: Real OS click INSIDE Veypane's own synthetic non-persistent webpage keeps panel open
        model.showPanel(activateFocus: true, openedFromEdge: false)
        let c7Pre = await waitUntilFullyVisible()
        let pFrame = model.panel?.frame ?? .zero
        let insideCG = toCG(CGPoint(x: pFrame.minX + 140, y: pFrame.maxY - 40))
        var s7 = [sample()]
        let c7Obs0 = model.outsideClickEventsObserved
        let c7Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: insideCG, expectedPID: selfPID)
        for _ in 0..<5 {
            try await Task.sleep(nanoseconds: 65_000_000)
            s7.append(sample())
        }
        let c7StayedOpen = model.isPanelVisible && (model.panel?.isVisible == true)
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "7_inside_panel_synthetic_webpage_click_keeps_open",
            sourceUnderTest: "Production AppModel + SlideOverPanel + synthetic WKWebView",
            injectionLevel: "Real OS CGEvent left-click inside SlideOverPanel at CG \(insideCG) (selfPID \(selfPID))",
            actions: "showPanel, OS click inside synthetic webpage input, observe 325ms, verify panel stays open",
            preClickPanelOnscreenConfirmed: c7Pre,
            expectedDismiss: false,
            observedDismissed: !c7StayedOpen,
            eventsObservedDelta: model.outsideClickEventsObserved - c7Obs0,
            dismissalsTriggeredDelta: model.outsideClickDismissalsTriggered - c7Dis0,
            lastDecisionSummary: decisionSummary(model.lastOutsideClickDecision),
            passed: c7Pre && c7StayedOpen && (model.outsideClickEventsObserved - c7Obs0) >= 1 && (model.lastOutsideClickDecision == .keepOpen(.insidePanelWindow)),
            samples: s7
        ))

        // Case 8: High-level non-menu utility window (`level = popUpMenu + 3`, simulating Tooltip / TUINSWindow) does NOT block OS outside-click dismissal
        let dummyHighWin = NSWindow(
            contentRect: NSRect(x: -14000, y: -14000, width: 80, height: 24),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        dummyHighWin.isReleasedWhenClosed = false
        dummyHighWin.level = NSWindow.Level(rawValue: NSWindow.Level.popUpMenu.rawValue + 3)
        dummyHighWin.orderFrontRegardless()
        let c8Pre = isWindowOnscreenInWindowServer(model.panel?.windowNumber ?? 0) && model.isPanelVisible
        let c8PopupFalsePositive = model.hasActivePopupMenuWindow()
        var s8 = [sample()]
        let c8Obs0 = model.outsideClickEventsObserved
        let c8Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        let c8Hidden = await waitUntilFullyHidden()
        s8.append(sample())
        dummyHighWin.orderOut(nil)
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "8_high_level_tooltip_or_textinput_window_does_not_block_dismissal",
            sourceUnderTest: "Production AppModel.hasActivePopupMenuWindow() + OutsideClickEventMonitor",
            injectionLevel: "Real OS CGEvent left-click on external helper PID \(helperPID) while visible non-menu NSWindow at level=104 exists",
            actions: "orderFront non-menu utility window at level=popUpMenu+3, OS click external window, verify panel dismisses",
            preClickPanelOnscreenConfirmed: c8Pre,
            expectedDismiss: true,
            observedDismissed: c8Hidden,
            eventsObservedDelta: model.outsideClickEventsObserved - c8Obs0,
            dismissalsTriggeredDelta: model.outsideClickDismissalsTriggered - c8Dis0,
            lastDecisionSummary: decisionSummary(model.lastOutsideClickDecision),
            passed: c8Pre && !c8PopupFalsePositive && c8Hidden,
            samples: s8
        ))

        // Case 9: `isPinnedOpen` + `isAlwaysOnTop` real OS click lifecycle (pinned stays open -> unpin + OS click dismisses)
        model.state.settings.isAlwaysOnTop = true
        model.state.settings.isPinnedOpen = true
        model.showPanel(activateFocus: true, openedFromEdge: false)
        let c9Pre = await waitUntilFullyVisible()
        var s9 = [sample()]
        let c9Obs0 = model.outsideClickEventsObserved
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        for _ in 0..<4 {
            try await Task.sleep(nanoseconds: 65_000_000)
            s9.append(sample())
        }
        let c9StayedPinned = model.isPanelVisible && (model.panel?.isVisible == true) && (model.lastOutsideClickDecision == .keepOpen(.panelPinnedOpen))
        model.state.settings.isPinnedOpen = false
        let c9Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        let c9HiddenAfterUnpin = await waitUntilFullyHidden()
        s9.append(sample())
        model.state.settings.isAlwaysOnTop = false
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "9_pinned_and_always_on_top_real_os_click_lifecycle",
            sourceUnderTest: "Production AppModel (isAlwaysOnTop + isPinnedOpen) + OutsideClickEventMonitor",
            injectionLevel: "Real OS CGEvent left-clicks on external helper PID \(helperPID)",
            actions: "enable isAlwaysOnTop+isPinnedOpen, OS click external window (stays open), set isPinnedOpen=false, OS click external window (dismisses)",
            preClickPanelOnscreenConfirmed: c9Pre,
            expectedDismiss: true,
            observedDismissed: c9HiddenAfterUnpin,
            eventsObservedDelta: model.outsideClickEventsObserved - c9Obs0,
            dismissalsTriggeredDelta: model.outsideClickDismissalsTriggered - c9Dis0,
            lastDecisionSummary: decisionSummary(model.lastOutsideClickDecision),
            passed: c9Pre && c9StayedPinned && c9HiddenAfterUnpin && (model.outsideClickDismissalsTriggered - c9Dis0) >= 1,
            samples: s9
        ))

        // Case 10: Child popover window & attached modal sheet real OS click exceptions
        model.showPanel(activateFocus: true, openedFromEdge: false)
        let c10Pre = await waitUntilFullyVisible()
        let pRect10 = model.panel?.frame ?? .zero
        let childAppKitRect = CGRect(x: round(pRect10.midX - 90), y: round(pRect10.midY - 60), width: 180, height: 120)
        let childWin = NSWindow(contentRect: childAppKitRect, styleMask: [.borderless], backing: .buffered, defer: false)
        childWin.isReleasedWhenClosed = false
        childWin.backgroundColor = .windowBackgroundColor
        if let panel = model.panel {
            panel.addChildWindow(childWin, ordered: .above)
        }
        childWin.orderFrontRegardless()
        try await Task.sleep(nanoseconds: 80_000_000)
        let childCG = toCG(CGPoint(x: childAppKitRect.midX, y: childAppKitRect.midY))
        var s10 = [sample()]
        let c10Obs0 = model.outsideClickEventsObserved
        try postVerifiedClick(at: childCG, expectedPID: selfPID)
        try await Task.sleep(nanoseconds: 150_000_000)
        let c10ChildKept = model.isPanelVisible && (model.lastOutsideClickDecision == .keepOpen(.insideChildOrPopoverWindow))
        if let panel = model.panel {
            panel.removeChildWindow(childWin)
        }
        childWin.orderOut(nil)

        // Attach a real AppKit sheet to `panel` -> external OS click + >450ms hover outside BOTH keep panel open -> endSheet + external OS click dismisses
        let sheetWin = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 120), styleMask: [.titled], backing: .buffered, defer: false)
        sheetWin.isReleasedWhenClosed = false
        model.panel?.beginSheet(sheetWin) { _ in }
        try await Task.sleep(nanoseconds: 120_000_000)
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        try await Task.sleep(nanoseconds: 460_000_000)
        s10.append(sample())
        let c10SheetKept = model.isPanelVisible && (model.lastOutsideClickDecision == .keepOpen(.activeModalOrSheetOrFileDialog))
        if let panel = model.panel {
            panel.endSheet(sheetWin)
        }
        sheetWin.orderOut(nil)
        try await Task.sleep(nanoseconds: 60_000_000)
        let c10Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        let c10HiddenAfterSheet = await waitUntilFullyHidden()
        let c10DisDelta = model.outsideClickDismissalsTriggered - c10Dis0
        s10.append(sample())
        let c10EffectiveDecision: OutsideClickDecision? = (c10DisDelta >= 1 && model.lastOutsideClickDecision == .keepOpen(.panelNotVisible))
            ? model.lastOutsideClickDismissalDecision
            : model.lastOutsideClickDecision
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "10_child_popover_and_attached_sheet_real_os_click_exceptions",
            sourceUnderTest: "Production AppModel + child NSWindow + beginSheet + OutsideClickEventMonitor",
            injectionLevel: "Real OS CGEvent left-clicks on child popover (\(childCG)) and external helper (\(safeOutsideCG))",
            actions: "OS click child popover (keeps open), attach real NSWindow sheet + OS click external window + wait 460ms (keeps open), endSheet + OS click external window (dismisses via OutsideClickEventMonitor)",
            preClickPanelOnscreenConfirmed: c10Pre,
            expectedDismiss: true,
            observedDismissed: c10HiddenAfterSheet,
            eventsObservedDelta: model.outsideClickEventsObserved - c10Obs0,
            dismissalsTriggeredDelta: c10DisDelta,
            lastDecisionSummary: decisionSummary(c10EffectiveDecision),
            passed: c10Pre && c10ChildKept && c10SheetKept && c10HiddenAfterSheet && c10DisDelta >= 1 && (model.lastOutsideClickDismissalDecision == .dismissPanel(.externalClick)),
            samples: s10
        ))

        // Case 11: Ephemeral child OAuth popup (`window.open` -> `EphemeralPopupWindowController`) real OS click exception
        model.showPanel(activateFocus: true, openedFromEdge: false)
        let c11Pre = await waitUntilFullyVisible()
        model.forceOffscreenPopupWindows = true
        _ = try? await wc.evaluateLimitedScript("window.__osAcceptPop = window.open('about:blank', 'oauthOSAccept', 'width=400,height=420'); ''")
        try await Task.sleep(nanoseconds: 150_000_000)
        let c11PopupActive = !model.ephemeralPopups.isEmpty
        var s11 = [sample()]
        let c11Obs0 = model.outsideClickEventsObserved
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        try await Task.sleep(nanoseconds: 180_000_000)
        s11.append(sample())
        let c11PopupKept = c11PopupActive && model.isPanelVisible && (model.lastOutsideClickDecision == .keepOpen(.activeEphemeralChildPopup))
        model.closeAllEphemeralPopups()
        model.forceOffscreenPopupWindows = false
        let c11Dis0 = model.outsideClickDismissalsTriggered
        try postVerifiedClick(at: safeOutsideCG, expectedPID: helperPID)
        let c11HiddenAfterPopup = await waitUntilFullyHidden()
        s11.append(sample())
        results.append(NativeOSOutsideClickCaseResult(
            caseName: "11_ephemeral_oauth_child_popup_real_os_click_exception",
            sourceUnderTest: "Production AppModel + EphemeralPopupWindowController + OutsideClickEventMonitor",
            injectionLevel: "Real OS CGEvent left-clicks on external helper PID \(helperPID)",
            actions: "spawn window.open child popup, OS click external window (keeps opener open), close popup, OS click external window (dismisses)",
            preClickPanelOnscreenConfirmed: c11Pre,
            expectedDismiss: true,
            observedDismissed: c11HiddenAfterPopup,
            eventsObservedDelta: model.outsideClickEventsObserved - c11Obs0,
            dismissalsTriggeredDelta: model.outsideClickDismissalsTriggered - c11Dis0,
            lastDecisionSummary: decisionSummary(model.lastOutsideClickDecision),
            passed: c11Pre && c11PopupKept && c11HiddenAfterPopup,
            samples: s11
        ))

        let passedCount = results.filter(\.passed).count
        let allPassed = (passedCount == results.count) && !results.isEmpty
        let report = NativeOSOutsideClickAcceptanceReport(
            generatedAt: Date(),
            executionContext: executionContext,
            appIsRunningMainLoop: app.isRunning,
            axTrusted: axTrusted,
            cgPostEventAccess: postAccess,
            monitorBackend: model.outsideClickMonitorBackend,
            isolatedTemporaryStore: true,
            nonPersistentWebDataStore: true,
            totalCases: results.count,
            passedCases: passedCount,
            passedAllChecks: allPassed,
            cases: results
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let outFile = outputDir.appendingPathComponent(reportFilename)
        try data.write(to: outFile, options: .atomic)
        print(outFile.path)

        if !allPassed {
            let failedNames = results.filter { !$0.passed }.map(\.caseName).joined(separator: ", ")
            throw NSError(
                domain: "NativeOSOutsideClickAcceptance",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed real OS outside-click acceptance cases (\(results.count - passedCount)/\(results.count)): \(failedNames)"]
            )
        }

        return report
    }
}
