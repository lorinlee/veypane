import AppKit
import Foundation
import SwiftUI
import WebKit
import VeypaneCore

public struct InteractionProbeReport: Codable, Sendable {
    public var appName: String
    public var bundleIdentifier: String
    public var initialPadCount: Int
    public var switchIterations: Int
    public var showHideCycles: Int
    public var rapidInterruptedCycles: Int
    public var webViewCreationsInitial: Int
    public var webViewCreationsAfterSwitchesAndTransitions: Int
    public var loadRequestsInitial: Int
    public var loadRequestsAfterSwitchesAndTransitions: Int
    public var reloadRequestsAfterSwitchesAndTransitions: Int
    public var scrollYBefore: Double
    public var scrollYAfterSwitchesAndTransitions: Double
    public var scrollPreserved: Bool
    public var noExtraWebViewsOnSwitchOrShowHide: Bool
    public var noExtraLoadsOnSwitchOrShowHide: Bool
    public var titleBeforeSecondNavigation: String
    public var titleAfterSecondNavigation: String
    public var loadDeltaForSingleNavigation: Int
    public var titleAfterSPADocumentTitleMutation: String
    public var badgeAfterSPADocumentTitleMutation: Int?
    public var customRenamedTitlePreservedAfterDOMTitleChange: Bool
    public var finalDiagnostics: RuntimeDiagnosticsCounters
}

/// Isolated `--interaction-probe <outputDir>` runner using harmless local HTML test files in a temporary directory.
/// Never touches the user's `~/Library/Application Support/SlideCraft` workspace or extensions.
@MainActor
public enum InteractionProbeRunner {
    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            do {
                let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
                try await runProbe(into: outDir)
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Interaction probe failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }

