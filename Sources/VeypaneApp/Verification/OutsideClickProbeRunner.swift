import AppKit
import Foundation
import WebKit
import VeypaneCore

public struct OutsideClickProbeReport: Codable, Sendable {
    public var generatedAt: Date
    public var isolatedTemporaryStore: Bool
    public var nonPersistentWebDataStore: Bool
    public var injectionLevel: String
    public var firstAndRepeatedShowExternalClickDismissVerified: Bool
    public var hotkeyOrStatusShowWithoutHoverExternalClickDismissVerified: Bool
    public var edgeTriggerDisabledExternalClickDismissVerified: Bool
    public var midAnimationShowExternalClickReversalVerified: Bool
    public var rapidShowHideBurstCoherenceVerified: Bool
    public var sameAppSettingsAndWelcomeWindowClickDismissVerified: Bool
    public var insidePanelAndSyntheticWebInputClickKeepsOpenVerified: Bool
    public var pinnedPanelStaysOpenThenUnpinDismissesVerified: Bool
    public var alwaysOnTopUnpinnedDismissesAndPinnedStaysOpenVerified: Bool
    public var childPopoverSheetMenuInspectorAndOAuthPopupKeepOpenVerified: Bool
    public var triggerMarginDismissSuppressesImmediateRetriggerVerified: Bool
    public var passedAllChecks: Bool
}

/// Bounded isolated `--outside-click-probe <outputDir>` verification runner (`t304`).
/// Uses an isolated temporary directory and `WKWebsiteDataStore.nonPersistent()`, never touching
/// `AppModel.shared`, saved workspace files, or private windows, with a strict 45-second watchdog.
@MainActor
public enum OutsideClickProbeRunner {
    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Hard 45s watchdog so probe can never hang
        DispatchQueue.global().asyncAfter(deadline: .now() + 45.0) {
            FileHandle.standardError.write(Data("Outside-click probe timed out after 45s\n".utf8))
            Darwin.exit(2)
        }

        Task { @MainActor in
            do {
                let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
                try await runProbe(into: outDir)
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Outside-click probe failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    private static func waitUntilHidden(_ model: AppModel, timeoutMs: UInt64 = 700) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMs * 1_000_000
        while (model.isPanelVisible || model.panel?.isVisible == true || model.transitionController.phase != .hidden)
            && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return !model.isPanelVisible
            && model.panel?.isVisible != true
            && model.transitionController.phase == .hidden
    }

    private static func waitUntilVisible(_ model: AppModel, timeoutMs: UInt64 = 700) async -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutMs * 1_000_000
        while (!model.isPanelVisible || model.panel?.isVisible != true || model.transitionController.phase != .visible)
            && DispatchTime.now().uptimeNanoseconds < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return model.isPanelVisible
            && model.panel?.isVisible == true
            && model.transitionController.phase == .visible
    }

