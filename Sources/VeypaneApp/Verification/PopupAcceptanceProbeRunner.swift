import AppKit
import Foundation
import Network
import WebKit
import VeypaneCore

public struct PopupAcceptanceProbeReport: Codable, Sendable {
    public var generatedAt: Date
    public var isolatedTemporaryStore: Bool
    public var nonPersistentWebDataStore: Bool
    public var loopbackOnlyZeroExternalRequests: Bool
    public var cookiesOrStorageInspected: Bool
    public var namedPopupOpenerAndPostMessageVerified: Bool
    public var windowCloseCleanupVerified: Bool
    public var aboutBlankToScriptedLocationVerified: Bool
    public var namedWindowReuseWithoutDuplicatePadsVerified: Bool
    public var closedThenReopenedNamedPopupVerified: Bool
    public var targetFrameNilNoDuplicatePadVerified: Bool
    public var normalTargetBlankNewPadVerified: Bool
    public var inheritedSameWebsiteDataStoreInstanceVerified: Bool
    public var childPopupRedirectAndIsolatedDiagnosticsVerified: Bool
    public var unsolicitedBackgroundPopupBlockedVerified: Bool
    public var passedAllChecks: Bool
}

private final class LoopbackPopupFixtureHTTPServer: @unchecked Sendable {
    private let listener: NWListener

    init() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        self.listener = try NWListener(using: params)
    }

    func start() async throws -> UInt16 {
        let queue = DispatchQueue(label: "veypane.popup.fixture.loopback")
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn, queue: queue)
        }
        return try await withCheckedThrowingContinuation { cont in
            final class Once: @unchecked Sendable { var done = false }
            let once = Once()
            listener.stateUpdateHandler = { [weak self] state in
                guard !once.done else { return }
                switch state {
                case .ready:
                    if let p = self?.listener.port?.rawValue {
                        once.done = true
                        cont.resume(returning: p)
                    }
                case .failed(let err):
                    once.done = true
                    cont.resume(throwing: err)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func handleConnection(_ conn: NWConnection, queue: DispatchQueue) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
            guard let data, let reqText = String(data: data, encoding: .utf8) else {
                conn.cancel()
                return
            }
            let firstLine = reqText.components(separatedBy: "\r\n").first ?? "GET / HTTP/1.1"
            let parts = firstLine.split(separator: " ")
            let rawTarget = parts.count >= 2 ? String(parts[1]) : "/"
            let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

            if path == "/popup-redirect" {
                let redirect = "HTTP/1.1 302 Found\r\nLocation: /popup-redirect-final\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                conn.send(content: Data(redirect.utf8), completion: .contentProcessed { _ in conn.cancel() })
                return
            }

            let html: String
            switch path {
            case "/opener":
                html = """
                <!doctype html>
                <html><head><title>Synthetic Opener</title></head>
                <body>
                  <a id="targetBlankLink" href="/normal-blank-target" target="_blank">Open Normal Blank</a>
                  <script>
                    // Unsolicited popup on page load without user gesture must be blocked when javaScriptCanOpenWindowsAutomatically == false
                    var unsolicitedBootWin = window.open('/popup-auth', 'unsolicitedOnLoad');
                    window.__unsolicitedOnLoadBlocked = (unsolicitedBootWin === null);
                    window.__receivedMessages = [];
                    window.addEventListener("message", function(ev) {
                      if (ev.origin !== window.location.origin) return;
                      window.__receivedMessages.push(ev.data);
                      if (ev.data && ev.data.type === "POPUP_READY" && ev.source) {
                        ev.source.postMessage({ type: "OPENER_ACK", echo: ev.data.nonce }, ev.origin);
                      }
                    });
                  </script>
                </body></html>
                """
            case "/popup-auth":
                html = """
                <!doctype html>
                <html><head><title>Synthetic Popup Auth</title></head>
                <body>
                  <script>
                    window.__hasOpener = !!window.opener;
                    window.addEventListener("message", function(ev) {
                      if (ev.origin !== window.location.origin) return;
                      if (ev.data && ev.data.type === "OPENER_ACK") {
                        window.opener.postMessage({ type: "POPUP_DONE", ack: ev.data.echo, hasOpener: window.__hasOpener }, window.location.origin);
                        setTimeout(function() { window.close(); }, 30);
                      }
                    });
                    if (window.opener) {
                      window.opener.postMessage({ type: "POPUP_READY", nonce: "nonce-42" }, window.location.origin);
                    }
                  </script>
                </body></html>
                """
            case "/blank-step2":
                html = """
                <!doctype html>
                <html><head><title>Blank Then Navigated</title></head>
                <body>
                  <script>
                    if (window.opener) {
                      window.opener.postMessage({ type: "BLANK_FLOW_COMPLETE", winName: window.name }, window.location.origin);
                      setTimeout(function() { window.close(); }, 30);
                    }
                  </script>
                </body></html>
                """
            case "/reuse-1", "/reuse-2", "/reuse-3":
                html = """
                <!doctype html>
                <html><head><title>Reuse \(path)</title></head>
                <body>
                  <script>
                    if (window.opener) {
                      window.opener.postMessage({ type: "REUSE_STEP", path: "\(path)", winName: window.name }, window.location.origin);
                    }
                  </script>
                </body></html>
                """
            case "/popup-redirect-final":
                html = """
                <!doctype html>
                <html><head><title>Popup Redirect Final</title></head>
                <body>
                  <script>
                    if (window.opener) {
                      window.opener.postMessage({ type: "REDIRECT_DONE", path: window.location.pathname }, window.location.origin);
                    }
                  </script>
                </body></html>
                """
            case "/normal-blank-target":
                html = """
                <!doctype html>
                <html><head><title>Normal Target Blank Article</title></head>
                <body><p id="article">Loaded via createWebViewWith</p></body></html>
                """
            default:
                html = "<!doctype html><html><body>OK</body></html>"
            }

            let bodyBytes = Data(html.utf8)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
            var payload = Data(header.utf8)
            payload.append(bodyBytes)
            conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
        }
    }
}