        app.run()
    }

    public static func runProbe(into outputDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let tempRoot = fm.temporaryDirectory.appendingPathComponent("VeypaneInteractionProbe-\(UUID().uuidString)", isDirectory: true)
        let storeDir = tempRoot.appendingPathComponent("Store", isDirectory: true)
        let htmlDir = tempRoot.appendingPathComponent("Pages", isDirectory: true)
        try fm.createDirectory(at: htmlDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let page1URL = htmlDir.appendingPathComponent("pad1.html")
        let page1NextURL = htmlDir.appendingPathComponent("pad1-next.html")
        let page2URL = htmlDir.appendingPathComponent("pad2.html")
        let page3URL = htmlDir.appendingPathComponent("pad3.html")

        try Data("""
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Alpha Initial Document</title></head>
        <body style="margin:0;padding:24px;height:3600px;font-family:-apple-system,sans-serif;">
          <h1>Alpha Pad</h1>
          <div style="margin-top:640px;" id="marker">Scroll Marker 640</div>
        </body></html>
        """.utf8).write(to: page1URL)

        try Data("""
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Alpha Second Navigation Title</title></head>
        <body style="margin:0;padding:24px;font-family:-apple-system,sans-serif;">
          <h1>Second Page</h1>
        </body></html>
        """.utf8).write(to: page1NextURL)

        try Data("""
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Beta Reference Document</title></head>
        <body style="margin:0;padding:24px;height:2400px;font-family:-apple-system,sans-serif;">
          <h1>Beta Pad</h1>
        </body></html>
        """.utf8).write(to: page2URL)

        try Data("""
        <!doctype html>
        <html><head><meta charset="utf-8"><title>Gamma Workspace Document</title></head>
        <body style="margin:0;padding:24px;height:2400px;font-family:-apple-system,sans-serif;">
          <h1>Gamma Pad</h1>
        </body></html>
        """.utf8).write(to: page3URL)

        let store = VeypaneStore(directoryURL: storeDir)
        let profiles = BrowserProfile.defaultProfiles()
        let pads = [
            Pad(title: "pad1", url: page1URL, profileID: profiles.first?.id),
            Pad(title: "pad2", url: page2URL, profileID: profiles.first?.id),
            Pad(title: "pad3", url: page3URL, profileID: profiles.first?.id)
        ]
        var state = WorkspaceState(
            pads: pads,
            selectedPadID: pads[0].id,
            activeProfileID: profiles.first?.id,
            profiles: profiles
        )
        state.settings.hasCompletedOnboarding = true
        state.settings.animationDuration = 0.08
        try store.save(state)

        let model = AppModel(store: store, allowExtensionPrompts: false)

        // Host PanelRootView offscreen at (-14000, -14000) so no visible window appears on the Mac's display
        let hostWindow = NSWindow(
            contentRect: NSRect(x: -14000, y: -14000, width: 1080, height: 740),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.isReleasedWhenClosed = false
        hostWindow.alphaValue = 0.01
        hostWindow.ignoresMouseEvents = true
        let hostingView = NSHostingView(rootView: PanelRootView(model: model))
        hostingView.frame = NSRect(x: 0, y: 0, width: 1080, height: 740)
        hostWindow.contentView = hostingView
        hostWindow.orderBack(nil)
        defer { hostWindow.orderOut(nil) }

        // Warm up all 3 pads once and wait for initial loads to settle
        for pad in model.state.pads {
            model.selectPad(pad.id)
            let wc = model.webController(for: pad)
            _ = await wc.ensureLoadedAndWaitUntilReady(timeoutSeconds: 5.0)
        }
        model.selectPad(pads[0].id)
        hostingView.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)

        let pad1WC = model.webController(for: model.state.pads[0])
        _ = try? await pad1WC.evaluateLimitedScript("window.scrollTo(0, 640); window.scrollY")
        try? await Task.sleep(nanoseconds: 120_000_000)
        let scrollBeforeStr = (try? await pad1WC.evaluateLimitedScript("window.scrollY")) ?? "0"
        let scrollBefore = Double(scrollBeforeStr) ?? 0

        let creationsInitial = model.diagnostics.webViewCreations
        let loadsInitial = model.diagnostics.loadRequests

        // 1. Exercise 50 pad switches across the 3 live pads
        let padIDs = model.state.pads.map(\.id)
        let switchIterations = 50
        for step in 0..<switchIterations {
            let nextID = padIDs[(step + 1) % padIDs.count]
            model.selectPad(nextID)
            hostingView.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        model.selectPad(padIDs[0])
        hostingView.layoutSubtreeIfNeeded()

        // 2. Exercise 20 show/hide cycles (14 settled + 6 rapid interrupted reversals)
        for cycle in 0..<20 {
            model.showPanel(activateFocus: false, openedFromEdge: false)
            if cycle < 6 {
                // Rapid reversal before transition completes
                model.hidePanel()
                model.showPanel(activateFocus: false, openedFromEdge: false)
                model.hidePanel()
            } else {
                model.hidePanel()
            }
        }
        model.showPanel(activateFocus: false, openedFromEdge: false)
        try? await Task.sleep(nanoseconds: 120_000_000)

        let creationsAfter = model.diagnostics.webViewCreations
        let loadsAfter = model.diagnostics.loadRequests
        let reloadsAfter = model.diagnostics.reloadRequests
        let scrollAfterStr = (try? await pad1WC.evaluateLimitedScript("window.scrollY")) ?? "0"
        let scrollAfter = Double(scrollAfterStr) ?? 0

        // 3. Verify non-custom title updates on second navigation AND single load count delta
        let titleBeforeNav2 = model.state.pads[0].title
        let loadsBeforeNav2 = model.diagnostics.loadRequests
        model.navigatePad(id: padIDs[0], to: page1NextURL)
        _ = await pad1WC.ensureLoadedAndWaitUntilReady(timeoutSeconds: 5.0)
        try? await Task.sleep(nanoseconds: 200_000_000)
        let loadsAfterNav2 = model.diagnostics.loadRequests
        let titleAfterNav2 = model.state.pads[0].title

        // 4. Verify SPA dynamic `document.title` mutation updates title + unread badge
        _ = try? await pad1WC.evaluateLimitedScript("document.title = '(4) Dynamic SPA Title'; document.title")
        try? await Task.sleep(nanoseconds: 220_000_000)
        let titleAfterSPA = model.state.pads[0].title
        let badgeAfterSPA = model.state.pads[0].badgeCount

        // 5. Verify hand-renamed pad (`hasCustomTitle == true`) preserves user title across DOM title changes
        let pad2ID = padIDs[1]
        model.renamePad(pad2ID, newTitle: "Hand Renamed Space")
        let pad2WC = model.webController(for: model.state.pads[1])
        _ = try? await pad2WC.evaluateLimitedScript("document.title = '(2) Overwrite Attempt'; document.title")
        try? await Task.sleep(nanoseconds: 200_000_000)
        let pad2After = model.state.pads[1]
        let customPreserved = (pad2After.title == "Hand Renamed Space" && pad2After.hasCustomTitle && pad2After.badgeCount == 2)

        model.writeLiveUIState()
        let finalDiag = (try? store.readUIState().diagnostics) ?? model.diagnostics

        let report = InteractionProbeReport(
            appName: AppBrandIdentity.productName,
            bundleIdentifier: AppBrandIdentity.bundleIdentifier,
            initialPadCount: padIDs.count,
            switchIterations: switchIterations,
            showHideCycles: 20,
            rapidInterruptedCycles: 6,
            webViewCreationsInitial: creationsInitial,
            webViewCreationsAfterSwitchesAndTransitions: creationsAfter,
            loadRequestsInitial: loadsInitial,
            loadRequestsAfterSwitchesAndTransitions: loadsAfter,
            reloadRequestsAfterSwitchesAndTransitions: reloadsAfter,
            scrollYBefore: scrollBefore,
            scrollYAfterSwitchesAndTransitions: scrollAfter,
            scrollPreserved: abs(scrollAfter - scrollBefore) < 2.0,
            noExtraWebViewsOnSwitchOrShowHide: creationsAfter == creationsInitial,
            noExtraLoadsOnSwitchOrShowHide: loadsAfter == loadsInitial && reloadsAfter == 0,
            titleBeforeSecondNavigation: titleBeforeNav2,
            titleAfterSecondNavigation: titleAfterNav2,
            loadDeltaForSingleNavigation: loadsAfterNav2 - loadsBeforeNav2,
            titleAfterSPADocumentTitleMutation: titleAfterSPA,
            badgeAfterSPADocumentTitleMutation: badgeAfterSPA,
            customRenamedTitlePreservedAfterDOMTitleChange: customPreserved,
            finalDiagnostics: finalDiag
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let resultsFile = outputDir.appendingPathComponent("results.json")
        try data.write(to: resultsFile, options: .atomic)
        print(resultsFile.path)
    }
}
