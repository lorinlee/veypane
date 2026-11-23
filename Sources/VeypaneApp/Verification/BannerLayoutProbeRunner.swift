import AppKit
import SwiftUI
import WebKit
import VeypaneCore

/// Isolated acceptance fixture: no external sites, credentials, saved settings or display writes.
@MainActor
enum BannerLayoutProbeRunner {
    static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run(into: URL(fileURLWithPath: outputDirectoryPath, isDirectory: true))
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Banner layout fixture failed: \(error)\n".utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    private static func rect(_ r: NSRect) -> [String: Double] {
        ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
    }

    private static func run(into out: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let temp = fm.temporaryDirectory.appendingPathComponent("VeypaneBannerFixture-\(UUID())")
        defer { try? fm.removeItem(at: temp) }
        let store = VeypaneStore(directoryURL: temp)
        var state = WorkspaceState(pads: [])
        state.settings.hasCompletedOnboarding = true
        state.pads = []
        state.selectedPadID = nil
        try store.save(state)
        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        for _ in 0..<100 {
            if model.areExtensionsReady { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let pad = model.addPad(url: URL(string: "about:blank")!, title: "Local layout fixture", select: true)
        let wc = model.webController(for: pad)
        _ = await wc.ensureLoadedAndWaitUntilReady(timeoutSeconds: 5)
        wc.webView.loadHTMLString("<html><body style='margin:0;background:#e8f8ee'><button id='fixture' style='position:fixed;left:45%;top:8px;width:100px;height:36px'>Local control</button><p style='padding-top:65px'>Local UI geometry fixture, not Google.</p></body></html>", baseURL: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        var cases: [[String: Any]] = []
        for size in [NSSize(width: 420, height: 420), NSSize(width: 760, height: 600)] {
            let host = NSHostingView(rootView: PanelRootView(model: model, snapshotCompatibilityIssue: SiteCompatibilityIssueKind.none))
            let window = NSWindow(contentRect: NSRect(x: -15000, y: -15000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.alphaValue = 0.01
            window.ignoresMouseEvents = true
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            window.orderBack(nil)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 200_000_000)
            let noBanner = wc.webView.convert(wc.webView.bounds, to: host)
            host.rootView = PanelRootView(model: model, snapshotCompatibilityIssue: .verificationRouteObserved)
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(nanoseconds: 250_000_000)
            host.layoutSubtreeIfNeeded()
            let webFrame = wc.webView.convert(wc.webView.bounds, to: host)
            let nativePoint = NSPoint(x: wc.webView.bounds.midX, y: wc.webView.isFlipped ? 20 : wc.webView.bounds.height - 20)
            let hostPoint = wc.webView.convert(nativePoint, to: host)
            let hit = host.hitTest(hostPoint)
            let hitsWeb = hit.map { $0 === wc.webView || $0.isDescendant(of: wc.webView) } ?? false
            let delta = noBanner.height - webFrame.height
            let inside = host.bounds.insetBy(dx: -1, dy: -1).contains(webFrame)
            let pass = inside && hitsWeb && delta >= 20 && delta <= 40 && webFrame.height > 200
            cases.append(["window": ["width": size.width, "height": size.height], "webWithoutBanner": rect(noBanner), "webWithBanner": rect(webFrame), "bannerHeightDelta": delta, "topWebPointHitsWebKit": hitsWeb, "webFrameWithinHost": inside, "passed": pass])
            if let image = await UISnapshotRenderer.captureSnapshotImage(of: wc.webView, size: wc.webView.bounds.size, timeoutSeconds: 3) {
                try UISnapshotRenderer.renderSwiftUIViewToPNG(PanelRootView(model: model, snapshotWebImage: image, snapshotCompatibilityIssue: .verificationRouteObserved), size: size, to: out.appendingPathComponent("banner-\(Int(size.width)).png"))
            }
            wc.webView.removeFromSuperview()
            window.orderOut(nil)
        }
        let passed = cases.allSatisfy { $0["passed"] as? Bool == true }
        let report: [String: Any] = ["isolatedTemporaryStore": true, "publicWebsiteRequests": 0, "captchaInteraction": false, "displayWrites": false, "fixtureIsNotGoogle": true, "cases": cases, "passed": passed]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("results.json"))
        if !passed { throw NSError(domain: "VeypaneBannerFixture", code: 1) }
    }
}