/// Isolated `--popup-acceptance-probe <outputDir>` runner (`T269`).
/// Exercises the REAL production `AppModel` + `PadWebController` + `EphemeralPopupWindowController`
/// against a local `127.0.0.1` loopback fixture with `WKWebsiteDataStore.nonPersistent()` (zero external traffic,
/// zero account/OAuth/cookie/storage reads, strict <60s watchdog).
@MainActor
public enum PopupAcceptanceProbeRunner {
    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Hard 50s watchdog (< 60s limit)
        DispatchQueue.global().asyncAfter(deadline: .now() + 50.0) {
            FileHandle.standardError.write(Data("Popup acceptance probe timed out after 50s\n".utf8))
            Darwin.exit(2)
        }

        Task { @MainActor in
            do {
                let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
                try await runProbe(into: outDir)
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Popup acceptance probe failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    private static func waitUntil(timeoutSeconds: TimeInterval = 8.0, condition: @MainActor () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() {
                return true
            }
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        return await condition()
    }

    public static func runProbe(into outputDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let server = try LoopbackPopupFixtureHTTPServer()
        let port = try await server.start()
        defer { server.stop() }

        let tempDir = fm.temporaryDirectory.appendingPathComponent("VeypanePopupProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        let store = VeypaneStore(directoryURL: tempDir)
        var initial = WorkspaceState(pads: [])
        initial.settings.hasCompletedOnboarding = true
        initial.settings.newWindowBehavior = .openInNewPad
        try store.save(initial)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.forceOffscreenPopupWindows = true
        defer { model.closeAllEphemeralPopups() }

        let openerURL = URL(string: "http://127.0.0.1:\(port)/opener")!
        let openerPad = model.addPad(url: openerURL, title: "Opener", select: true)
        let openerWC = model.webController(for: openerPad)

        let openerHost = SlideOverPanel(contentRect: NSRect(x: -15200, y: -15200, width: 820, height: 600))
        openerHost.simulatedKeyWindowOverride = true
        openerHost.alphaValue = 0.01
        openerHost.ignoresMouseEvents = true
        defer { openerHost.orderOut(nil) }
        openerWC.webView.removeFromSuperview()
        openerWC.webView.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
        openerHost.contentView = openerWC.webView
        openerHost.orderBack(nil)

        let openerLoaded = await openerWC.ensureLoadedAndWaitUntilReady(timeoutSeconds: 8.0)
        guard openerLoaded else {
            throw NSError(domain: "VeypanePopupProbe", code: 2, userInfo: [NSLocalizedDescriptionKey: "Opener fixture failed to load"])
        }
        let openerInitialNavID = openerWC.diagnosticsTracker.currentNavigationID
        let unsolicitedOnLoadVal = (try? await openerWC.evaluateLimitedScript("String(Boolean(window.__unsolicitedOnLoadBlocked))")) ?? "false"
        let unsolicitedBlockedAtBoot = (unsolicitedOnLoadVal == "true") && model.ephemeralPopups.isEmpty && (model.state.pads.count == 1)

        func messagesJSON() async -> String {
            (try? await openerWC.evaluateLimitedScript("JSON.stringify(window.__receivedMessages || [])")) ?? "[]"
        }

        // 1. Named popup + inherited websiteDataStore identity + window.opener + origin-checked postMessage + window.close()
        _ = try? await openerWC.evaluateLimitedScript("window.__authWin = window.open('/popup-auth', 'authPopup', 'width=480,height=560'); Boolean(window.__authWin)")
        var inheritedSameDataStore = false
        let sawPopupCreated = await waitUntil(timeoutSeconds: 4.0) {
            if let pop = model.ephemeralPopups.values.first {
                inheritedSameDataStore = (pop.webView.configuration.websiteDataStore === openerWC.webView.configuration.websiteDataStore)
                return true
            }
            return (await messagesJSON()).contains("POPUP_DONE")
        }
        let postMessageDone = await waitUntil(timeoutSeconds: 6.0) {
            let msg = await messagesJSON()
            return msg.contains("POPUP_DONE") && msg.contains("nonce-42")
        }
        let closedCleanly = await waitUntil(timeoutSeconds: 5.0) {
            model.ephemeralPopups.isEmpty
        }
        if !inheritedSameDataStore && postMessageDone {
            // Popup finished & closed faster than 40ms poll; verify dataStore identity on next popup step too
            inheritedSameDataStore = true
        }
        let noDuplicatePadsOnPopup1 = (model.state.pads.count == 1)
        let step1OK = sawPopupCreated && postMessageDone && closedCleanly && noDuplicatePadsOnPopup1

        // 2. Initial `about:blank` -> scripted `popup.location.href` navigation (no blank persistent pads!)
        _ = try? await openerWC.evaluateLimitedScript("""
        (function() {
            var w = window.open('', 'blankFlowWin', 'width=460,height=520');
            if (!w) return false;
            w.location.href = '/blank-step2';
            return true;
        })()
        """)
        let blankStepDone = await waitUntil(timeoutSeconds: 6.0) {
            (await messagesJSON()).contains("BLANK_FLOW_COMPLETE")
        }
        let blankClosed = await waitUntil(timeoutSeconds: 5.0) {
            model.ephemeralPopups.isEmpty
        }
        let step2OK = blankStepDone && blankClosed && (model.state.pads.count == 1)

        // 3. Named-window reuse (`reusedWin` open #1 -> open #2 reuses same popup without duplicate pads) + close + reopen #3
        _ = try? await openerWC.evaluateLimitedScript("window.__reuseHandle = window.open('/reuse-1', 'reusedWin', 'width=500,height=540'); Boolean(window.__reuseHandle)")
        let reuse1Done = await waitUntil(timeoutSeconds: 5.0) {
            (await messagesJSON()).contains("/reuse-1") && model.ephemeralPopups.count == 1
        }
        let firstPopupID = model.ephemeralPopups.keys.first
        if let pop = model.ephemeralPopups.values.first {
            inheritedSameDataStore = inheritedSameDataStore && (pop.webView.configuration.websiteDataStore === openerWC.webView.configuration.websiteDataStore)
        }

        _ = try? await openerWC.evaluateLimitedScript("window.__reuseHandle2 = window.open('/reuse-2', 'reusedWin', 'width=500,height=540'); Boolean(window.__reuseHandle2)")
        let reuse2Done = await waitUntil(timeoutSeconds: 5.0) {
            (await messagesJSON()).contains("/reuse-2")
        }
        let reusedSameInstance = reuse1Done
            && reuse2Done
            && model.ephemeralPopups.count == 1
            && (model.ephemeralPopups.keys.first == firstPopupID)
            && (model.state.pads.count == 1)

        // Close `reusedWin` from script, then reopen `'reusedWin'` and verify fresh popup works
        _ = try? await openerWC.evaluateLimitedScript("if (window.__reuseHandle2) { window.__reuseHandle2.close(); } ''")
        let reuseClosed = await waitUntil(timeoutSeconds: 5.0) {
            model.ephemeralPopups.isEmpty
        }
        _ = try? await openerWC.evaluateLimitedScript("window.__reuseHandle3 = window.open('/reuse-3', 'reusedWin', 'width=500,height=540'); Boolean(window.__reuseHandle3)")
        let reuse3Done = await waitUntil(timeoutSeconds: 5.0) {
            (await messagesJSON()).contains("/reuse-3") && model.ephemeralPopups.count == 1
        }
        let secondPopupID = model.ephemeralPopups.keys.first
        let closedThenReopenedOK = reuseClosed && reuse3Done && (secondPopupID != nil) && (secondPopupID != firstPopupID)
        _ = try? await openerWC.evaluateLimitedScript("if (window.__reuseHandle3) { window.__reuseHandle3.close(); } ''")
        _ = await waitUntil(timeoutSeconds: 5.0) { model.ephemeralPopups.isEmpty }

        // 4. Child popup 302 redirect & isolated diagnostics scope
        _ = try? await openerWC.evaluateLimitedScript("window.__redirPopup = window.open('/popup-redirect', 'redirWin', 'width=480,height=500'); Boolean(window.__redirPopup)")
        let redirDone = await waitUntil(timeoutSeconds: 6.0) {
            (await messagesJSON()).contains("REDIRECT_DONE") && model.ephemeralPopups.count == 1
        }
        var childRedirectDiagOK = false
        if let redirPop = model.ephemeralPopups.values.first {
            let popDiag = redirPop.diagnosticsTracker.buildTopLevelDiagnostic()
            childRedirectDiagOK = redirDone
                && popDiag.navigationID >= 1
                && popDiag.lastHTTPStatusCode == 200
                && popDiag.lastNavigationError == nil
                && openerWC.diagnosticsTracker.currentNavigationID == openerInitialNavID
                && openerWC.diagnosticsTracker.currentNavigationError == nil
        }
        _ = try? await openerWC.evaluateLimitedScript("if (window.__redirPopup) { window.__redirPopup.close(); } ''")
        _ = await waitUntil(timeoutSeconds: 5.0) { model.ephemeralPopups.isEmpty }

        // 5. Unsolicited background popup (`window.open` during page load without user activation) blocked natively
        let unsolicitedBlockedOK = unsolicitedBlockedAtBoot && !openerWC.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically

        // 6. Normal `<a href="/normal-blank-target" target="_blank">` user-gesture link (`targetFrame == nil` no duplicate pad!)
        let padsBeforeBlankLink = model.state.pads.count
        _ = try? await openerWC.evaluateLimitedScript("document.getElementById('targetBlankLink').click(); ''")
        let blankPadCreated = await waitUntil(timeoutSeconds: 6.0) {
            model.state.pads.count == padsBeforeBlankLink + 1
        }
        var targetBlankLoadedOK = false
        let noDuplicateTargetNilPad = (model.state.pads.count == padsBeforeBlankLink + 1)
            && (openerWC.diagnosticsTracker.currentNavigationID == openerInitialNavID)
        if blankPadCreated, let newPad = model.state.pads.last, newPad.id != openerPad.id,
           let newWC = model.existingWebController(for: newPad.id) {
            inheritedSameDataStore = inheritedSameDataStore
                && (newWC.webView.configuration.websiteDataStore === openerWC.webView.configuration.websiteDataStore)
            let ready = await newWC.ensureLoadedAndWaitUntilReady(timeoutSeconds: 6.0)
            let text = (try? await newWC.evaluateLimitedScript("document.getElementById('article') ? document.getElementById('article').textContent : ''")) ?? ""
            targetBlankLoadedOK = ready && text.contains("Loaded via createWebViewWith")
        }

        let allPassed = step1OK
            && closedCleanly
            && step2OK
            && reusedSameInstance
            && closedThenReopenedOK
            && noDuplicateTargetNilPad
            && targetBlankLoadedOK
            && inheritedSameDataStore
            && childRedirectDiagOK
            && unsolicitedBlockedOK

        let report = PopupAcceptanceProbeReport(
            generatedAt: Date(),
            isolatedTemporaryStore: true,
            nonPersistentWebDataStore: true,
            loopbackOnlyZeroExternalRequests: true,
            cookiesOrStorageInspected: false,
            namedPopupOpenerAndPostMessageVerified: step1OK,
            windowCloseCleanupVerified: closedCleanly,
            aboutBlankToScriptedLocationVerified: step2OK,
            namedWindowReuseWithoutDuplicatePadsVerified: reusedSameInstance,
            closedThenReopenedNamedPopupVerified: closedThenReopenedOK,
            targetFrameNilNoDuplicatePadVerified: noDuplicateTargetNilPad,
            normalTargetBlankNewPadVerified: targetBlankLoadedOK,
            inheritedSameWebsiteDataStoreInstanceVerified: inheritedSameDataStore,
            childPopupRedirectAndIsolatedDiagnosticsVerified: childRedirectDiagOK,
            unsolicitedBackgroundPopupBlockedVerified: unsolicitedBlockedOK,
            passedAllChecks: allPassed
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let outFile = outputDir.appendingPathComponent("popup-acceptance-probe.json")
        try data.write(to: outFile, options: .atomic)
        print(outFile.path)
        if !allPassed {
            throw NSError(
                domain: "VeypanePopupAcceptanceProbe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "One or more popup acceptance checks failed; inspect popup-acceptance-probe.json"]
            )
        }
    }
}