    public static func runProbe(into outputDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let tempDir = fm.temporaryDirectory.appendingPathComponent("VeypaneOutsideClickProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        let store = VeypaneStore(directoryURL: tempDir)
        var initial = WorkspaceState(pads: [
            Pad(title: "Synthetic Pad", url: URL(string: "about:blank")!)
        ])
        initial.settings.hasCompletedOnboarding = true
        initial.settings.animationDuration = 0.14
        initial.settings.isPinnedOpen = false
        try store.save(initial)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.forceOffscreenPopupWindows = true
        model.simulatedDisplaysOverride = [
            DisplayDescriptor(
                id: 1,
                name: "Synthetic 1080p",
                frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                visibleFrame: CGRect(x: 0, y: 40, width: 1920, height: 1016),
                isMain: true
            )
        ]
        model.startRuntimeServices {
            let root = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
            return root
        }
        model.panel?.alphaValue = 0.01
        model.panel?.ignoresMouseEvents = true
        defer { model.stopRuntimeServices() }

        let pad = try {
            guard let p = model.selectedPad else {
                throw NSError(domain: "OutsideClickProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing synthetic pad"])
            }
            return p
        }()
        let wc = model.webController(for: pad)
        wc.webView.loadHTMLString("<!doctype html><html><body><input id='f' value='seed'></body></html>", baseURL: nil)
        if let contentView = model.panel?.contentView {
            wc.webView.removeFromSuperview()
            wc.webView.frame = contentView.bounds
            contentView.addSubview(wc.webView)
        }
        try await Task.sleep(nanoseconds: 250_000_000)

        let externalPt = CGPoint(x: 180, y: 500)

        // 1 & 2. First & 3x repeated show (both hotkey/status `openedFromEdge: false` and edge `openedFromEdge: true`) -> external click dismisses immediately
        var repeatedOK = true
        var noHoverShowOK = true
        for idx in 0..<3 {
            let fromEdge = (idx % 2 == 1)
            model.showPanel(activateFocus: true, openedFromEdge: fromEdge)
            let shown = await waitUntilVisible(model)
            let dec = model.handlePointerDownForOutsideDismissal(
                origin: .externalApplicationOrDesktop,
                screenLocation: externalPt
            )
            let hidden = await waitUntilHidden(model)
            if !shown || !dec.shouldDismiss || !hidden {
                repeatedOK = false
                if !fromEdge { noHoverShowOK = false }
            }
        }

        // 3. Hot-edge trigger disabled (`edgeTrigger.isEnabled = false`) -> external click still dismisses
        model.state.settings.edgeTrigger.isEnabled = false
        model.showPanel(activateFocus: true, openedFromEdge: false)
        _ = await waitUntilVisible(model)
        let disabledDec = model.handlePointerDownForOutsideDismissal(
            origin: .externalApplicationOrDesktop,
            screenLocation: externalPt
        )
        let disabledHidden = await waitUntilHidden(model)
        let edgeDisabledOK = disabledDec.shouldDismiss && disabledHidden
        model.state.settings.edgeTrigger.isEnabled = true

        // 4. Mid-animation outside click (`transitionController.phase == .showing` at 40ms into 140ms slide-in)
        model.showPanel(activateFocus: true, openedFromEdge: true)
        try await Task.sleep(nanoseconds: 40_000_000)
        let wasShowingMidFlight = (model.transitionController.phase == .showing)
        let midDec = model.handlePointerDownForOutsideDismissal(
            origin: .externalApplicationOrDesktop,
            screenLocation: externalPt
        )
        let midHidden = await waitUntilHidden(model)
        let midAnimOK = wasShowingMidFlight
            && (midDec == .dismissPanel(.midAnimationExternalClick))
            && midHidden

        // 5. Rapid show/hide + outside-click bursts settle cleanly in `.hidden`
        for _ in 0..<6 {
            model.showPanel(activateFocus: true, openedFromEdge: false)
            try await Task.sleep(nanoseconds: 15_000_000)
            _ = model.handlePointerDownForOutsideDismissal(
                origin: .externalApplicationOrDesktop,
                screenLocation: externalPt
            )
        }
        let rapidBurstOK = await waitUntilHidden(model)

        // 6. Same-app other window (`Settings` & `Welcome`) click dismisses unpinned panel
        model.showPanel(activateFocus: true, openedFromEdge: false)
        _ = await waitUntilVisible(model)
        model.openSettingsWindow()
        model.activeSettingsWindow?.alphaValue = 0.01
        let settingsOrigin = model.classifyLocalMouseWindow(model.activeSettingsWindow, screenLocation: CGPoint(x: 600, y: 400))
        let settingsDec = model.handlePointerDownForOutsideDismissal(origin: settingsOrigin, screenLocation: CGPoint(x: 600, y: 400))
        let settingsHidden = await waitUntilHidden(model)
        let settingsDismissed = (settingsOrigin == .sameApplicationOtherStandardWindow)
            && settingsDec.shouldDismiss
            && settingsHidden
        model.activeSettingsWindow?.orderOut(nil)

        model.showPanel(activateFocus: true, openedFromEdge: false)
        _ = await waitUntilVisible(model)
        model.openWelcomeWindow()
        model.activeWelcomeWindow?.alphaValue = 0.01
        let welcomeOrigin = model.classifyLocalMouseWindow(model.activeWelcomeWindow, screenLocation: CGPoint(x: 600, y: 400))
        let welcomeDec = model.handlePointerDownForOutsideDismissal(origin: welcomeOrigin, screenLocation: CGPoint(x: 600, y: 400))
        let welcomeHidden = await waitUntilHidden(model)
        let welcomeDismissed = (welcomeOrigin == .sameApplicationOtherStandardWindow)
            && welcomeDec.shouldDismiss
            && welcomeHidden
        model.activeWelcomeWindow?.orderOut(nil)
        let sameAppOtherWinOK = settingsDismissed && welcomeDismissed

        // 7. Inside-panel click + synthetic `<input>` focus/edit keeps panel open
        model.showPanel(activateFocus: true, openedFromEdge: true)
        _ = await waitUntilVisible(model)
        let insideOrigin = model.classifyLocalMouseWindow(model.panel, screenLocation: CGPoint(x: 1000, y: 500))
        let insideDec = model.handlePointerDownForOutsideDismissal(origin: insideOrigin, screenLocation: CGPoint(x: 1000, y: 500))
        _ = try? await wc.evaluateLimitedScript("var el=document.getElementById('f'); el.focus(); el.value='typed-inside'; el.value;")
        let typedVal = (try? await wc.evaluateLimitedScript("document.getElementById('f').value")) ?? ""
        let insideKeepOpenOK = (insideOrigin == .sameApplicationPanel)
            && (insideDec == .keepOpen(.insidePanelWindow))
            && model.isPanelVisible
            && (typedVal == "typed-inside")

        // 8. Legitimate Exception: Pinned panel (`isPinnedOpen == true`) stays open on external & Settings clicks, then unpin + click dismisses
        model.state.settings.isPinnedOpen = true
        let pinnedExtDec = model.handlePointerDownForOutsideDismissal(origin: .externalApplicationOrDesktop, screenLocation: externalPt)
        let pinnedSameAppDec = model.handlePointerDownForOutsideDismissal(origin: .sameApplicationOtherStandardWindow, screenLocation: externalPt)
        let stayedOpenWhenPinned = (pinnedExtDec == .keepOpen(.panelPinnedOpen))
            && (pinnedSameAppDec == .keepOpen(.panelPinnedOpen))
            && model.isPanelVisible
        model.state.settings.isPinnedOpen = false
        let unpinnedDec = model.handlePointerDownForOutsideDismissal(origin: .externalApplicationOrDesktop, screenLocation: externalPt)
        let unpinnedHidden = await waitUntilHidden(model)
        let pinnedLifecycleOK = stayedOpenWhenPinned && unpinnedDec.shouldDismiss && unpinnedHidden

        // 9. `isAlwaysOnTop == true` (`.statusBar` level): dismisses when unpinned, stays open when pinned
        model.state.settings.isAlwaysOnTop = true
        model.showPanel(activateFocus: true, openedFromEdge: false)
        _ = await waitUntilVisible(model)
        let hasStatusBarLevel = (model.panel?.level == .statusBar)
        model.state.settings.isPinnedOpen = true
        let aotPinnedDec = model.handlePointerDownForOutsideDismissal(origin: .externalApplicationOrDesktop, screenLocation: externalPt)
        let aotPinnedKept = (aotPinnedDec == .keepOpen(.panelPinnedOpen)) && model.isPanelVisible
        model.state.settings.isPinnedOpen = false
        let aotUnpinnedDec = model.handlePointerDownForOutsideDismissal(origin: .externalApplicationOrDesktop, screenLocation: externalPt)
        let aotUnpinnedHidden = await waitUntilHidden(model)
        let aotLifecycleOK = hasStatusBarLevel && aotPinnedKept && aotUnpinnedDec.shouldDismiss && aotUnpinnedHidden
        model.state.settings.isAlwaysOnTop = false

        // 10. Legitimate Exceptions: Child popover, attached sheet/modal/file dialog, popup menu/status bar, Web Inspector, and child OAuth popup
        model.showPanel(activateFocus: true, openedFromEdge: false)
        _ = await waitUntilVisible(model)

        // 10a. Child window / popover attached to `panel`
        let childWin = NSWindow(contentRect: NSRect(x: -14800, y: -14800, width: 220, height: 140), styleMask: [.borderless], backing: .buffered, defer: false)
        childWin.isReleasedWhenClosed = false
        childWin.alphaValue = 0.01
        if let panel = model.panel {
            panel.addChildWindow(childWin, ordered: .above)
        }
        let childOrigin = model.classifyLocalMouseWindow(childWin, screenLocation: childWin.frame.origin)
        let childKeepOK = (childOrigin == .sameApplicationPanelChildOrPopover)
            && (model.handlePointerDownForOutsideDismissal(origin: childOrigin) == .keepOpen(.insideChildOrPopoverWindow))
            && model.isPanelVisible
        if let panel = model.panel {
            panel.removeChildWindow(childWin)
        }
        childWin.orderOut(nil)

        // 10b. Active modal / sheet / file upload dialog (`NSOpenPanel`)
        model.simulatedModalOrFileDialogActiveForTesting = true
        let modalKeepOK = (model.handlePointerDownForOutsideDismissal(origin: .externalApplicationOrDesktop, screenLocation: externalPt) == .keepOpen(.activeModalOrSheetOrFileDialog))
            && model.isPanelVisible
        model.simulatedModalOrFileDialogActiveForTesting = false

        // 10c. Active popup context/toolbar menu & status item window
        model.simulatedMenuOpenForTesting = true
        let menuKeepOK = (model.handlePointerDownForOutsideDismissal(origin: .externalApplicationOrDesktop, screenLocation: externalPt) == .keepOpen(.activeMenuOrStatusItemWindow))
            && model.isPanelVisible
        model.simulatedMenuOpenForTesting = false

        // 10d. Detached Web Inspector window
        let inspectorWin = NSWindow(contentRect: NSRect(x: -14600, y: -14600, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        inspectorWin.isReleasedWhenClosed = false
        inspectorWin.title = "Web Inspector — Synthetic"
        let inspectorOrigin = model.classifyLocalMouseWindow(inspectorWin, screenLocation: inspectorWin.frame.origin)
        let inspectorKeepOK = (inspectorOrigin == .sameApplicationInspectorWindow)
            && (model.handlePointerDownForOutsideDismissal(origin: inspectorOrigin) == .keepOpen(.activeInspectorWindow))
            && model.isPanelVisible
        inspectorWin.orderOut(nil)

        // 10e. Active ephemeral child OAuth popup (`EphemeralPopupWindowController`)
        let popupCfg = WKWebViewConfiguration()
        popupCfg.websiteDataStore = .nonPersistent()
        _ = try? await wc.evaluateLimitedScript("window.__probePop = window.open('about:blank', 'oauthProbe', 'width=400,height=420'); ''")
        try await Task.sleep(nanoseconds: 120_000_000)
        let oauthPopupPresent = !model.ephemeralPopups.isEmpty
        let oauthKeepOK = oauthPopupPresent
            && (model.handlePointerDownForOutsideDismissal(origin: .externalApplicationOrDesktop, screenLocation: externalPt) == .keepOpen(.activeEphemeralChildPopup))
            && model.isPanelVisible
        model.closeAllEphemeralPopups()

        // Once all exceptions are closed, outside click dismisses immediately
        let postExceptionDec = model.handlePointerDownForOutsideDismissal(origin: .externalApplicationOrDesktop, screenLocation: externalPt)
        let postExceptionHidden = await waitUntilHidden(model)
        let postExceptionDismissOK = postExceptionDec.shouldDismiss && postExceptionHidden
        let exceptionsOK = childKeepOK && modalKeepOK && menuKeepOK && inspectorKeepOK && oauthKeepOK && postExceptionDismissOK

        // 11. Trigger-margin dismiss suppresses immediate edge re-trigger until cursor leaves trigger zone
        var engine = EdgeTriggerEngine()
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let card = PanelGeometry.visibleFrame(screenVisibleFrame: screen, anchor: .right, defaultWidthPercent: 66, defaultHeightPercent: 76, edgeInset: 14)
        engine.setPanelVisible(true, pointerAlreadyInside: true)
        engine.setPanelVisible(false, pointerAlreadyInside: false, requireTriggerExitBeforeReshow: true)
        let edgePt = PointerContext(location: CGPoint(x: 1919, y: 500), timestamp: 10.0, screenFrame: screen, visiblePanelFrame: card)
        let d1 = engine.evaluate(context: edgePt, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100))
        var edgePtLater = edgePt
        edgePtLater.timestamp = 10.5
        let d2 = engine.evaluate(context: edgePtLater, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100))
        // Now cursor leaves trigger zone (`x = 1800`) and re-enters (`x = 1919`) -> re-arms normally!
        let exitPt = PointerContext(location: CGPoint(x: 1800, y: 500), timestamp: 11.0, screenFrame: screen, visiblePanelFrame: card)
        _ = engine.evaluate(context: exitPt, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100))
        var reenterStart = edgePt
        reenterStart.timestamp = 12.0
        _ = engine.evaluate(context: reenterStart, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100))
        var reenterDone = edgePt
        reenterDone.timestamp = 12.2
        let d3 = engine.evaluate(context: reenterDone, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100))
        let triggerMarginGuardOK = (d1 == .none) && (d2 == .none) && (d3 == .showPanel)

        let allPassed = repeatedOK
            && noHoverShowOK
            && edgeDisabledOK
            && midAnimOK
            && rapidBurstOK
            && sameAppOtherWinOK
            && insideKeepOpenOK
            && pinnedLifecycleOK
            && aotLifecycleOK
            && exceptionsOK
            && triggerMarginGuardOK

        let report = OutsideClickProbeReport(
            generatedAt: Date(),
            isolatedTemporaryStore: true,
            nonPersistentWebDataStore: true,
            injectionLevel: "Synthetic production-handler & AppKit window routing (AppModel.classifyLocalMouseWindow + handlePointerDownForOutsideDismissal; NOT real OS mouse input — genuine OS CGEvent verification is recorded separately in native-os-outside-click-acceptance.json)",
            firstAndRepeatedShowExternalClickDismissVerified: repeatedOK,
            hotkeyOrStatusShowWithoutHoverExternalClickDismissVerified: noHoverShowOK,
            edgeTriggerDisabledExternalClickDismissVerified: edgeDisabledOK,
            midAnimationShowExternalClickReversalVerified: midAnimOK,
            rapidShowHideBurstCoherenceVerified: rapidBurstOK,
            sameAppSettingsAndWelcomeWindowClickDismissVerified: sameAppOtherWinOK,
            insidePanelAndSyntheticWebInputClickKeepsOpenVerified: insideKeepOpenOK,
            pinnedPanelStaysOpenThenUnpinDismissesVerified: pinnedLifecycleOK,
            alwaysOnTopUnpinnedDismissesAndPinnedStaysOpenVerified: aotLifecycleOK,
            childPopoverSheetMenuInspectorAndOAuthPopupKeepOpenVerified: exceptionsOK,
            triggerMarginDismissSuppressesImmediateRetriggerVerified: triggerMarginGuardOK,
            passedAllChecks: allPassed
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let outFile = outputDir.appendingPathComponent("outside-click-probe.json")
        try data.write(to: outFile, options: .atomic)
        print(outFile.path)
        if !allPassed {
            throw NSError(
                domain: "VeypaneOutsideClickProbe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "One or more outside-click matrix checks failed; inspect outside-click-probe.json"]
            )
        }
    }
}
