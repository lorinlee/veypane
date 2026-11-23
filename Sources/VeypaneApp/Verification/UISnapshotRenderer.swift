import AppKit
import SwiftUI
import WebKit
import VeypaneCore

@MainActor
private final class SnapshotNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var completed = false

    func waitForFinish(on webView: WKWebView, url: URL, timeoutSeconds: TimeInterval) async -> Bool {
        webView.navigationDelegate = self
        completed = false

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            self.continuation = cont
            webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeoutSeconds))

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                self?.finish(success: false)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(success: true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(success: false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(success: false)
    }

    private func finish(success: Bool) {
        guard !completed else { return }
        completed = true
        let cont = continuation
        continuation = nil
        cont?.resume(returning: success)
    }
}

@MainActor
public enum UISnapshotRenderer {
    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            do {
                try await generateAllSnapshots(into: URL(fileURLWithPath: outputDirectoryPath, isDirectory: true))
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Snapshot error: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }

        app.run()
    }

    public static func generateAllSnapshots(into outputDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let tempStoreDir = fm.temporaryDirectory.appendingPathComponent("VeypaneSnapStore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempStoreDir) }

        let tempStore = VeypaneStore(directoryURL: tempStoreDir)
        let profiles = BrowserProfile.defaultProfiles()
        let samplePads: [Pad] = [
            Pad(
                title: "Example Domain",
                url: URL(string: "https://example.com")!,
                symbolName: "globe",
                profileID: profiles.first?.id
            ),
            Pad(
                title: "Wikipedia",
                url: URL(string: "https://www.wikipedia.org")!,
                symbolName: "book",
                profileID: profiles.first?.id
            ),
            Pad(
                title: "Hacker News",
                url: URL(string: "https://news.ycombinator.com")!,
                symbolName: "newspaper",
                profileID: profiles.first?.id,
                badgeCount: 3
            )
        ]

        var initialState = WorkspaceState(
            pads: samplePads,
            selectedPadID: samplePads.first?.id,
            activeProfileID: profiles.first?.id,
            profiles: profiles,
            recentHistory: [
                RecentHistoryEntry(title: "Swift Documentation", url: URL(string: "https://www.swift.org/documentation/")!),
                RecentHistoryEntry(title: "WebKit Blog", url: URL(string: "https://webkit.org")!)
            ]
        )
        initialState.settings.hasCompletedOnboarding = true
        try tempStore.save(initialState)

        let model = AppModel(store: tempStore, allowExtensionPrompts: false)

        // 1. Capture live example.com WKWebView snapshot offscreen (up to 15 s)
        let webSize = NSSize(width: 1020, height: 700)
        let webSnapshot = await captureExampleWebSnapshot(size: webSize, timeoutSeconds: 15.0)

        // 2. Render ours-panel.png & ours-panel-v5.png (normal existing page, NO permanent URL field!)
        let panelCardSize = NSSize(width: 1080, height: 740)
        model.cancelAddressBar()
        let panelBackdropView = ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.16, blue: 0.24),
                    Color(red: 0.08, green: 0.10, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            PanelRootView(model: model, snapshotWebImage: webSnapshot)
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .padding(16)
        }
        let panelFile = outputDir.appendingPathComponent("ours-panel.png")
        try renderViewToPNG(panelBackdropView, size: panelCardSize, to: panelFile)
        print(panelFile.path)

        let panelV5File = outputDir.appendingPathComponent("ours-panel-v5.png")
        try renderViewToPNG(panelBackdropView, size: panelCardSize, to: panelV5File)
        print(panelV5File.path)

        // 2b. Render ours-address-editor-v5.png (transient ⌘L floating omnibox overlay)
        if let pad = model.selectedPad {
            model.addressBarState.revealForCurrentPad(padID: pad.id, currentURL: pad.url)
        }
        let addressEditorBackdrop = ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.16, blue: 0.24),
                    Color(red: 0.08, green: 0.10, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            PanelRootView(model: model, snapshotWebImage: webSnapshot)
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .padding(16)
        }
        let addressEditorFile = outputDir.appendingPathComponent("ours-address-editor-v5.png")
        try renderViewToPNG(addressEditorBackdrop, size: panelCardSize, to: addressEditorFile)
        print(addressEditorFile.path)
        model.cancelAddressBar()

        // 3. Render ours-add-pad.png & ours-add-pad-v5.png
        let addPadContainer = ZStack {
            Color(nsColor: .windowBackgroundColor)
            AddPadPopoverView(model: model, initialQuery: "") {}
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor))
                        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                )
                .padding(16)
        }
        let addPadFile = outputDir.appendingPathComponent("ours-add-pad.png")
        try renderViewToPNG(addPadContainer, size: NSSize(width: 360, height: 340), to: addPadFile)
        print(addPadFile.path)

        let addPadV5File = outputDir.appendingPathComponent("ours-add-pad-v5.png")
        try renderViewToPNG(addPadContainer, size: NSSize(width: 360, height: 340), to: addPadV5File)
        print(addPadV5File.path)

        // Optional E5: If VEYPANE_SNAPSHOT_EXTENSION (or legacy SLIDECRAFT_SNAPSHOT_EXTENSION)=<folder> is set, install into tempStore,
        // run live Wikipedia page through the extension (up to 30 s), and render ours-panel-extension.png
        let rawExtEnv = (ProcessInfo.processInfo.environment["VEYPANE_SNAPSHOT_EXTENSION"] ?? ProcessInfo.processInfo.environment["SLIDECRAFT_SNAPSHOT_EXTENSION"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let rawExtEnv, !rawExtEnv.isEmpty {
            try await renderExtensionSnapshotsAndProbe(
                extensionSourcePath: (rawExtEnv as NSString).expandingTildeInPath,
                model: model,
                webSize: webSize,
                panelCardSize: panelCardSize,
                outputDir: outputDir
            )
        }

        // 4. Render ours-settings-v5.png + ours-settings-<pane>.png for every Settings pane
        model.state.settings.selectedSettingsPane = .general
        let settingsV5View = SettingsView(model: model)
            .background(Color(nsColor: .windowBackgroundColor))
        let settingsV5File = outputDir.appendingPathComponent("ours-settings-v5.png")
        try renderViewToPNG(settingsV5View, size: NSSize(width: 760, height: 540), to: settingsV5File)
        print(settingsV5File.path)

        for pane in SettingsPaneID.allCases {
            model.state.settings.selectedSettingsPane = pane
            let settingsView = SettingsView(model: model)
                .background(Color(nsColor: .windowBackgroundColor))
            let paneFile = outputDir.appendingPathComponent("ours-settings-\(pane.rawValue).png")
            try renderViewToPNG(settingsView, size: NSSize(width: 760, height: 540), to: paneFile)
            print(paneFile.path)
        }

        // 5. Render ours-welcome.png (520x440)
        let welcomeView = WelcomeView(model: model, onTryNow: {})
            .background(Color(nsColor: .windowBackgroundColor))
        let welcomeFile = outputDir.appendingPathComponent("ours-welcome.png")
        try renderViewToPNG(welcomeView, size: NSSize(width: 520, height: 440), to: welcomeFile)
        print(welcomeFile.path)

        // 6. Write ours-status-menu.txt (titles of status NSMenu items)
        let statusMenu = StatusMenuBuilder.buildMenu(model: model, target: nil)
        let lines = statusMenu.items.map { item in
            item.isSeparatorItem ? "---" : item.title
        }
        let menuText = lines.joined(separator: "\n") + "\n"
        let menuFile = outputDir.appendingPathComponent("ours-status-menu.txt")
        try Data(menuText.utf8).write(to: menuFile, options: .atomic)
        print(menuFile.path)
    }

    private struct ExtensionDOMProbeResult {
        var wrappers: Int
        var cjkCharacters: Int
    }

    private static func renderExtensionSnapshotsAndProbe(
        extensionSourcePath: String,
        model: AppModel,
        webSize: NSSize,
        panelCardSize: NSSize,
        outputDir: URL
    ) async throws {
        let sourceURL = URL(fileURLWithPath: extensionSourcePath)
        let installed = try await model.extensionManager.installExtension(from: sourceURL)

        let targetURL = URL(string: "https://en.wikipedia.org/wiki/Swift_(programming_language)")!
        let wikiPad = model.addPad(
            url: targetURL,
            title: "Swift (programming language) - Wikipedia",
            symbolName: "book.pages",
            select: true
        )

        let padController = model.webController(for: wikiPad)
        let webView = padController.webView

        // Host offscreen at (-5000, -5000) with orderFrontRegardless so WebKit IntersectionObserver
        // treats the top-of-article paragraphs as in-viewport while remaining invisible on screen.
        let hostWindow = NSWindow(
            contentRect: NSRect(x: -5000, y: -5000, width: webSize.width, height: webSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        hostWindow.isReleasedWhenClosed = false
        hostWindow.ignoresMouseEvents = true
        webView.removeFromSuperview()
        webView.frame = NSRect(origin: .zero, size: webSize)
        hostWindow.contentView = webView
        hostWindow.orderFrontRegardless()

        defer {
            webView.removeFromSuperview()
            hostWindow.orderOut(nil)
        }

        model.extensionManager.syncTabsWithWorkspace()
        model.extensionManager.notifyWindowFocused()

        // Wait for initial navigation to complete (up to 18 s)
        _ = await padController.ensureLoadedAndWaitUntilReady(timeoutSeconds: 18.0)

        let waitStart = Date()
        let maxExtensionWait: TimeInterval = 30.0

        // Allow content script + MV3 background service worker to initialize
        try? await Task.sleep(nanoseconds: 3_500_000_000)

        var probe = await probeExtensionDOM(on: webView)
        var didTriggerCommand = false

        if probe.wrappers == 0 {
            let summaries = model.extensionManager.listAutomationSummaries()
            if let summary = summaries.first(where: { $0.id == installed.id }) {
                let candidateCmd = summary.commands.first(where: { $0.id == "toggleTranslatePage" })
                    ?? summary.commands.first(where: {
                        $0.id.lowercased().contains("translate") || $0.title.lowercased().contains("translate")
                    })
                if let cmd = candidateCmd {
                    _ = try? model.extensionManager.performAutomationCommand(
                        extensionQuery: installed.id,
                        commandID: cmd.id,
                        padQuery: nil
                    )
                    didTriggerCommand = true
                }
            }
        }

        while Date().timeIntervalSince(waitStart) < maxExtensionWait {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            probe = await probeExtensionDOM(on: webView)

            if probe.wrappers > 0 && probe.cjkCharacters >= 20 {
                // Allow visible paragraphs one final settle pass before screenshot
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                probe = await probeExtensionDOM(on: webView)
                break
            }

            if !didTriggerCommand && probe.wrappers == 0 && Date().timeIntervalSince(waitStart) >= 7.0 {
                let summaries = model.extensionManager.listAutomationSummaries()
                if let summary = summaries.first(where: { $0.id == installed.id }),
                   let cmd = summary.commands.first(where: { $0.id == "toggleTranslatePage" }) {
                    _ = try? model.extensionManager.performAutomationCommand(
                        extensionQuery: installed.id,
                        commandID: cmd.id,
                        padQuery: nil
                    )
                    didTriggerCommand = true
                }
            }
        }

        let extWebSnapshot = await takeWebViewSnapshotWithTimeout(
            webView: webView,
            rect: NSRect(origin: .zero, size: webSize),
            timeoutSeconds: 6.0
        ) ?? renderFallbackWebPreview(size: webSize)

        let extPanelView = ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.13, green: 0.16, blue: 0.24),
                    Color(red: 0.08, green: 0.10, blue: 0.15)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            PanelRootView(model: model, snapshotWebImage: extWebSnapshot)
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .padding(16)
        }
        let extPanelFile = outputDir.appendingPathComponent("ours-panel-extension.png")
        try renderViewToPNG(extPanelView, size: panelCardSize, to: extPanelFile)
        print(extPanelFile.path)

        let probePayload: [String: Any] = [
            "extensionID": installed.id,
            "extensionName": installed.displayName,
            "url": webView.url?.absoluteString ?? targetURL.absoluteString,
            "immersiveTranslateTargetWrappers": probe.wrappers,
            "cjkCharacters": probe.cjkCharacters
        ]
        if let jsonData = try? JSONSerialization.data(withJSONObject: probePayload, options: [.sortedKeys]),
           let jsonStr = String(data: jsonData, encoding: .utf8) {
            print("EXTENSION_PROBE \(jsonStr)")
        }
    }

    private static func probeExtensionDOM(on webView: WKWebView) async -> ExtensionDOMProbeResult {
        let js = """
        (function() {
            var wrappers = document.querySelectorAll('[class*="immersive-translate-target-wrapper"]').length;
            var text = (document.body && document.body.innerText) ? document.body.innerText : '';
            var cjk = (text.match(/[\\u4e00-\\u9fff]/g) || []).length;
            return JSON.stringify({ wrappers: wrappers, cjk: cjk });
        })()
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { value, _ in
                if let str = value as? String,
                   let data = str.data(using: .utf8),
                   let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let w = (dict["wrappers"] as? Int) ?? 0
                    let c = (dict["cjk"] as? Int) ?? 0
                    continuation.resume(returning: ExtensionDOMProbeResult(wrappers: w, cjkCharacters: c))
                } else {
                    continuation.resume(returning: ExtensionDOMProbeResult(wrappers: 0, cjkCharacters: 0))
                }
            }
        }
    }

    private static func captureExampleWebSnapshot(size: NSSize, timeoutSeconds: TimeInterval) async -> NSImage {
        let offscreenWindow = NSWindow(
            contentRect: NSRect(x: -16000, y: -16000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        offscreenWindow.isReleasedWhenClosed = false
        offscreenWindow.alphaValue = 0.01
        offscreenWindow.ignoresMouseEvents = true

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        offscreenWindow.contentView = webView
        offscreenWindow.orderBack(nil)

        defer {
            offscreenWindow.orderOut(nil)
        }

        let waiter = SnapshotNavigationWaiter()
        let loaded = await waiter.waitForFinish(
            on: webView,
            url: URL(string: "https://example.com")!,
            timeoutSeconds: timeoutSeconds
        )

        if loaded {
            try? await Task.sleep(nanoseconds: 350_000_000)
        }

        if let captured = await takeWebViewSnapshotWithTimeout(webView: webView, rect: NSRect(origin: .zero, size: size), timeoutSeconds: 5.0) {
            return captured
        }

        // Clean fallback image if offline
        return renderFallbackWebPreview(size: size)
    }

    public static func captureSnapshotImage(
        of webView: WKWebView,
        size: NSSize,
        timeoutSeconds: TimeInterval
    ) async -> NSImage? {
        await takeWebViewSnapshotWithTimeout(
            webView: webView,
            rect: NSRect(origin: .zero, size: size),
            timeoutSeconds: timeoutSeconds
        )
    }

    public static func writeNSImagePNG(_ image: NSImage, to fileURL: URL) throws {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try pngData.write(to: fileURL, options: .atomic)
    }

    public static func renderSwiftUIViewToPNG<V: View>(_ swiftUIView: V, size: NSSize, to fileURL: URL) throws {
        try renderViewToPNG(swiftUIView, size: size, to: fileURL)
    }

    private static func takeWebViewSnapshotWithTimeout(
        webView: WKWebView,
        rect: NSRect,
        timeoutSeconds: TimeInterval
    ) async -> NSImage? {
        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = rect

        return await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
            var resumed = false
            webView.takeSnapshot(with: snapConfig) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: nil)
            }
        }
    }

    private static func renderFallbackWebPreview(size: NSSize) -> NSImage {
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 28),
            .foregroundColor: NSColor.black
        ]
        NSString(string: "Example Domain").draw(at: NSPoint(x: 80, y: size.height - 120), withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    private static func renderViewToPNG<V: View>(_ swiftUIView: V, size: NSSize, to fileURL: URL) throws {
        let framed = swiftUIView.frame(width: size.width, height: size.height)
            .environment(\.controlActiveState, .key)
        let hosting = NSHostingView(rootView: framed)
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = SnapshotKeyWindow(
            contentRect: NSRect(x: -16000, y: -16000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()

        // Allow SwiftUI split views / forms / materials one runloop turn to settle layout
        RunLoop.main.run(until: Date().addingTimeInterval(0.08))
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        let bounds = hosting.bounds
        if let bitmap = hosting.bitmapImageRepForCachingDisplay(in: bounds) {
            hosting.cacheDisplay(in: bounds, to: bitmap)
            if let pngData = bitmap.representation(using: .png, properties: [:]) {
                try pngData.write(to: fileURL, options: .atomic)
                window.orderOut(nil)
                return
            }
        }

        window.orderOut(nil)

        // Fallback via SwiftUI ImageRenderer
        let renderer = ImageRenderer(content: framed)
        renderer.scale = 2.0
        if let nsImage = renderer.nsImage,
           let tiff = nsImage.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let pngData = rep.representation(using: .png, properties: [:]) {
            try pngData.write(to: fileURL, options: .atomic)
            return
        }

        throw CocoaError(.fileWriteUnknown)
    }
}


/// Offscreen window that reports key/main status so sidebar selection renders like the live, active app.
private final class SnapshotKeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var isKeyWindow: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isMainWindow: Bool { true }
}
