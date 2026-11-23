import AppKit
import Foundation
import SwiftUI
import WebKit
import VeypaneCore

public struct SingleCompatibilityTargetResult: Codable, Sendable {
    public var label: String
    public var requestedOrigin: String
    public var finalOrigin: String
    public var redirectedToSorryPath: Bool
    public var didFinishNavigation: Bool
    public var readyState: String
    public var pageTitle: String
    public var visibleTextLength: Int
    public var iframeCount: Int
    public var challengeIframeCount: Int
    public var challengeIframeCollapsed: Bool
    public var screenshotFile: String
    public var diagnostics: SiteDiagnosticsReport
}

public struct CompatibilityProbeSuiteReport: Codable, Sendable {
    public var generatedAt: Date
    public var isolatedTempStore: Bool
    public var captchaInteractionPerformed: Bool
    public var anyCompatibilityIssueObserved: Bool
    public var compatibilitySnapshotFile: String?
    public var targets: [SingleCompatibilityTargetResult]
}

/// Isolated `--google-compat-probe <outputDir>` / `--compatibility-probe <outputDir>` runner.
/// Uses a temporary store & isolated `WKWebsiteDataStore.nonPersistent()` in-memory store, and passively loads
/// `https://www.google.com/` and `https://www.google.com/search?q=WebKit` at most once each with bounded timeouts.
/// NEVER clicks, solves, automates, logs in, or interacts with any CAPTCHA or page control.
@MainActor
public enum CompatibilityProbeRunner {
    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        Task { @MainActor in
            do {
                let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
                try await runProbe(into: outDir)
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Compatibility probe failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }

        app.run()
    }

    public static func runProbe(into outputDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let tempStoreDir = fm.temporaryDirectory.appendingPathComponent("VeypaneCompatProbe-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: tempStoreDir)
        }

        let tempStore = VeypaneStore(directoryURL: tempStoreDir)
        let isolatedProfile = BrowserProfile(
            name: "IsolatedNonPersistentProbe",
            symbolName: "globe",
            dataStoreIdentifier: UUID()
        )
        var initialState = WorkspaceState(
            pads: [],
            selectedPadID: nil,
            activeProfileID: isolatedProfile.id,
            profiles: [isolatedProfile]
        )
        initialState.settings.hasCompletedOnboarding = true
        try tempStore.save(initialState)

        let model = AppModel(
            store: tempStore,
            allowExtensionPrompts: false,
            useNonPersistentWebsiteDataStore: true
        )
        let webSize = NSSize(width: 1020, height: 700)

        let probeSpecs: [(label: String, url: URL, screenshotName: String)] = [
            ("google-home", URL(string: "https://www.google.com/")!, "google-home.png"),
            ("google-search", URL(string: "https://www.google.com/search?q=WebKit")!, "google-search.png")
        ]

        var results: [SingleCompatibilityTargetResult] = []
        var capturedIssuePadAndImage: (Pad, NSImage, SiteCompatibilityIssueKind, String?)?

        for spec in probeSpecs {
            let pad = model.addPad(url: spec.url, title: spec.label, select: true)
            let wc = model.webController(for: pad)
            let webView = wc.webView

            let hostWindow = NSWindow(
                contentRect: NSRect(x: -15000, y: -15000, width: webSize.width, height: webSize.height),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            hostWindow.isReleasedWhenClosed = false
            hostWindow.alphaValue = 0.01
            hostWindow.ignoresMouseEvents = true
            webView.removeFromSuperview()
            webView.frame = NSRect(origin: .zero, size: webSize)
            hostWindow.contentView = webView
            hostWindow.orderBack(nil)

            let finished = await wc.ensureLoadedAndWaitUntilReady(timeoutSeconds: 15.0)
            // Brief passive settle for subframes (strictly read-only, zero interaction)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await model.refreshSiteDiagnosticsSample(for: pad.id)

            let domSummary = await inspectPassiveDOM(on: webView)
            let snapImage = await UISnapshotRenderer.captureSnapshotImage(of: webView, size: webSize, timeoutSeconds: 5.0)
            let shotURL = outputDir.appendingPathComponent(spec.screenshotName)
            if let snapImage {
                try? UISnapshotRenderer.writeNSImagePNG(snapImage, to: shotURL)
            }

            let diag = model.buildSiteDiagnosticsReport(for: pad.id)
            let finalURL = webView.url
            let sorryPath = (finalURL?.path.lowercased().hasPrefix("/sorry") == true)

            if diag.issueKind != .none, capturedIssuePadAndImage == nil, let snapImage {
                capturedIssuePadAndImage = (pad, snapImage, diag.issueKind, diag.issueSummary)
            }

            results.append(
                SingleCompatibilityTargetResult(
                    label: spec.label,
                    requestedOrigin: SiteCompatibilityInspector.sanitizedOrigin(for: spec.url),
                    finalOrigin: SiteCompatibilityInspector.sanitizedOrigin(for: finalURL),
                    redirectedToSorryPath: sorryPath,
                    didFinishNavigation: finished,
                    readyState: domSummary.readyState,
                    pageTitle: domSummary.title,
                    visibleTextLength: domSummary.visibleTextLength,
                    iframeCount: domSummary.iframeCount,
                    challengeIframeCount: domSummary.challengeIframeCount,
                    challengeIframeCollapsed: domSummary.challengeIframeCollapsed,
                    screenshotFile: shotURL.lastPathComponent,
                    diagnostics: diag
                )
            )

            webView.removeFromSuperview()
            hostWindow.orderOut(nil)
        }

        var compatPanelShotName: String?
        if let (_, issueImage, issueKind, issueSummary) = capturedIssuePadAndImage {
            let compatShotURL = outputDir.appendingPathComponent("ours-compatibility-v5.png")
            let panelCardView = ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.13, green: 0.16, blue: 0.24),
                        Color(red: 0.08, green: 0.10, blue: 0.15)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                PanelRootView(
                    model: model,
                    snapshotWebImage: issueImage,
                    snapshotCompatibilityIssue: issueKind,
                    snapshotCompatibilitySummary: issueSummary
                )
                .shadow(color: .black.opacity(0.32), radius: 18, y: 8)
                .padding(16)
            }
            try UISnapshotRenderer.renderSwiftUIViewToPNG(
                panelCardView,
                size: NSSize(width: 1080, height: 740),
                to: compatShotURL
            )
            compatPanelShotName = compatShotURL.lastPathComponent
        }

        let suiteReport = CompatibilityProbeSuiteReport(
            generatedAt: Date(),
            isolatedTempStore: true,
            captchaInteractionPerformed: false,
            anyCompatibilityIssueObserved: results.contains(where: { $0.diagnostics.issueKind != .none || $0.redirectedToSorryPath }),
            compatibilitySnapshotFile: compatPanelShotName,
            targets: results
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(suiteReport)
        let reportFile = outputDir.appendingPathComponent("compatibility-report.json")
        try jsonData.write(to: reportFile, options: .atomic)
        print(reportFile.path)
    }

    private struct PassiveDOMObservation {
        var readyState: String
        var title: String
        var visibleTextLength: Int
        var iframeCount: Int
        var challengeIframeCount: Int
        var challengeIframeCollapsed: Bool
    }

    private static func inspectPassiveDOM(on webView: WKWebView) async -> PassiveDOMObservation {
        let js = """
        (function() {
            var rs = document.readyState || "";
            var title = document.title || "";
            var textLen = (document.body && document.body.innerText) ? document.body.innerText.trim().length : 0;
            var allFrames = Array.from(document.querySelectorAll("iframe"));
            var chalFrames = allFrames.filter(function(f) {
                var s = ((f.getAttribute("src") || "") + " " + (f.getAttribute("title") || "")).toLowerCase();
                return s.indexOf("recaptcha") !== -1 || s.indexOf("challenge") !== -1;
            });
            var collapsed = chalFrames.length > 0 && chalFrames.every(function(f) {
                var r = f.getBoundingClientRect();
                return r.width < 10 || r.height < 10;
            });
            return JSON.stringify({
                readyState: rs,
                title: title.slice(0, 120),
                textLen: textLen,
                iframes: allFrames.length,
                chalFrames: chalFrames.length,
                collapsed: collapsed
            });
        })()
        """
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { value, _ in
                guard let str = value as? String,
                      let data = str.data(using: .utf8),
                      let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    continuation.resume(returning: PassiveDOMObservation(
                        readyState: "unknown",
                        title: webView.title ?? "",
                        visibleTextLength: 0,
                        iframeCount: 0,
                        challengeIframeCount: 0,
                        challengeIframeCollapsed: false
                    ))
                    return
                }
                continuation.resume(returning: PassiveDOMObservation(
                    readyState: (dict["readyState"] as? String) ?? "",
                    title: (dict["title"] as? String) ?? "",
                    visibleTextLength: (dict["textLen"] as? Int) ?? 0,
                    iframeCount: (dict["iframes"] as? Int) ?? 0,
                    challengeIframeCount: (dict["chalFrames"] as? Int) ?? 0,
                    challengeIframeCollapsed: (dict["collapsed"] as? Bool) ?? false
                ))
            }
        }
    }
}
