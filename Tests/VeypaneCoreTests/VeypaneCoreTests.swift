import AppKit
import SwiftUI
import Foundation
import CoreGraphics
import Network
import WebKit
import Testing
@testable import VeypaneCore
@testable import VeypaneApp

@Suite("VeypaneCore Comprehensive Tests", .serialized)
struct VeypaneCoreTests {

    // MARK: - 1. Panel Geometry & Per-Site Sizing & Multi-Display

    @Test("Panel visible & hidden frames across edges and corners")
    func panelGeometryEdgesAndCorners() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

        let rightVisible = PanelGeometry.visibleFrame(
            screenVisibleFrame: screen,
            anchor: .right,
            defaultWidthPercent: 35,
            defaultHeightPercent: 90,
            edgeInset: 10
        )
        #expect(rightVisible.width == 672)
        #expect(rightVisible.height == 972)
        #expect(rightVisible.maxX == 1910)
        #expect(abs(rightVisible.midY - screen.midY) <= 1)

        let rightHidden = PanelGeometry.hiddenFrame(
            visibleFrame: rightVisible,
            screenFrame: screen,
            anchor: .right,
            offscreenGap: 16
        )
        #expect(rightHidden.minX == 1936)
        #expect(rightHidden.minY == rightVisible.minY)

        let topLeftVisible = PanelGeometry.visibleFrame(
            screenVisibleFrame: screen,
            anchor: .topLeft,
            defaultWidthPercent: 25,
            defaultHeightPercent: 50,
            edgeInset: 8
        )
        #expect(topLeftVisible.minX == 8)
        #expect(topLeftVisible.maxY == 1072)

        let leftHidden = PanelGeometry.hiddenFrame(
            visibleFrame: topLeftVisible,
            screenFrame: screen,
            anchor: .topLeft,
            offscreenGap: 12
        )
        #expect(leftHidden.maxX == -12)
    }

    @Test("Per-site size rules & per-pad override precedence")
    func perSiteSizeRules() {
        let rules = [
            SiteSizeRule(
                hostPattern: "*.slack.com",
                sizeOverride: PanelSizeOverride(widthPercent: 45, heightPercent: 95)
            ),
            SiteSizeRule(
                hostPattern: "calendar.google.com",
                sizeOverride: PanelSizeOverride(fixedWidth: 520, fixedHeight: 760)
            )
        ]

        let slackPad = Pad(title: "Slack", url: URL(string: "https://app.slack.com/client/T123")!)
        let matchedSlack = SiteSizeRuleMatcher.effectiveOverride(for: slackPad, rules: rules)
        #expect(matchedSlack?.widthPercent == 45)

        var customSlackPad = slackPad
        customSlackPad.sizeOverride = PanelSizeOverride(fixedWidth: 600)
        let explicitWins = SiteSizeRuleMatcher.effectiveOverride(for: customSlackPad, rules: rules)
        #expect(explicitWins?.fixedWidth == 600)
        #expect(explicitWins?.widthPercent == nil)

        let calPad = Pad(title: "Cal", url: URL(string: "https://calendar.google.com/calendar/u/0")!)
        let calOverride = SiteSizeRuleMatcher.effectiveOverride(for: calPad, rules: rules)
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = PanelGeometry.visibleFrame(
            screenVisibleFrame: screen,
            anchor: .bottomRight,
            defaultWidthPercent: 30,
            defaultHeightPercent: 80,
            override: calOverride,
            edgeInset: 10
        )
        #expect(frame.width == 520)
        #expect(frame.height == 760)
        #expect(frame.minY == 10)
        #expect(frame.maxX == 1430)
    }

    @Test("Multi-display selection: follow mouse vs pinned display with fallback")
    func multiDisplaySelection() {
        let main = DisplayDescriptor(
            id: 1,
            name: "Built-in Retina Display",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            isMain: true
        )
        let external = DisplayDescriptor(
            id: 2,
            name: "Studio Display",
            frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
            isMain: false
        )
        let displays = [main, external]

        let followed = DisplaySelector.selectDisplay(
            from: displays,
            mode: .followMouse,
            mouseLocation: CGPoint(x: 2200, y: 600)
        )
        #expect(followed?.id == 2)

        let pinned = DisplaySelector.selectDisplay(
            from: displays,
            mode: .pinnedDisplay(displayID: 1, name: main.name),
            mouseLocation: CGPoint(x: 2200, y: 600)
        )
        #expect(pinned?.id == 1)

        // Disconnected display ID 99 falls back to mouse display
        let fallback = DisplaySelector.selectDisplay(
            from: displays,
            mode: .pinnedDisplay(displayID: 99, name: "Disconnected"),
            mouseLocation: CGPoint(x: 2200, y: 600)
        )
        #expect(fallback?.id == 2)
    }

    // MARK: - 2. Edge Trigger Engine & Hysteresis

    @Test("Hot edge dwell trigger, modifier/drag/fullscreen guards, and grace dismissal")
    func edgeTriggerHysteresis() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = PanelGeometry.visibleFrame(
            screenVisibleFrame: screen,
            anchor: .right,
            defaultWidthPercent: 35,
            defaultHeightPercent: 90
        )
        var settings = EdgeTriggerSettings(
            isEnabled: true,
            dwellMilliseconds: 150,
            triggerThickness: 4,
            dismissGraceMilliseconds: 300,
            requiredModifiers: [.option],
            ignoreWhileDragging: true,
            ignoreInFullScreenApps: true
        )
        var engine = EdgeTriggerEngine()

        // Without Option modifier -> does not dwell
        let noMod = PointerContext(
            location: CGPoint(x: 1439, y: 450),
            timestamp: 10.0,
            screenFrame: screen,
            visiblePanelFrame: panel,
            activeModifiers: []
        )
        #expect(engine.evaluate(context: noMod, anchor: .right, settings: settings) == .none)
        #expect(engine.phase == .hidden)

        // With Option modifier, while dragging -> ignored
        var dragging = noMod
        dragging.activeModifiers = [.option]
        dragging.isDragging = true
        #expect(engine.evaluate(context: dragging, anchor: .right, settings: settings) == .none)

        // Valid entry starts dwell
        var valid = noMod
        valid.activeModifiers = [.option]
        #expect(engine.evaluate(context: valid, anchor: .right, settings: settings) == .none)
        #expect(engine.phase == .dwelling(startedAt: 10.0))

        // 100ms later (< 150ms) -> still dwelling
        valid.timestamp = 10.10
        #expect(engine.evaluate(context: valid, anchor: .right, settings: settings) == .none)

        // 160ms later -> triggers showPanel!
        valid.timestamp = 10.16
        #expect(engine.evaluate(context: valid, anchor: .right, settings: settings) == .showPanel)
        #expect(engine.phase == .visible)

        // Pointer leaves panel -> enters grace period, does not hide immediately
        settings.requiredModifiers = []
        let outside = PointerContext(
            location: CGPoint(x: 300, y: 450),
            timestamp: 11.0,
            screenFrame: screen,
            visiblePanelFrame: panel
        )
        #expect(engine.evaluate(context: outside, anchor: .right, settings: settings) == .none)
        #expect(engine.phase == .dismissGrace(startedAt: 11.0))

        // Re-entering panel within 300ms cancels dismissal
        let backInside = PointerContext(
            location: CGPoint(x: panel.midX, y: panel.midY),
            timestamp: 11.15,
            screenFrame: screen,
            visiblePanelFrame: panel
        )
        #expect(engine.evaluate(context: backInside, anchor: .right, settings: settings) == .none)
        #expect(engine.phase == .visible)

        // Leaving again for >= 300ms hides panel (unless pinned)
        var leaveStart = outside
        leaveStart.timestamp = 12.0
        _ = engine.evaluate(context: leaveStart, anchor: .right, settings: settings)
        var leaveEnd = outside
        leaveEnd.timestamp = 12.35
        leaveEnd.isPinnedOpen = true
        #expect(engine.evaluate(context: leaveEnd, anchor: .right, settings: settings) == .none)

        // Unpinned -> hides after grace
        _ = engine.evaluate(context: PointerContext(location: CGPoint(x: 100, y: 450), timestamp: 13.0, screenFrame: screen, visiblePanelFrame: panel), anchor: .right, settings: settings)
        let finalHide = engine.evaluate(context: PointerContext(location: CGPoint(x: 100, y: 450), timestamp: 13.35, screenFrame: screen, visiblePanelFrame: panel), anchor: .right, settings: settings)
        #expect(finalHide == .hidePanel)
        #expect(engine.phase == .hidden)
    }

    // MARK: - 3. Omnibox URL vs Search Parsing

    @Test("Omnibox distinguishes URLs, domains, localhost/IPs, and search keywords")
    func omniboxParsing() {
        #expect(OmniboxParser.resolve(input: "https://developer.apple.com/documentation") ==
                .directURL(URL(string: "https://developer.apple.com/documentation")!))

        #expect(OmniboxParser.resolve(input: "docs.swift.org/swift-book") ==
                .directURL(URL(string: "https://docs.swift.org/swift-book")!))

        #expect(OmniboxParser.resolve(input: "localhost:3000/api") ==
                .directURL(URL(string: "http://localhost:3000/api")!))

        #expect(OmniboxParser.resolve(input: "127.0.0.1:8080") ==
                .directURL(URL(string: "http://127.0.0.1:8080")!))

        let searchRes = OmniboxParser.resolve(input: "swift concurrency actors", engine: .google)
        if case .search(let query, let url) = searchRes {
            #expect(query == "swift concurrency actors")
            #expect(url.absoluteString == "https://www.google.com/search?q=swift%20concurrency%20actors")
        } else {
            Issue.record("Expected search resolution")
        }

        let customRes = OmniboxParser.resolve(
            input: "? apple.com",
            engine: .custom,
            customTemplate: "https://example.org/find?term={query}"
        )
        #expect(customRes.url.absoluteString == "https://example.org/find?term=apple.com")
    }

    // MARK: - 4. User Agent Presets, Badges, and Hotkeys

    @Test("User-Agent presets resolve mobile, desktop, and custom strings")
    func userAgentPresets() {
        #expect(UserAgentPreset.iPhoneSafari.isMobile)
        #expect(UserAgentPreset.iPadSafari.isMobile)
        #expect(!UserAgentPreset.desktopSafari.isMobile)
        #expect(UserAgentPreset.iPhoneSafari.resolvedUserAgent()?.contains("iPhone") == true)
        #expect(UserAgentPreset.desktopSafari.resolvedUserAgent()?.contains("Macintosh") == true)
        #expect(UserAgentPreset.defaultWebKit.resolvedUserAgent() == nil)
        #expect(UserAgentPreset.custom.resolvedUserAgent(customValue: "MyAgent/1.0") == "MyAgent/1.0")
    }

    @Test("Badge parsing extracts unread counts and ignores trailing years")
    func badgeParsing() {
        let inbox = BadgeParser.parse(pageTitle: "(3) Inbox - alex@example.com")
        #expect(inbox.count == 3)
        #expect(inbox.cleanTitle == "Inbox - alex@example.com")

        let big = BadgeParser.parse(pageTitle: "[1,240+] Notifications")
        #expect(big.count == 1240)
        var pad = Pad(title: "Mail", url: URL(string: "https://mail.google.com")!, badgeCount: big.count)
        #expect(pad.formattedBadge == "99+")

        let dot = BadgeParser.parse(pageTitle: "• general — Team")
        #expect(dot.count == nil)
        #expect(dot.hasUnreadDot == true)
        pad.badgeCount = nil
        pad.hasUnreadDot = true
        #expect(pad.formattedBadge == "•")

        let yearTitle = BadgeParser.parse(pageTitle: "Annual Financial Summary (2026)")
        #expect(yearTitle.count == nil)
        #expect(yearTitle.hasUnreadDot == false)
    }

    @Test("Hotkey parsing, display formatting, and Carbon bitmask round-trip")
    func hotkeyParsing() throws {
        let defaultBinding = HotkeyBinding.defaultToggle
        #expect(defaultBinding.displayString == "⌃`")
        #expect(defaultBinding.modifiers.carbonFlags == 4096)

        let parsedSymbol = try HotkeyCatalog.parse("⌃`")
        #expect(parsedSymbol == defaultBinding)

        let parsedWords = try HotkeyCatalog.parse("Cmd+Shift+Space")
        #expect(parsedWords.modifiers == [.command, .shift])
        #expect(parsedWords.displayString == "⇧⌘Space")
        #expect(HotkeyModifiers(carbonFlags: parsedWords.modifiers.carbonFlags) == parsedWords.modifiers)

        let fnKey = try HotkeyCatalog.parse("F12")
        #expect(fnKey.modifiers.isEmpty)

        #expect(throws: HotkeyParseError.missingModifiers) {
            _ = try HotkeyCatalog.parse("A")
        }
    }

    // MARK: - 5. Persistence, Corruption Recovery, Migration, Export/Import & Sync

    @Test("Persistence round-trip, corrupt file recovery, v1 migration, and export/import")
    func persistenceAndMigration() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = VeypaneStore(directoryURL: tempRoot)
        var initial = store.load().state
        #expect(initial.pads.count >= 2)

        _ = PadWorkspaceEngine.addPad(
            to: &initial,
            url: URL(string: "https://swift.org")!,
            title: "Swift.org"
        )
        initial.settings.anchor = .topLeft
        try store.save(initial)

        let reloaded = store.load()
        #expect(!reloaded.didRecoverFromCorruption)
        #expect(reloaded.state.settings.anchor == .topLeft)
        #expect(reloaded.state.pads.contains(where: { $0.title == "Swift.org" }))

        // Export & Import (authToken must NOT be overwritten by imported bundle)
        let originalToken = reloaded.state.settings.automation.authToken
        let exported = try store.exportData(from: reloaded.state)
        let exportedString = String(decoding: exported, as: UTF8.self)
        #expect(!exportedString.contains(originalToken))

        var cleanTarget = WorkspaceState.makeDefault()
        let keepToken = cleanTarget.settings.automation.authToken
        let imported = try store.importData(exported, into: cleanTarget, merge: false)
        #expect(imported.settings.anchor == .topLeft)
        #expect(imported.settings.automation.authToken == keepToken)

        // Corrupt file recovery -> creates .bak file and returns safe defaults
        try Data("{corrupt json!!!".utf8).write(to: store.stateFileURL)
        let recovered = store.load()
        #expect(recovered.didRecoverFromCorruption)
        #expect(recovered.backupFileURL != nil)
        #expect(FileManager.default.fileExists(atPath: recovered.backupFileURL!.path))

        // Schema v1 migration -> upgrades to v3 seamlessly
        let v1JSON = """
        {
          "schemaVersion": 1,
          "pads": [
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "title": "Legacy Pad",
              "url": "https://example.com"
            }
          ],
          "settings": {
            "anchor": "left",
            "widthPercent": 40.0,
            "heightPercent": 85.0
          }
        }
        """
        try Data(v1JSON.utf8).write(to: store.stateFileURL)
        let migrated = store.load()
        #expect(!migrated.didRecoverFromCorruption)
        #expect(migrated.migratedFromVersion == 1)
        #expect(migrated.state.schemaVersion == WorkspaceState.currentSchemaVersion)
        #expect(migrated.state.pads.first?.title == "Legacy Pad")
        #expect(migrated.state.settings.anchor == .left)

        // Sync folder snapshot test
        let syncDir = tempRoot.appendingPathComponent("SyncFolder", isDirectory: true)
        var newerState = migrated.state
        newerState.settings.widthPercent = 52.0
        newerState.updatedAt = Date().addingTimeInterval(120)
        try store.writeSyncSnapshot(for: newerState, toDirectory: syncDir)
        let synced = try store.loadNewerSyncSnapshotIfAvailable(fromDirectory: syncDir, currentState: migrated.state)
        #expect(synced?.settings.widthPercent == 52.0)
        cleanTarget = imported // silence unused mutability warning if any
    }

    // MARK: - 6. Pad Shortcuts, Closed Stack, Hibernation, Gestures & Content Rules

    @Test("Pad cycling, ⌘1-9 jump, ⌘⇧T reopen closed pad, idle hibernation, and gestures")
    func padWorkspaceAndGestures() {
        var state = WorkspaceState.makeDefault()
        let p3 = PadWorkspaceEngine.addPad(to: &state, url: URL(string: "https://example.org")!, title: "Example")
        #expect(state.selectedPadID == p3.id)

        // ⌘1 jumps to first pad
        let firstID = state.pads[0].id
        #expect(PadWorkspaceEngine.selectPadByShortcutNumber(1, in: &state) == firstID)

        // ⌃Tab cycles forward
        let secondID = state.pads[1].id
        #expect(PadWorkspaceEngine.cyclePad(forward: true, in: &state) == secondID)

        // Remove second pad, then ⌘⇧T restores it at original index
        let removed = PadWorkspaceEngine.removePad(id: secondID, from: &state)
        #expect(removed?.id == secondID)
        #expect(state.pads.count == 2)

        let restored = PadWorkspaceEngine.reopenLastClosedPad(in: &state)
        #expect(restored?.id == secondID)
        #expect(state.pads[1].id == secondID)

        // Idle hibernation marks inactive background pads hibernated, sparing selected pad
        let oldDate = Date().addingTimeInterval(-3600)
        for i in state.pads.indices {
            state.pads[i].lastActiveAt = oldDate
        }
        state.settings.autoHibernateMinutes = 15
        let hibernated = PadWorkspaceEngine.hibernateIdlePads(in: &state, now: Date())
        #expect(hibernated.count == 2)
        #expect(!hibernated.contains(secondID))

        // Gesture engine: swipe on chrome cycles pad; discrete swipe toward right edge hides
        var gesture = GestureRecognizerEngine(threshold: 50)
        _ = gesture.handleScroll(deltaX: -30, deltaY: 2, phase: .began, anchor: .right, onChromeArea: true)
        let action = gesture.handleScroll(deltaX: -25, deltaY: 1, phase: .changed, anchor: .right, onChromeArea: true)
        #expect(action == .nextPad)
        #expect(GestureRecognizerEngine.handleDiscreteSwipe(appKitDeltaX: -1.0, anchor: .right) == .hidePanel)
    }

    @Test("CSS/JS URL pattern matching and WKContentRuleList JSON compilation")
    func contentRulesAndAdBlocker() throws {
        let rule = InjectionRule(
            name: "Clean Reader",
            urlPattern: "*://*.example.com/*",
            css: "body { max-width: 720px; }",
            javascript: "console.log('injected');"
        )
        let hitURL = URL(string: "https://blog.example.com/post/1")!
        let missURL = URL(string: "https://other.org/")!
        #expect(ContentRulesEngine.matchingInjectionRules(for: hitURL, from: [rule]).count == 1)
        #expect(ContentRulesEngine.matchingInjectionRules(for: missURL, from: [rule]).isEmpty)

        let script = ContentRulesEngine.makeCSSInjectionScript(css: rule.css, ruleID: rule.id)
        #expect(script?.contains("max-width: 720px") == true)

        let blocker = ContentBlockerSettings(
            isEnabled: true,
            useBuiltInAdBlockRules: true,
            blockedDomains: ["ads.badtracker.test"]
        )
        let json = try ContentRulesEngine.buildContentRuleListJSON(from: blocker)
        #expect(json != nil)
        let parsedArray = try JSONSerialization.jsonObject(with: Data((json ?? "[]").utf8)) as? [[String: Any]]
        #expect((parsedArray?.count ?? 0) >= 3)
        let filters = parsedArray?.compactMap { ($0["trigger"] as? [String: Any])?["url-filter"] as? String } ?? []
        #expect(filters.contains(where: { $0.contains("ads\\.badtracker\\.test") }))
    }

    // MARK: - 7. URL Scheme, CLI (`veypanectl`), and Localhost Automation Server

    private final class MockIPCSender: IPCSender, @unchecked Sendable {
        var actions: [VeypaneAutomationAction] = []
        func send(_ action: VeypaneAutomationAction) throws {
            actions.append(action)
        }
    }

    @Test("URL scheme parsing & veypanectl CLI operations in isolated store")
    func urlSchemeAndCLI() {
        let openURL = URL(string: "veypane://open?url=https%3A%2F%2Fswift.org&pad=Search")!
        let parsed = VeypaneURLCommand.parse(openURL)
        #expect(parsed == .openURL(url: URL(string: "https://swift.org")!, padQuery: "Search", inNewPad: false))

        let roundTrip = VeypaneURLCommand.makeURL(for: .togglePanel)
        #expect(roundTrip?.absoluteString == "veypane://toggle")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneCLI-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ipc = MockIPCSender()
        let addOut = VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", tempDir.path, "add", "docs.swift.org", "--title", "Swift Docs"],
            ipcSender: ipc
        )
        #expect(addOut.exitCode == 0)
        #expect(addOut.stdout.contains("Swift Docs"))

        let listOut = VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", tempDir.path, "--json", "list"],
            ipcSender: ipc
        )
        #expect(listOut.exitCode == 0)
        #expect(listOut.stdout.contains("https:\\/\\/docs.swift.org") || listOut.stdout.contains("https://docs.swift.org"))

        let toggleOut = VeypaneCLIRunner.run(
            arguments: ["veypanectl", "toggle"],
            ipcSender: ipc
        )
        #expect(toggleOut.exitCode == 0)
        #expect(ipc.actions.contains(.togglePanel))
    }

    private actor MockAutomationBridge: AutomationRuntimeBridge {
        var pads: [AutomationPadSummary] = [
            AutomationPadSummary(
                id: "pad-1",
                title: "Docs",
                url: "https://docs.swift.org",
                isSelected: true,
                isHibernated: false,
                isMuted: false,
                badge: nil
            )
        ]
        var panelVisible = false

        func listPads() async -> [AutomationPadSummary] {
            pads
        }

        func getPageSnapshot(padQuery: String?) async throws -> AutomationPageSnapshot {
            AutomationPageSnapshot(padID: "pad-1", title: "Docs", url: pads[0].url, text: "Welcome to Swift")
        }

        func navigate(padQuery: String?, to url: URL) async throws -> AutomationPadSummary {
            pads[0].url = url.absoluteString
            return pads[0]
        }

        func evaluateLimitedJS(padQuery: String?, script: String) async throws -> String {
            "42"
        }

        func togglePanel(visible: Bool?) async -> Bool {
            panelVisible = visible ?? !panelVisible
            return panelVisible
        }
    }

    @Test("Localhost (127.0.0.1) automation & MCP server enforces opt-in, bearer token, and JS guard")
    func localAutomationServerEndToEnd() async throws {
        let bridge = MockAutomationBridge()

        // 1. Default settings: off by default -> refuses to start
        let disabledServer = LocalAutomationServer(settings: AutomationSettings(), bridge: bridge)
        await #expect(throws: LocalAutomationServerError.self) {
            try await disabledServer.start()
        }

        // 2. Opt-in on ephemeral loopback port 0 with secret token, JS disabled initially
        let secret = "test-secret-token-12345"
        let enabledSettings = AutomationSettings(
            isEnabled: true,
            port: 0,
            authToken: secret,
            allowLimitedJS: false
        )
        let server = LocalAutomationServer(settings: enabledSettings, bridge: bridge)
        try await server.start()
        defer { Task { await server.stop() } }

        guard let port = await server.boundPort else {
            Issue.record("Expected ephemeral bound port")
            return
        }

        // Missing token -> 401 Unauthorized
        let unauthURL = URL(string: "http://127.0.0.1:\(port)/v1/pads")!
        let (_, unauthResp) = try await URLSession.shared.data(from: unauthURL)
        #expect((unauthResp as? HTTPURLResponse)?.statusCode == 401)

        // Valid token -> 200 OK with pad list
        var listReq = URLRequest(url: unauthURL)
        listReq.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        let (listData, listResp) = try await URLSession.shared.data(for: listReq)
        #expect((listResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: listData, as: UTF8.self).contains("docs.swift.org"))

        // JS eval when allowLimitedJS == false -> 403 Forbidden
        var evalReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pads/eval")!)
        evalReq.httpMethod = "POST"
        evalReq.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        evalReq.httpBody = Data(#"{"script":"1+1"}"#.utf8)
        let (_, evalForbidden) = try await URLSession.shared.data(for: evalReq)
        #expect((evalForbidden as? HTTPURLResponse)?.statusCode == 403)

        // MCP JSON-RPC tools/call `navigate_pad`
        var mcpReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        mcpReq.httpMethod = "POST"
        mcpReq.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        mcpReq.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"navigate_pad","arguments":{"url":"https://swift.org"}}}"#.utf8)
        let (mcpData, mcpResp) = try await URLSession.shared.data(for: mcpReq)
        #expect((mcpResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: mcpData, as: UTF8.self).contains("swift.org"))

        await server.stop()
    }

    // MARK: - 8. Additional Edge Cases Across All Phases

    @Test("All six screen anchor trigger zones stay inside screen bounds")
    func triggerZonesAllSixAnchors() {
        let screen = CGRect(x: 100, y: 50, width: 2560, height: 1440)
        for anchor in AnchorPosition.allCases {
            let zone = PanelGeometry.triggerZone(screenFrame: screen, anchor: anchor, thickness: 6, cornerSpan: 50)
            #expect(screen.contains(zone))
            if anchor.isCorner {
                #expect(zone.width == 50 && zone.height == 50)
            } else {
                #expect(zone.width == 6)
            }
        }
    }

    @Test("Full-screen active app suppresses hot-edge trigger when configured")
    func fullScreenSuppressesEdgeTrigger() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let panel = CGRect(x: 900, y: 40, width: 520, height: 820)
        var engine = EdgeTriggerEngine()
        let settings = EdgeTriggerSettings(dwellMilliseconds: 0, ignoreInFullScreenApps: true)
        let ctx = PointerContext(
            location: CGPoint(x: 1439, y: 450),
            timestamp: 1.0,
            screenFrame: screen,
            visiblePanelFrame: panel,
            isFullScreenAppActive: true
        )
        #expect(engine.evaluate(context: ctx, anchor: .right, settings: settings) == .none)
    }

    @Test("IPv6, file URLs, regex injection patterns, and custom content rule validation")
    func ipv6RegexAndRuleValidation() throws {
        #expect(OmniboxParser.resolve(input: "[::1]:8080/status") ==
                .directURL(URL(string: "http://[::1]:8080/status")!))
        #expect(OmniboxParser.resolve(input: "about:blank") ==
                .directURL(URL(string: "about:blank")!))

        let regexRule = InjectionRule(
            name: "Regex Match",
            urlPattern: #"re:^https://(docs|developer)\.apple\.com/"#,
            javascript: "void(0);"
        )
        #expect(ContentRulesEngine.matchingInjectionRules(
            for: URL(string: "https://developer.apple.com/swift/")!,
            from: [regexRule]
        ).count == 1)

        let badCustom = ContentBlockerSettings(
            isEnabled: true,
            useBuiltInAdBlockRules: false,
            customRuleListJSON: #"[{"not_a_trigger": 1}]"#
        )
        #expect(throws: ContentRuleValidationError.missingTriggerOrAction) {
            _ = try ContentRulesEngine.buildContentRuleListJSON(from: badCustom)
        }
    }

    @Test("IPC payload round-trip, URL scheme actions, CLI merge import, and MCP JS eval when enabled")
    func ipcMergeImportAndMCPTools() async throws {
        // IPC round-trip
        let action: VeypaneAutomationAction = .addPad(
            url: URL(string: "https://webkit.org")!,
            title: "WebKit",
            profileName: "Work"
        )
        let encoded = try VeypaneIPC.encode(action)
        #expect(try VeypaneIPC.decode(encoded) == action)

        // URL scheme round-trip for add/remove/select/show/hide
        for item in [
            VeypaneAutomationAction.showPanel,
            .hidePanel,
            .removePad(padQuery: "Search"),
            .selectPad(padQuery: "Wikipedia"),
            action
        ] {
            let url = try #require(VeypaneURLCommand.makeURL(for: item))
            #expect(VeypaneURLCommand.parse(url) == item)
        }

        // CLI export + merge import + select + open + remove
        let dirA = FileManager.default.temporaryDirectory.appendingPathComponent("VeypaneMergeA-\(UUID().uuidString)", isDirectory: true)
        let dirB = FileManager.default.temporaryDirectory.appendingPathComponent("VeypaneMergeB-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: dirA)
            try? FileManager.default.removeItem(at: dirB)
        }
        let ipc = MockIPCSender()
        _ = VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", dirA.path, "add", "https://webkit.org", "--title", "WebKit"], ipcSender: ipc)
        let exportFile = dirA.appendingPathComponent("exported.json")
        #expect(VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", dirA.path, "export", exportFile.path], ipcSender: ipc).exitCode == 0)

        _ = VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", dirB.path, "add", "https://swift.org", "--title", "Swift"], ipcSender: ipc)
        #expect(VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", dirB.path, "import", exportFile.path, "--merge"], ipcSender: ipc).exitCode == 0)

        let mergedList = VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", dirB.path, "list"], ipcSender: ipc)
        #expect(mergedList.stdout.contains("WebKit"))
        #expect(mergedList.stdout.contains("Swift"))

        #expect(VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", dirB.path, "select", "WebKit"], ipcSender: ipc).exitCode == 0)
        #expect(VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", dirB.path, "open", "https://apple.com", "--pad", "WebKit"], ipcSender: ipc).exitCode == 0)
        #expect(VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", dirB.path, "remove", "WebKit"], ipcSender: ipc).exitCode == 0)

        // MCP initialize + tools/list + run_limited_js when allowLimitedJS == true
        let bridge = MockAutomationBridge()
        let server = LocalAutomationServer(
            settings: AutomationSettings(isEnabled: true, port: 0, authToken: "tok999", allowLimitedJS: true),
            bridge: bridge
        )
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort)

        var initReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        initReq.httpMethod = "POST"
        initReq.setValue("tok999", forHTTPHeaderField: "X-Veypane-Token")
        initReq.httpBody = Data(#"{"jsonrpc":"2.0","id":10,"method":"initialize"}"#.utf8)
        let (initData, initResp) = try await URLSession.shared.data(for: initReq)
        #expect((initResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: initData, as: UTF8.self).contains("Veypane"))

        var jsReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        jsReq.httpMethod = "POST"
        jsReq.setValue("tok999", forHTTPHeaderField: "X-Veypane-Token")
        jsReq.httpBody = Data(#"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"run_limited_js","arguments":{"script":"21*2"}}}"#.utf8)
        let (jsData, jsResp) = try await URLSession.shared.data(for: jsReq)
        #expect((jsResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: jsData, as: UTF8.self).contains("42"))

        await server.stop()
    }

    // MARK: - 9. Round 3 UX Redesign, Content API Seam, Localization & UI Verification Hooks

    private struct StubWebPageContentSession: WebPageContentSession {
        var ready: Bool
        var title: String?
        var url: URL?
        var bodyInnerText: String?
        var documentTextContent: String?

        func ensureLoadedAndWaitUntilReady(timeoutSeconds: TimeInterval) async -> Bool {
            ready
        }

        func currentTitle() async -> String? {
            title
        }

        func currentURL() async -> URL? {
            url
        }

        func extractBodyInnerText() async -> String? {
            bodyInnerText
        }

        func extractDocumentTextContent() async -> String? {
            documentTextContent
        }
    }

    private actor TimeoutAutomationBridge: AutomationRuntimeBridge {
        func listPads() async -> [AutomationPadSummary] { [] }
        func getPageSnapshot(padQuery: String?) async throws -> AutomationPageSnapshot {
            throw AutomationBridgeError.pageLoadTimedOut(
                title: "Slow Page",
                url: "https://slow.example.com",
                timeoutSeconds: 10.0
            )
        }
        func navigate(padQuery: String?, to url: URL) async throws -> AutomationPadSummary {
            throw AutomationBridgeError.padNotFound("none")
        }
        func evaluateLimitedJS(padQuery: String?, script: String) async throws -> String { "" }
        func togglePanel(visible: Bool?) async -> Bool { false }
    }

    @Test("PageContentExtractor innerText truncation, textContent fallback, and HTTP 504 timeout error")
    func pageContentExtractorAndTimeout504() async throws {
        let fallbackURL = URL(string: "https://example.com")!

        // 1. Normal innerText extraction + 16,000-character limit
        let oversized = String(repeating: "A", count: 18_500)
        let innerSession = StubWebPageContentSession(
            ready: true,
            title: "Example Domain",
            url: fallbackURL,
            bodyInnerText: "  \(oversized)  ",
            documentTextContent: "Should not be used"
        )
        let snap1 = try await PageContentExtractor.extractSnapshot(
            padID: "pad-1",
            fallbackTitle: "Fallback",
            fallbackURL: fallbackURL,
            session: innerSession
        )
        #expect(snap1.title == "Example Domain")
        #expect(snap1.url == "https://example.com")
        #expect(snap1.text.count == 16_000)

        // 2. Empty innerText falls back to document.documentElement.textContent
        let fallbackSession = StubWebPageContentSession(
            ready: true,
            title: nil,
            url: URL(string: "https://example.com/app")!,
            bodyInnerText: "   \n\t  ",
            documentTextContent: "  Fallback text from documentElement  "
        )
        let snap2 = try await PageContentExtractor.extractSnapshot(
            padID: "pad-2",
            fallbackTitle: "Stored Title",
            fallbackURL: fallbackURL,
            session: fallbackSession
        )
        #expect(snap2.title == "Stored Title")
        #expect(snap2.url == "https://example.com/app")
        #expect(snap2.text == "Fallback text from documentElement")

        // 3. Load timeout throws pageLoadTimedOut and server maps it to HTTP 504 JSON error
        let timeoutSession = StubWebPageContentSession(
            ready: false,
            title: "Loading Docs",
            url: URL(string: "https://slow.example.com")!,
            bodyInnerText: nil,
            documentTextContent: nil
        )
        await #expect(throws: AutomationBridgeError.self) {
            _ = try await PageContentExtractor.extractSnapshot(
                padID: "pad-3",
                fallbackTitle: "Fallback",
                fallbackURL: fallbackURL,
                session: timeoutSession,
                timeoutSeconds: 0.05
            )
        }

        let server = LocalAutomationServer(
            settings: AutomationSettings(isEnabled: true, port: 0, authToken: "timeout-tok"),
            bridge: TimeoutAutomationBridge()
        )
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort)

        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/pads/content")!)
        req.setValue("Bearer timeout-tok", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        #expect((resp as? HTTPURLResponse)?.statusCode == 504)
        let bodyText = String(decoding: data, as: UTF8.self)
        #expect(bodyText.contains("error"))
        #expect(bodyText.contains("slow.example.com"))

        await server.stop()
    }

    @Test("Pad strip drag-reorder persistence round-trip in VeypaneStore")
    func padStripReorderPersistence() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneReorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = VeypaneStore(directoryURL: tempDir)
        var state = store.load().state
        let added = PadWorkspaceEngine.addPad(
            to: &state,
            url: URL(string: "https://news.ycombinator.com")!,
            title: "Hacker News"
        )
        #expect(state.pads.count >= 3)

        let originalFirstID = state.pads[0].id
        PadWorkspaceEngine.reorderPad(draggedID: added.id, before: originalFirstID, in: &state)
        #expect(state.pads.first?.id == added.id)

        try store.save(state)
        let reloaded = store.load().state
        #expect(reloaded.pads.first?.id == added.id)
        #expect(reloaded.pads.first?.title == "Hacker News")
        #expect(reloaded.pads.dropFirst().first?.id == originalFirstID)
    }

    @Test("Add-pad suggestion ranking prioritizes direct action, prefix matches, and deduplicates URLs")
    func addPadSuggestionRanking() {
        let existingPad = Pad(
            title: "Swift Documentation",
            url: URL(string: "https://docs.swift.org")!
        )
        let history = [
            RecentHistoryEntry(title: "Swift Forums", url: URL(string: "https://forums.swift.org")!),
            RecentHistoryEntry(title: "Duplicate Swift Docs", url: URL(string: "https://docs.swift.org/")!)
        ]
        let favorites = [
            FavoriteItem(title: "Wikipedia", url: URL(string: "https://www.wikipedia.org")!),
            FavoriteItem(title: "Swift Evolution", url: URL(string: "https://www.swift.org/swift-evolution")!)
        ]

        // Empty query lists existing pads, history, and favorites without a direct action row
        let emptyResults = AddPadSuggestionEngine.rankSuggestions(
            query: "",
            favorites: favorites,
            recentHistory: history,
            existingPads: [existingPad]
        )
        #expect(emptyResults.first?.source != .directAction)
        // docs.swift.org and docs.swift.org/ are deduplicated
        let docsMatches = emptyResults.filter { $0.url.host == "docs.swift.org" }
        #expect(docsMatches.count == 1)

        // Query "swift" puts direct search action first, followed by ranked Swift matches (excluding Wikipedia)
        let swiftResults = AddPadSuggestionEngine.rankSuggestions(
            query: "swift",
            favorites: favorites,
            recentHistory: history,
            existingPads: [existingPad]
        )
        #expect(swiftResults.first?.source == .directAction)
        #expect(!swiftResults.contains(where: { $0.title == "Wikipedia" }))
        #expect(swiftResults.contains(where: { $0.existingPadID == existingPad.id }))
        #expect(swiftResults.contains(where: { $0.title == "Swift Forums" }))

        // Domain query produces direct URL action at index 0
        let domainResults = AddPadSuggestionEngine.rankSuggestions(
            query: "example.com",
            favorites: favorites,
            recentHistory: history,
            existingPads: [existingPad]
        )
        #expect(domainResults.first?.source == .directAction)
        #expect(domainResults.first?.url == URL(string: "https://example.com"))
    }

    @Test("Round 3 default floating card geometry (66% x 76%, 14pt inset) and CLI show auto-hide guard")
    func floatingCardGeometryAndCLIShowGuard() {
        let defaults = AppSettings()
        #expect(defaults.widthPercent == 66.0)
        #expect(defaults.heightPercent == 76.0)
        #expect(defaults.edgeInset == 14.0)
        #expect(defaults.animationDuration == 0.22)
        #expect(defaults.appearance.cornerRadius == 12.0)
        #expect(defaults.edgeTrigger.dismissGraceMilliseconds == 400)

        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1055)
        let card = PanelGeometry.visibleFrame(
            screenVisibleFrame: screen,
            anchor: .right,
            defaultWidthPercent: defaults.widthPercent,
            defaultHeightPercent: defaults.heightPercent,
            edgeInset: defaults.edgeInset
        )
        #expect(abs(card.width - 1267) <= 1)
        #expect(abs(card.height - 802) <= 1)
        #expect(screen.maxX - card.maxX == 14)
        #expect(card.minY >= screen.minY + 14)
        #expect(card.maxY <= screen.maxY - 14)

        // When panel is opened via CLI/hotkey while cursor is far away, it must NOT auto-hide until pointer visits
        var engine = EdgeTriggerEngine()
        engine.setPanelVisible(true, pointerAlreadyInside: false)
        let farPointer = PointerContext(
            location: CGPoint(x: 100, y: 500),
            timestamp: 20.0,
            screenFrame: screen,
            visiblePanelFrame: card
        )
        #expect(engine.evaluate(context: farPointer, anchor: .right, settings: defaults.edgeTrigger) == .none)
        var laterFar = farPointer
        laterFar.timestamp = 25.0
        #expect(engine.evaluate(context: laterFar, anchor: .right, settings: defaults.edgeTrigger) == .none)
        #expect(engine.phase == .visible)

        // Once pointer enters the card and then leaves for > 0.4s, it hides cleanly
        let inside = PointerContext(
            location: CGPoint(x: card.midX, y: card.midY),
            timestamp: 26.0,
            screenFrame: screen,
            visiblePanelFrame: card
        )
        #expect(engine.evaluate(context: inside, anchor: .right, settings: defaults.edgeTrigger) == .none)
        #expect(engine.hasPointerEnteredSinceShow == true)

        var leftAt27 = farPointer
        leftAt27.timestamp = 27.0
        #expect(engine.evaluate(context: leftAt27, anchor: .right, settings: defaults.edgeTrigger) == .none)
        var leftAfterGrace = farPointer
        leftAfterGrace.timestamp = 27.45
        #expect(engine.evaluate(context: leftAfterGrace, anchor: .right, settings: defaults.edgeTrigger) == .hidePanel)
    }

    @Test("English and Simplified Chinese (zh-Hans) localization lookup")
    func localizationLookupEnAndZhHans() {
        #expect(L10n.resolvedLanguageCode(preferred: ["zh-Hans-CN", "en-US"]) == "zh-Hans")
        #expect(L10n.resolvedLanguageCode(preferred: ["zh-CN"]) == "zh-Hans")
        #expect(L10n.resolvedLanguageCode(preferred: ["en-GB", "zh-Hans"]) == "en")
        #expect(L10n.resolvedLanguageCode(preferred: ["fr-FR"]) == "en")

        #expect(L10n.string("settings.pane.general", language: "en") == "General")
        #expect(L10n.string("settings.pane.general", language: "zh-Hans") == "通用")
        #expect(L10n.string("settings.pane.trigger", language: "zh-Hans") == "触发方式")
        #expect(L10n.string("add_pad.placeholder", language: "en") == "Search or enter website")
        #expect(L10n.string("add_pad.placeholder", language: "zh-Hans") == "搜索或输入网址")
        #expect(L10n.string("welcome.try_now", language: "zh-Hans") == "立即体验")
    }

    @Test("UI verification state file and veypanectl ui subcommands")
    func uiStateAndCLIVerificationHooks() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneUIState-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = VeypaneStore(directoryURL: tempDir)
        let snapshot = UIStateSnapshot(
            statusItem: true,
            statusItemVisible: true,
            panelVisible: true,
            panelFrame: "{{639, 126}, {1267, 802}}",
            selectedPad: "Example",
            selectedPadLoading: false,
            settingsVisible: false,
            welcomeVisible: false,
            pid: 4242
        )
        try store.writeUIState(snapshot)
        let readBack = try store.readUIState()
        #expect(readBack.panelVisible == true)
        #expect(readBack.selectedPad == "Example")

        let ipc = MockIPCSender()
        let stateOut = VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", tempDir.path, "ui", "state"],
            ipcSender: ipc
        )
        #expect(stateOut.exitCode == 0)
        #expect(stateOut.stdout.contains("\"panelVisible\""))
        #expect(stateOut.stdout.contains("\"statusItem\""))

        let settingsOut = VeypaneCLIRunner.run(
            arguments: ["veypanectl", "ui", "open-settings", "trigger"],
            ipcSender: ipc
        )
        #expect(settingsOut.exitCode == 0)
        #expect(ipc.actions.contains(.openSettings(pane: "trigger")))

        let welcomeOut = VeypaneCLIRunner.run(
            arguments: ["veypanectl", "ui", "show-welcome"],
            ipcSender: ipc
        )
        #expect(welcomeOut.exitCode == 0)
        #expect(ipc.actions.contains(.showWelcome))

        // Verify Notification userInfo extraction used by DistributedIPCReceiver
        let payload = try VeypaneIPC.encode(.showPanel)
        let note = Notification(
            name: VeypaneIPC.distributedNotificationName,
            object: nil,
            userInfo: [VeypaneIPC.payloadUserInfoKey: payload]
        )
        #expect(VeypaneIPC.extractAction(from: note) == .showPanel)
    }

    // MARK: - 10. Round 4 Web Extensions, CRX/ZIP Unpacking, Migration & /v1/extensions Auth

    private static func appendLE32(_ value: UInt32, to data: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }

    @Test("CRX2 and CRX3 synthetic header stripping extracts exact ZIP payload")
    func crxHeaderStrippingV2AndV3() throws {
        let syntheticZipPayload = Data([0x50, 0x4B, 0x03, 0x04, 0xAA, 0xBB, 0xCC, 0xDD, 0xEE])

        // 1. Synthetic CRX2: "Cr24" + version(2) + pubKeyLen(5) + sigLen(7) + pubKey + sig + zip
        var crx2 = Data("Cr24".utf8)
        Self.appendLE32(2, to: &crx2)
        Self.appendLE32(5, to: &crx2)
        Self.appendLE32(7, to: &crx2)
        crx2.append(Data([1, 2, 3, 4, 5]))
        crx2.append(Data([10, 20, 30, 40, 50, 60, 70]))
        crx2.append(syntheticZipPayload)

        let strippedV2 = try ExtensionPackageInstaller.stripCRXHeader(crx2)
        #expect(strippedV2 == syntheticZipPayload)

        // 2. Synthetic CRX3: "Cr24" + version(3) + headerLen(9) + protoHeader + zip
        var crx3 = Data("Cr24".utf8)
        Self.appendLE32(3, to: &crx3)
        Self.appendLE32(9, to: &crx3)
        crx3.append(Data([9, 8, 7, 6, 5, 4, 3, 2, 1]))
        crx3.append(syntheticZipPayload)

        let strippedV3 = try ExtensionPackageInstaller.stripCRXHeader(crx3)
        #expect(strippedV3 == syntheticZipPayload)

        // 3. Invalid magic & unsupported version & truncated header errors
        #expect(throws: ExtensionInstallError.invalidCRXMagic) {
            _ = try ExtensionPackageInstaller.stripCRXHeader(Data("NOPE000000000000".utf8))
        }
        var badVer = Data("Cr24".utf8)
        Self.appendLE32(99, to: &badVer)
        Self.appendLE32(0, to: &badVer)
        #expect(throws: ExtensionInstallError.unsupportedCRXVersion(99)) {
            _ = try ExtensionPackageInstaller.stripCRXHeader(badVer)
        }
        var truncatedV3 = Data("Cr24".utf8)
        Self.appendLE32(3, to: &truncatedV3)
        Self.appendLE32(500, to: &truncatedV3)
        truncatedV3.append(Data([1, 2, 3]))
        #expect(throws: ExtensionInstallError.truncatedCRXHeader) {
            _ = try ExtensionPackageInstaller.stripCRXHeader(truncatedV3)
        }
    }

    @Test("ZIP nested-manifest detection, untouched extension copy, CRX3 install, and CLI lifecycle")
    func zipNestedManifestAndExtensionInstallLifecycle() throws {
        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("VeypaneExtPkg-\(UUID().uuidString)", isDirectory: true)
        let storeDir = fm.temporaryDirectory.appendingPathComponent("VeypaneExtStore-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fm.removeItem(at: workDir)
            try? fm.removeItem(at: storeDir)
        }

        // Build a synthetic MV3 extension nested one level inside an outer folder
        let stagingOuter = workDir.appendingPathComponent("outer-wrapper", isDirectory: true)
        let nestedExtDir = stagingOuter.appendingPathComponent("sample-translator-mv3", isDirectory: true)
        let localesDir = nestedExtDir.appendingPathComponent("_locales/en", isDirectory: true)
        try fm.createDirectory(at: localesDir, withIntermediateDirectories: true)

        let manifestBytes = Data(#"""
        {
          "manifest_version": 3,
          "name": "__MSG_extTitle__",
          "version": "2.4.1",
          "default_locale": "en",
          "permissions": ["storage", "activeTab"],
          "host_permissions": ["<all_urls>"],
          "content_scripts": [
            {
              "matches": ["*://*.wikipedia.org/*"],
              "js": ["content.js"]
            }
          ]
        }
        """#.utf8)
        let messagesBytes = Data(#"{"extTitle":{"message":"Sample Page Translator"}}"#.utf8)
        let contentJSBytes = Data("console.log('untouched extension content script');\n".utf8)

        try manifestBytes.write(to: nestedExtDir.appendingPathComponent("manifest.json"))
        try messagesBytes.write(to: localesDir.appendingPathComponent("messages.json"))
        try contentJSBytes.write(to: nestedExtDir.appendingPathComponent("content.js"))

        // Create .zip containing the 1-level nested folder via /usr/bin/ditto -c -k --keepParent
        let zipFile = workDir.appendingPathComponent("nested-ext.zip")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        proc.arguments = ["-c", "-k", "--keepParent", nestedExtDir.path, zipFile.path]
        try proc.run()
        proc.waitUntilExit()
        #expect(proc.terminationStatus == 0)

        // Wrap that .zip in a synthetic CRX3 container as well
        let rawZipData = try Data(contentsOf: zipFile)
        var crx3Data = Data("Cr24".utf8)
        Self.appendLE32(3, to: &crx3Data)
        Self.appendLE32(4, to: &crx3Data)
        crx3Data.append(Data([0x01, 0x02, 0x03, 0x04]))
        crx3Data.append(rawZipData)
        let crxFile = workDir.appendingPathComponent("nested-ext.crx")
        try crx3Data.write(to: crxFile)

        // Install from .zip via veypanectl extensions add
        let ipc = MockIPCSender()
        let addOut = VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", storeDir.path, "extensions", "add", zipFile.path],
            ipcSender: ipc
        )
        #expect(addOut.exitCode == 0)
        #expect(addOut.stdout.contains("Sample Page Translator"))
        #expect(ipc.actions.contains(.syncExtensionsFromStore))

        // Delete original staging & zip to verify installed copy in <store>/Extensions/<extID> survives untouched
        try fm.removeItem(at: stagingOuter)
        try fm.removeItem(at: zipFile)

        let store = VeypaneStore(directoryURL: storeDir)
        let loaded = store.load().state
        #expect(loaded.installedExtensions.count == 1)
        let ext = try #require(loaded.installedExtensions.first)
        #expect(ext.displayName == "Sample Page Translator")
        #expect(ext.version == "2.4.1")
        #expect(ext.enabled == true)
        #expect(ext.allURLsGranted == true)
        #expect(ext.grantedPermissions.contains("storage"))
        let firstUniqueContextID = ext.contextUniqueIdentifier

        let copiedDir = store.extensionsDirectoryURL.appendingPathComponent(ext.folderName, isDirectory: true)
        #expect(try Data(contentsOf: copiedDir.appendingPathComponent("manifest.json")) == manifestBytes)
        #expect(try Data(contentsOf: copiedDir.appendingPathComponent("content.js")) == contentJSBytes)

        // Re-installing from .crx preserves contextUniqueIdentifier so chrome.storage survives updates
        let reinstall = try ExtensionPackageInstaller.installExtensionPackage(
            from: crxFile,
            extensionsRootDirectory: store.extensionsDirectoryURL,
            existingExtensions: loaded.installedExtensions
        )
        #expect(reinstall.id == ext.id)
        #expect(reinstall.contextUniqueIdentifier == firstUniqueContextID)

        // CLI list (--json), disable, enable, command, remove
        let listJSON = VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", storeDir.path, "--json", "extensions", "list"],
            ipcSender: ipc
        )
        #expect(listJSON.exitCode == 0)
        #expect(listJSON.stdout.contains("Sample Page Translator"))

        #expect(VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", storeDir.path, "extensions", "disable", ext.id],
            ipcSender: ipc
        ).exitCode == 0)
        #expect(store.load().state.installedExtensions.first?.enabled == false)

        #expect(VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", storeDir.path, "extensions", "enable", ext.id],
            ipcSender: ipc
        ).exitCode == 0)
        #expect(store.load().state.installedExtensions.first?.enabled == true)

        #expect(VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", storeDir.path, "extensions", "command", ext.id, "toggleTranslatePage"],
            ipcSender: ipc
        ).exitCode == 0)
        #expect(ipc.actions.contains(.performExtensionCommand(
            extensionQuery: ext.id,
            commandID: "toggleTranslatePage",
            padQuery: nil
        )))

        #expect(VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", storeDir.path, "extensions", "remove", ext.id],
            ipcSender: ipc
        ).exitCode == 0)
        #expect(store.load().state.installedExtensions.isEmpty)
        #expect(!fm.fileExists(atPath: copiedDir.path))
    }

    @Test("InstalledExtension persistence, v4 -> v5 migration, and legacy panel width (34% / 653 pt) migration")
    func extensionPersistenceAndPanelWidthDefaultMigration() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneMigV5-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // 1. Legacy v4 workspace with old 34% x 94% default (and legacy fixedWidth 653) migrates to 66% x 76%
        let legacyV4JSON = #"""
        {
          "schemaVersion": 4,
          "pads": [],
          "profiles": [],
          "settings": {
            "widthPercent": 34.0,
            "heightPercent": 94.0,
            "fixedWidth": 653.0
          }
        }
        """#
        try Data(legacyV4JSON.utf8).write(to: tempDir.appendingPathComponent("workspace.json"))

        let store = VeypaneStore(directoryURL: tempDir)
        var migrated = store.load().state
        #expect(migrated.schemaVersion == WorkspaceState.currentSchemaVersion)
        #expect(migrated.settings.widthPercent == 66.0)
        #expect(migrated.settings.heightPercent == 76.0)
        #expect(migrated.settings.panelSizeUserCustomized == false)

        // 2. Also verify legacy fixedWidth == 653 migration helper directly
        var fixedLegacy = AppSettings(widthPercent: 40.0, heightPercent: 80.0, panelSizeUserCustomized: false)
        fixedLegacy.migrateLegacyPanelSizeIfNeeded(legacyFixedWidth: 653.0)
        #expect(fixedLegacy.widthPercent == 66.0)
        #expect(fixedLegacy.heightPercent == 76.0)

        // 3. Explicit user-customized size (e.g. 34% with panelSizeUserCustomized == true) is preserved across save/load
        migrated.settings.widthPercent = 34.0
        migrated.settings.heightPercent = 82.0
        migrated.settings.panelSizeUserCustomized = true
        let sampleExt = InstalledExtension(
            id: "ext-persist-1",
            folderName: "ext-persist-1",
            displayName: "Persistent Extension",
            version: "1.2.0",
            enabled: true,
            grantedPermissions: ["storage", "tabs"],
            grantedMatchPatterns: ["<all_urls>"],
            allURLsGranted: true,
            websiteAccessMode: .allWebsites,
            contextUniqueIdentifier: "ctx-stable-uuid-1234",
            pinnedToToolbar: true
        )
        migrated.installedExtensions = [sampleExt]
        let stableControllerID = migrated.webExtensionControllerID
        try store.save(migrated)

        let reloaded = store.load().state
        #expect(reloaded.settings.widthPercent == 34.0)
        #expect(reloaded.settings.heightPercent == 82.0)
        #expect(reloaded.settings.panelSizeUserCustomized == true)
        #expect(reloaded.webExtensionControllerID == stableControllerID)
        #expect(reloaded.installedExtensions.first?.contextUniqueIdentifier == "ctx-stable-uuid-1234")
        #expect(reloaded.installedExtensions.first?.displayName == "Persistent Extension")

        // Localization strings for Extensions UI in English and Simplified Chinese
        #expect(L10n.string("settings.pane.extensions", language: "en") == "Extensions")
        #expect(L10n.string("settings.pane.extensions", language: "zh-Hans") == "扩展")
        #expect(L10n.string("menu.extensions", language: "en") == "Extensions…")
        #expect(L10n.string("menu.extensions", language: "zh-Hans") == "扩展…")
    }

    private actor ExtensionAutomationMockBridge: AutomationRuntimeBridge {
        var executedCommands: [(String, String, String?)] = []

        func listPads() async -> [AutomationPadSummary] { [] }
        func getPageSnapshot(padQuery: String?) async throws -> AutomationPageSnapshot {
            throw AutomationBridgeError.padNotFound("none")
        }
        func navigate(padQuery: String?, to url: URL) async throws -> AutomationPadSummary {
            throw AutomationBridgeError.padNotFound("none")
        }
        func evaluateLimitedJS(padQuery: String?, script: String) async throws -> String { "" }
        func togglePanel(visible: Bool?) async -> Bool { true }

        func listExtensions() async -> [AutomationExtensionSummary] {
            [
                AutomationExtensionSummary(
                    id: "sample-translator",
                    name: "Sample Translator",
                    version: "1.9.0",
                    enabled: true,
                    loaded: true,
                    errors: [],
                    commands: [
                        AutomationExtensionCommand(id: "toggleTranslatePage", title: "Translate Page", shortcut: "A")
                    ]
                )
            ]
        }

        func performExtensionCommand(
            extensionQuery: String,
            commandID: String,
            padQuery: String?
        ) async throws -> AutomationExtensionCommandResult {
            guard extensionQuery == "sample-translator" || extensionQuery == "Sample Translator" else {
                throw AutomationBridgeError.extensionNotFound(extensionQuery)
            }
            guard commandID == "toggleTranslatePage" else {
                throw AutomationBridgeError.extensionCommandNotFound(commandID)
            }
            executedCommands.append((extensionQuery, commandID, padQuery))
            return AutomationExtensionCommandResult(
                ok: true,
                extensionID: "sample-translator",
                commandID: commandID
            )
        }
    }

    @Test("/v1/extensions and /v1/extensions/command enforce bearer token auth and expose MCP list_extensions")
    func extensionsAutomationRoutesAndAuth() async throws {
        let bridge = ExtensionAutomationMockBridge()
        let server = LocalAutomationServer(
            settings: AutomationSettings(isEnabled: true, port: 0, authToken: "ext-secret-token", allowLimitedJS: false),
            bridge: bridge
        )
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort)

        // 1. Unauthenticated GET /v1/extensions -> 401 Unauthorized
        let unauthListReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/extensions")!)
        let (_, unauthListResp) = try await URLSession.shared.data(for: unauthListReq)
        #expect((unauthListResp as? HTTPURLResponse)?.statusCode == 401)

        // 2. Wrong token POST /v1/extensions/command -> 401 Unauthorized
        var badTokenCmd = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/extensions/command")!)
        badTokenCmd.httpMethod = "POST"
        badTokenCmd.setValue("Bearer wrong-token", forHTTPHeaderField: "Authorization")
        badTokenCmd.httpBody = Data(#"{"extension":"sample-translator","command":"toggleTranslatePage"}"#.utf8)
        let (_, badTokenResp) = try await URLSession.shared.data(for: badTokenCmd)
        #expect((badTokenResp as? HTTPURLResponse)?.statusCode == 401)

        // 3. Authenticated GET /v1/extensions -> 200 with loaded extension & command metadata
        var authListReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/extensions")!)
        authListReq.setValue("Bearer ext-secret-token", forHTTPHeaderField: "Authorization")
        let (listData, listResp) = try await URLSession.shared.data(for: authListReq)
        #expect((listResp as? HTTPURLResponse)?.statusCode == 200)
        let listText = String(decoding: listData, as: UTF8.self)
        #expect(listText.contains("sample-translator"))
        #expect(listText.contains("toggleTranslatePage"))

        // 4. Authenticated POST /v1/extensions/command -> 200
        var cmdReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/extensions/command")!)
        cmdReq.httpMethod = "POST"
        cmdReq.setValue("Bearer ext-secret-token", forHTTPHeaderField: "Authorization")
        cmdReq.httpBody = Data(#"{"extension":"Sample Translator","command":"toggleTranslatePage","pad":"Wikipedia"}"#.utf8)
        let (cmdData, cmdResp) = try await URLSession.shared.data(for: cmdReq)
        #expect((cmdResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: cmdData, as: UTF8.self).contains("\"ok\":true"))
        let recorded = await bridge.executedCommands
        #expect(recorded.count == 1)
        #expect(recorded.first?.2 == "Wikipedia")

        // 5. MCP tools/list & tools/call for list_extensions
        var mcpListReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        mcpListReq.httpMethod = "POST"
        mcpListReq.setValue("Bearer ext-secret-token", forHTTPHeaderField: "Authorization")
        mcpListReq.httpBody = Data(#"{"jsonrpc":"2.0","id":21,"method":"tools/list"}"#.utf8)
        let (mcpToolsData, _) = try await URLSession.shared.data(for: mcpListReq)
        #expect(String(decoding: mcpToolsData, as: UTF8.self).contains("list_extensions"))

        var mcpCallReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        mcpCallReq.httpMethod = "POST"
        mcpCallReq.setValue("Bearer ext-secret-token", forHTTPHeaderField: "Authorization")
        mcpCallReq.httpBody = Data(#"{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"list_extensions","arguments":{}}}"#.utf8)
        let (mcpCallData, mcpCallResp) = try await URLSession.shared.data(for: mcpCallReq)
        #expect((mcpCallResp as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: mcpCallData, as: UTF8.self).contains("Sample Translator"))

        await server.stop()
    }

    // MARK: - 11. Round 5 Branding, Transient Address Bar, Transition Guard, Favicon & Compatibility Tests

    @Test("Transient AddressBarStateMachine covers hidden, new-pad, Cmd+L edit, draft edits, Esc cancel, and submit")
    func transientAddressBarStateMachineFlows() {
        var machine = AddressBarStateMachine()
        let padA = UUID()
        let padB = UUID()
        let initialURL = URL(string: "https://en.wikipedia.org/wiki/Swift")!

        // 1. Hidden by default on existing pads
        #expect(!machine.isVisible)
        #expect(!machine.isCreatingNewPad)
        #expect(!machine.isEditingCurrentPad)
        #expect(machine.submit() == .none)

        // 2. New pad flow (+ / Cmd+T) -> draft updates never navigate -> Return submits & hides
        machine.openForNewPad()
        #expect(machine.isVisible && machine.isCreatingNewPad)
        machine.updateDraft("webkit.org")
        #expect(machine.draftText == "webkit.org")
        #expect(machine.isVisible) // Still open; typing alone never submits
        let createEffect = machine.submit(searchEngine: .duckDuckGo)
        #expect(createEffect == .createNewPad(URL(string: "https://webkit.org")!))
        #expect(!machine.isVisible)

        // 3. Cmd+L on existing pad -> Esc cancels without navigating and restores hidden state
        machine.revealForCurrentPad(padID: padA, currentURL: initialURL)
        #expect(machine.isEditingCurrentPad)
        #expect(machine.draftText == initialURL.absoluteString)
        #expect(machine.originalURLString == initialURL.absoluteString)
        machine.updateDraft("https://malformed-unsubmitted.example")
        machine.cancel()
        #expect(!machine.isVisible)
        #expect(machine.draftText.isEmpty)

        // 4. Cmd+L on existing pad -> pad switch auto-cancels without navigating
        machine.revealForCurrentPad(padID: padA, currentURL: initialURL)
        machine.updateDraft("swift concurrency")
        machine.handleSelectedPadChanged(to: padB)
        #expect(!machine.isVisible)

        // 5. Cmd+L on existing pad -> Return resolves search/URL, navigates once, and dismisses immediately
        machine.revealForCurrentPad(padID: padB, currentURL: initialURL)
        machine.updateDraft("docs.swift.org")
        let navEffect = machine.submit(searchEngine: .duckDuckGo)
        #expect(navEffect == .navigateExistingPad(padID: padB, url: URL(string: "https://docs.swift.org")!))
        #expect(!machine.isVisible)
    }

    @Test("Generation-guarded PanelTransitionController prevents stale hide completion ghosting on rapid toggles")
    func panelTransitionRapidReversalCoherence() {
        var tc = PanelTransitionController()
        #expect(tc.phase == .hidden)
        #expect(!tc.isTargetVisible)

        // Show -> complete
        let show1 = tc.beginShow()
        #expect(show1.shouldPerformTransition)
        #expect(!show1.reversedInFlight)
        #expect(tc.phase == .showing)
        let didCompleteShow1 = tc.completeShow(generation: show1.generation)
        #expect(didCompleteShow1)
        #expect(tc.phase == .visible)

        // Begin hide, then IMMEDIATELY re-show before hide animation finishes!
        let hide1 = tc.beginHide()
        #expect(hide1.shouldPerformTransition)
        #expect(tc.phase == .hiding)

        let rapidReShow = tc.beginShow()
        #expect(rapidReShow.shouldPerformTransition)
        #expect(rapidReShow.reversedInFlight)
        #expect(tc.phase == .showing)
        #expect(tc.interruptedTransitions == 1)

        // Now hide1's async animation completion fires late — MUST return false so window is NOT ordered out!
        let staleHideAllowed = tc.completeHide(generation: hide1.generation)
        #expect(staleHideAllowed == false)
        #expect(tc.phase == .showing)
        #expect(tc.isTargetVisible)

        // Rapid show finishes cleanly
        let didCompleteRapidShow = tc.completeShow(generation: rapidReShow.generation)
        #expect(didCompleteRapidShow == true)
        #expect(tc.phase == .visible)

        // 20 rapid back-and-forth show/hide reversals end in a deterministic final state
        var lastHideGen: UInt64 = 0
        for _ in 0..<20 {
            _ = tc.beginHide()
            let s = tc.beginShow()
            _ = s
            let h = tc.beginHide()
            lastHideGen = h.generation
        }
        #expect(tc.phase == .hiding)
        let didCompleteFinalHide = tc.completeHide(generation: lastHideGen)
        #expect(didCompleteFinalHide == true)
        #expect(tc.phase == .hidden)
    }

    @Test("PadSessionPool switching seam never reloads live pads and prevents double-load on navigation")
    func padSessionLifecycleNoReloadAndSingleLoad() {
        final class FakeWebSession {
            var loadedURLs: [URL]
            var reloadCount = 0
            init(initial: URL) { self.loadedURLs = [initial] }
        }

        var pool = PadSessionPool<FakeWebSession>()
        let pads = [
            Pad(title: "One", url: URL(string: "https://one.example.com")!),
            Pad(title: "Two", url: URL(string: "https://two.example.com")!),
            Pad(title: "Three", url: URL(string: "https://three.example.com")!)
        ]

        // Warm up 3 pads
        for pad in pads {
            _ = pool.ensureSession(for: pad) { FakeWebSession(initial: $0.url) }
        }
        #expect(pool.webViewCreations == 3)
        #expect(pool.loadRequests == 3)

        // 50 switches across the 3 pads -> ZERO new creations, ZERO extra loads, ZERO reloads!
        var activeID: UUID? = pads[0].id
        for idx in 0..<50 {
            let nextPad = pads[(idx + 1) % pads.count]
            _ = pool.switchPad(from: activeID, to: nextPad) { FakeWebSession(initial: $0.url) }
            activeID = nextPad.id
        }
        #expect(pool.padSwitchCount == 50)
        #expect(pool.webViewCreations == 3)
        #expect(pool.loadRequests == 3)
        #expect(pool.reloadRequests == 0)

        // Navigating an already-live pad issues strictly 1 load request
        let dest = URL(string: "https://one.example.com/docs")!
        let s1 = pool.navigate(
            pad: pads[0],
            to: dest,
            makeAndInitialLoad: { FakeWebSession(initial: $0.url) },
            loadURLOnExisting: { session, url in session.loadedURLs.append(url) }
        )
        #expect(pool.loadRequests == 4)
        #expect(s1.loadedURLs.count == 2)

        // Navigating an uninitialized / woken pad ALSO issues strictly 1 load request (never 2!)
        let wokenPad = Pad(title: "Four", url: URL(string: "https://four.example.com")!)
        let s4 = pool.navigate(
            pad: wokenPad,
            to: URL(string: "https://four.example.com/start")!,
            makeAndInitialLoad: { FakeWebSession(initial: $0.url) },
            loadURLOnExisting: { session, url in session.loadedURLs.append(url) }
        )
        #expect(pool.webViewCreations == 4)
        #expect(pool.loadRequests == 5)
        #expect(s4.loadedURLs == [URL(string: "https://four.example.com/start")!])
    }

    @Test("FaviconCandidateSelector prefers SVG and high-DPI icons over 16x16 blurry icons")
    func highDPIFaviconCandidateRanking() throws {
        let baseURL = URL(string: "https://docs.example.com/guide/intro")!
        let rawLinks = [
            RawFaviconLink(href: "/favicon-16x16.png", rel: "icon", sizes: "16x16", mimeType: "image/png"),
            RawFaviconLink(href: "/favicon.ico", rel: "shortcut icon", sizes: "", mimeType: "image/x-icon"),
            RawFaviconLink(href: "/safari-pinned-tab.svg", rel: "mask-icon", sizes: "any", mimeType: "image/svg+xml"),
            RawFaviconLink(href: "/apple-touch-icon.png", rel: "apple-touch-icon", sizes: "180x180", mimeType: "image/png"),
            RawFaviconLink(href: "assets/icon-128.png", rel: "icon", sizes: "128x128", mimeType: "image/png")
        ]

        let ranked = FaviconCandidateSelector.rankCandidates(from: rawLinks, pageURL: baseURL, targetPixelSize: 72)
        #expect(ranked.count >= 5)

        // Top two must be the 180x180 apple-touch-icon and 128x128 PNG — never the 16x16 PNG, monochrome mask-icon, or .ico!
        let topURLs = ranked.prefix(2).map(\.url.absoluteString)
        #expect(topURLs.contains("https://docs.example.com/apple-touch-icon.png"))
        #expect(topURLs.contains("https://docs.example.com/guide/assets/icon-128.png"))

        let idx16 = try #require(ranked.firstIndex(where: { $0.url.path.contains("16x16") }))
        let idx128 = try #require(ranked.firstIndex(where: { $0.url.path.contains("icon-128.png") }))
        #expect(idx128 < idx16)

        // Scalable color SVG ranks at the very top when provided
        let withVector = rawLinks + [
            RawFaviconLink(href: "/brand-icon.svg", rel: "icon", sizes: "any", mimeType: "image/svg+xml")
        ]
        let rankedWithSVG = FaviconCandidateSelector.rankCandidates(from: withVector, pageURL: baseURL)
        #expect(rankedWithSVG.first?.url.absoluteString == "https://docs.example.com/brand-icon.svg")
        #expect(rankedWithSVG.first?.isScalableVector == true)
    }

    @Test("Stale title fix: live navigations update automatic titles while preserving hand-renamed custom titles and v5->v6 migration")
    func pageTitleUpdatesAndHandRenamedMigration() throws {
        // 1. Automatic pad updates title across multiple navigations and SPA document.title changes
        var autoPad = Pad(title: "en.wikipedia.org", url: URL(string: "https://en.wikipedia.org")!)
        #expect(autoPad.hasCustomTitle == false)
        autoPad.applyObservedPageTitle("Wikipedia, the free encyclopedia")
        #expect(autoPad.title == "Wikipedia, the free encyclopedia")

        // Second navigation previously stayed stuck on the first page's title — now updates!
        autoPad.url = URL(string: "https://en.wikipedia.org/wiki/Swift_(programming_language)")!
        autoPad.applyObservedPageTitle("(5) Swift (programming language) - Wikipedia")
        #expect(autoPad.title == "Swift (programming language) - Wikipedia")
        #expect(autoPad.badgeCount == 5)

        // 2. Explicit user rename (`hasCustomTitle = true`) preserves title while still updating unread badges
        var state = WorkspaceState(pads: [autoPad])
        PadWorkspaceEngine.renamePad(id: autoPad.id, newTitle: "Swift Wiki", in: &state)
        #expect(state.pads[0].title == "Swift Wiki")
        #expect(state.pads[0].hasCustomTitle == true)

        state.pads[0].applyObservedPageTitle("(9) Some Other Article - Wikipedia")
        #expect(state.pads[0].title == "Swift Wiki")
        #expect(state.pads[0].badgeCount == 9)

        // Resetting custom title restores automatic page title tracking
        PadWorkspaceEngine.resetCustomTitle(id: autoPad.id, fallbackPageTitle: "Restored Page Title", in: &state)
        #expect(state.pads[0].hasCustomTitle == false)
        #expect(state.pads[0].title == "Restored Page Title")

        // 3. Schema v5 -> v6 migration preserves hand-renamed existing titles while keeping automatic ones unlocked
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneMigV6-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let v5JSON = #"""
        {
          "schemaVersion": 5,
          "pads": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "My Team Dashboard",
              "url": "https://linear.app/acme/team"
            },
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "title": "Wikipedia, the free encyclopedia",
              "url": "https://en.wikipedia.org/wiki/Main_Page"
            }
          ],
          "recentHistory": [
            {
              "id": "33333333-3333-3333-3333-333333333333",
              "title": "Wikipedia, the free encyclopedia",
              "url": "https://en.wikipedia.org/wiki/Main_Page",
              "visitedAt": "2026-11-16T00:00:00Z"
            }
          ],
          "profiles": [],
          "settings": {
            "widthPercent": 66.0,
            "heightPercent": 76.0,
            "panelSizeUserCustomized": false
          }
        }
        """#
        try Data(v5JSON.utf8).write(to: tempDir.appendingPathComponent("workspace.json"))

        let store = VeypaneStore(directoryURL: tempDir)
        let migrated = store.load().state
        #expect(migrated.schemaVersion == 6)
        #expect(migrated.pads[0].title == "My Team Dashboard")
        #expect(migrated.pads[0].hasCustomTitle == true)  // Hand-renamed preserved!
        #expect(migrated.pads[1].hasCustomTitle == false) // History-matched page title stays automatic!
    }

    @Test("Veypane branding uses canonical com.veypane.app, Application Support/Veypane, veypanectl, veypane://, and safe diagnostics")
    func veypaneBrandingDataPathsAndDiagnostics() throws {
        #expect(AppBrandIdentity.productName == "Veypane")
        #expect(AppBrandIdentity.appBundleName == "Veypane.app")
        #expect(AppBrandIdentity.appArchiveName == "Veypane.zip")
        #expect(AppBrandIdentity.bundleIdentifier == "com.veypane.app")
        #expect(AppBrandIdentity.urlSchemeBundleName == "com.veypane.urlscheme")
        #expect(AppBrandIdentity.applicationSupportFolderName == "Veypane")
        #expect(AppBrandIdentity.bundleExecutableName == "VeypaneApp")

        // Default store uses ~/Library/Application Support/Veypane path
        let defaultStore = VeypaneStore()
        #expect(defaultStore.directoryURL.lastPathComponent == "Veypane")

        // Localization in en & zh-Hans uses Veypane
        #expect(L10n.string("app.name", language: "en") == "Veypane")
        #expect(L10n.string("app.name", language: "zh-Hans") == "Veypane")
        #expect(L10n.string("settings.window_title", language: "en") == "Veypane Settings")
        #expect(L10n.string("settings.window_title", language: "zh-Hans") == "Veypane 设置")
        #expect(L10n.string("menu.quit", language: "en") == "Quit Veypane")
        #expect(L10n.string("menu.quit", language: "zh-Hans") == "退出 Veypane")
        #expect(L10n.string("welcome.window_title", language: "en") == "Welcome to Veypane")
        #expect(L10n.string("welcome.window_title", language: "zh-Hans") == "欢迎使用 Veypane")

        // Primary veypane:// URL scheme parses cleanly and unsupported schemes are rejected
        let primaryURL = URL(string: "veypane://open?url=https%3A%2F%2Fwebkit.org&new=1")!
        #expect(VeypaneURLCommand.parse(primaryURL) == .openURL(url: URL(string: "https://webkit.org")!, padQuery: nil, inNewPad: true))
        let unsupportedURL = URL(string: "otherapp://open?url=https%3A%2F%2Fwebkit.org&new=1")!
        #expect(VeypaneURLCommand.parse(unsupportedURL) == nil)

        // veypanectl works + `ui diagnostics` outputs counters
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneDiag-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = VeypaneStore(directoryURL: tempDir)
        let diagCounters = RuntimeDiagnosticsCounters(
            webViewCreations: 3,
            loadRequests: 4,
            reloadRequests: 0,
            padSwitchCount: 12,
            panelShowCount: 5,
            panelHideCount: 4,
            panelInterruptedTransitions: 1,
            transitionPhase: .visible
        )
        try store.writeUIState(
            UIStateSnapshot(
                statusItem: true,
                statusItemVisible: true,
                panelVisible: true,
                panelFrame: "{{639, 126}, {1267, 772}}",
                selectedPad: "Swift",
                selectedPadLoading: false,
                settingsVisible: false,
                welcomeVisible: false,
                diagnostics: diagCounters
            )
        )

        let ipc = MockIPCSender()
        let veypaneHelp = VeypaneCLIRunner.run(arguments: ["/usr/local/bin/veypanectl", "--help"], ipcSender: ipc)
        #expect(veypaneHelp.stdout.contains("veypanectl — Veypane"))
        let veypaneScheme = VeypaneCLIRunner.run(arguments: ["veypanectl", "url", "toggle"], ipcSender: ipc)
        #expect(veypaneScheme.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "veypane://toggle")
        let fallbackScheme = VeypaneCLIRunner.run(arguments: ["custom-alias", "url", "toggle"], ipcSender: ipc)
        #expect(fallbackScheme.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "veypane://toggle")

        let diagOut = VeypaneCLIRunner.run(
            arguments: ["veypanectl", "--store", tempDir.path, "ui", "diagnostics"],
            ipcSender: ipc
        )
        #expect(diagOut.exitCode == 0)
        #expect(diagOut.stdout.contains("\"appName\" : \"Veypane\""))
        #expect(diagOut.stdout.contains("\"webViewCreations\" : 3"))
        #expect(diagOut.stdout.contains("\"padSwitchCount\" : 12"))

        // Desktop Safari UA uses standard frozen `Intel Mac OS X 10_15_7` WebKit token (never Chrome, never synthetic 14_7)
        let desktopUA = try #require(UserAgentPreset.desktopSafari.resolvedUserAgent())
        #expect(desktopUA.contains("Intel Mac OS X 10_15_7"))
        #expect(!desktopUA.contains("Chrome/"))
        #expect(!desktopUA.contains("14_7"))

        // Origin sanitizer strips path, query tokens, credentials, and fragments
        let sensitiveURL = URL(string: "https://user:secret@www.google.com:8443/sorry/index?continue=https://mail.google.com&q=token123#frag")!
        #expect(SiteCompatibilityInspector.sanitizedOrigin(for: sensitiveURL) == "https://www.google.com:8443")
        let sorryDetect = SiteCompatibilityInspector.detectPassiveVerificationGate(
            url: sensitiveURL,
            hasChallengeIframe: true,
            challengeIframeLookedBlankOrBlocked: false
        )
        #expect(sorryDetect.detected == true)
    }

    @Test("Custom Veypane multi-resolution .icns, 1024px PNG preview, and NSWorkspace bundle icon lookup")
    func customVeypaneIconAssetsAndBundleLookup() throws {
        // 1. Bundled resource lookup via L10n.iconFileURL
        let resourceIconURL = try #require(L10n.iconFileURL)
        let icnsData = try Data(contentsOf: resourceIconURL)
        #expect(icnsData.count > 100_000)
        #expect(String(decoding: icnsData.prefix(4), as: UTF8.self) == "icns")

        // Verify multi-resolution Retina/standard chunk tags inside the .icns container
        // ic11 (32px), ic12 (64px), ic07 (128px), ic08 (256px), ic09 (512px), ic10 (1024px)
        for tag in ["ic11", "ic12", "ic07", "ic08", "ic09", "ic10"] {
            #expect(icnsData.range(of: Data(tag.utf8)) != nil)
        }

        let nsIcon = try #require(NSImage(contentsOf: resourceIconURL))
        let maxPixels = nsIcon.representations.map { max($0.pixelsWide, $0.pixelsHigh) }.max() ?? 0
        #expect(maxPixels >= 1024)
        #expect(nsIcon.representations.count >= 6)

        // 2. Repo Assets/AppIcon/Veypane-1024.png preview & Veypane.app NSWorkspace lookup (when packaged)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let previewPNG = repoRoot.appendingPathComponent("Assets/AppIcon/Veypane-1024.png")
        #expect(FileManager.default.fileExists(atPath: previewPNG.path))
        let previewData = try Data(contentsOf: previewPNG)
        let previewRep = try #require(NSBitmapImageRep(data: previewData))
        #expect(previewRep.pixelsWide == 1024)
        #expect(previewRep.pixelsHigh == 1024)

        let packagedApp = repoRoot.appendingPathComponent("Veypane.app")
        if FileManager.default.fileExists(atPath: packagedApp.path) {
            let bundlePlistURL = packagedApp.appendingPathComponent("Contents/Info.plist")
            let plistDict = try #require(NSDictionary(contentsOf: bundlePlistURL) as? [String: Any])
            #expect(plistDict["CFBundleIconFile"] as? String == "Veypane")
            #expect(plistDict["CFBundleIdentifier"] as? String == "com.veypane.app")
            #expect(plistDict["CFBundleExecutable"] as? String == "VeypaneApp")
            #expect(FileManager.default.fileExists(atPath: packagedApp.appendingPathComponent("Contents/Resources/Veypane.icns").path))

            let wsIcon = NSWorkspace.shared.icon(forFile: packagedApp.path)
            #expect(wsIcon.size.width > 0 && wsIcon.size.height > 0)
            #expect(!wsIcon.representations.isEmpty)
        }
    }

    // MARK: - 10. Feedback B (t265u) & Feedback A (t264u): Corner Animation, Reversal & Evidence-Based Diagnostics

    @Test("All 6 trigger anchors slide from/to exact corner or edge across positive and negative multi-display coordinates")
    func allSixAnchorCornerAndEdgeAnimationMappingsAndMultiDisplayBounds() {
        let primary = DisplayDescriptor(
            id: 1,
            name: "Primary",
            frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
            visibleFrame: CGRect(x: 0, y: 54, width: 1512, height: 890),
            isMain: true
        )
        let negativeSecondary = DisplayDescriptor(
            id: 2,
            name: "Left-Lower External",
            frame: CGRect(x: -1920, y: -360, width: 1920, height: 1080),
            visibleFrame: CGRect(x: -1920, y: -300, width: 1920, height: 1015),
            isMain: false
        )

        for display in [primary, negativeSecondary] {
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
                    anchor: anchor,
                    offscreenGap: 16
                )

                // Clamped strictly inside triggering screen's visibleFrame
                #expect(display.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(vis))
                #expect(!display.frame.intersects(hid))

                let showDX = vis.origin.x - hid.origin.x
                let showDY = vis.origin.y - hid.origin.y
                let hideDX = hid.origin.x - vis.origin.x
                let hideDY = hid.origin.y - vis.origin.y

                // Show and hide vectors are exact opposites
                #expect(abs(showDX + hideDX) < 0.001)
                #expect(abs(showDY + hideDY) < 0.001)

                switch anchor {
                case .left:
                    #expect(hid.maxX == display.frame.minX - 16)
                    #expect(showDX > 0 && showDY == 0)
                case .right:
                    #expect(hid.minX == display.frame.maxX + 16)
                    #expect(showDX < 0 && showDY == 0)
                case .topLeft:
                    #expect(hid.maxX == display.frame.minX - 16)
                    #expect(hid.minY == display.frame.maxY + 16)
                    #expect(showDX > 0 && showDY < 0)
                case .topRight:
                    #expect(hid.minX == display.frame.maxX + 16)
                    #expect(hid.minY == display.frame.maxY + 16)
                    #expect(showDX < 0 && showDY < 0)
                case .bottomLeft:
                    #expect(hid.maxX == display.frame.minX - 16)
                    #expect(hid.maxY == display.frame.minY - 16)
                    #expect(showDX > 0 && showDY > 0)
                case .bottomRight:
                    // Specifically verify bottom-right slides diagonally UP-and-LEFT out of bottom-right corner
                    // and retreats DOWN-and-RIGHT back into bottom-right corner!
                    #expect(hid.minX == display.frame.maxX + 16)
                    #expect(hid.maxY == display.frame.minY - 16)
                    #expect(showDX < 0 && showDY > 0)
                    #expect(hideDX > 0 && hideDY < 0)
                }
            }

            // Oversized fixed-size override clamps inside screenVisibleFrame
            let clampedHuge = PanelGeometry.visibleFrame(
                screenVisibleFrame: display.visibleFrame,
                anchor: .bottomRight,
                override: PanelSizeOverride(fixedWidth: 6000, fixedHeight: 4000),
                edgeInset: 14
            )
            #expect(display.visibleFrame.insetBy(dx: -0.5, dy: -0.5).contains(clampedHuge))
        }

        // Flipping Left/Right preserves corner vertical alignment (never clobbering bottomRight -> right)
        #expect(AnchorPosition.bottomRight.withHorizontalSide(left: true) == .bottomLeft)
        #expect(AnchorPosition.bottomLeft.withHorizontalSide(left: false) == .bottomRight)
        #expect(AnchorPosition.topRight.withHorizontalSide(left: true) == .topLeft)
        #expect(AnchorPosition.right.withHorizontalSide(left: true) == .left)

        // Locked display resolution keeps panel anchored to the display it opened on even when mouse leaves
        let locked = DisplaySelector.resolveLockedDisplay(
            locked: negativeSecondary,
            panelFrame: CGRect(x: -900, y: -250, width: 700, height: 800),
            in: [primary, negativeSecondary]
        )
        #expect(locked?.id == negativeSecondary.id)
    }

    @Test("Rapid show/hide toggles reverse from current presentation frame without jumping, suppress stale hides, and honor Reduce Motion")
    func midFlightPresentationFrameReversalAndReduceMotion() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let visibleScreen = CGRect(x: 0, y: 54, width: 1512, height: 890)
        let vis = PanelGeometry.visibleFrame(screenVisibleFrame: visibleScreen, anchor: .bottomRight)
        let hid = PanelGeometry.hiddenFrame(visibleFrame: vis, screenFrame: screen, anchor: .bottomRight)

        var tc = PanelTransitionController()
        let show1 = tc.beginShow()
        let flight1 = PanelAnimationPlanner.planShow(
            hiddenFrame: hid,
            visibleFrame: vis,
            anchor: .bottomRight,
            generation: show1.generation,
            now: 50.0,
            baseDuration: 0.20,
            reduceMotion: false,
            reversedInFlight: show1.reversedInFlight
        )
        #expect(flight1.fromFrame == hid)
        #expect(flight1.toFrame == vis)

        // Interrupt show mid-flight at t = 50.06s
        let midShow = flight1.presentationState(at: 50.06)
        #expect(midShow.frame.origin.x > vis.origin.x && midShow.frame.origin.x < hid.origin.x)
        #expect(midShow.frame.origin.y < vis.origin.y && midShow.frame.origin.y > hid.origin.y)

        let hide1 = tc.beginHide()
        #expect(hide1.reversedInFlight == true)
        // Even if AppKit's `window.frame` already equals model target `vis`, planner reverses from `midShow.frame`!
        let flight2 = PanelAnimationPlanner.planHide(
            visibleFrame: vis,
            hiddenFrame: hid,
            anchor: .bottomRight,
            generation: hide1.generation,
            now: 50.06,
            baseDuration: 0.20,
            reduceMotion: false,
            reversedInFlight: hide1.reversedInFlight,
            inFlight: flight1,
            liveWindowFrame: vis,
            liveWindowAlpha: 1.0
        )
        #expect(abs(flight2.fromFrame.origin.x - midShow.frame.origin.x) < 0.001)
        #expect(abs(flight2.fromFrame.origin.y - midShow.frame.origin.y) < 0.001)
        #expect(flight2.toFrame == hid)

        // Interrupt hide mid-flight at t = 50.11s back to show
        let midHide = flight2.presentationState(at: 50.11)
        let show2 = tc.beginShow()
        #expect(show2.reversedInFlight == true)
        let flight3 = PanelAnimationPlanner.planShow(
            hiddenFrame: hid,
            visibleFrame: vis,
            anchor: .bottomRight,
            generation: show2.generation,
            now: 50.11,
            baseDuration: 0.20,
            reduceMotion: false,
            reversedInFlight: show2.reversedInFlight,
            inFlight: flight2,
            liveWindowFrame: hid,
            liveWindowAlpha: 0.0,
            isWindowCurrentlyVisible: true
        )
        #expect(abs(flight3.fromFrame.origin.x - midHide.frame.origin.x) < 0.001)
        #expect(abs(flight3.fromFrame.origin.y - midHide.frame.origin.y) < 0.001)
        #expect(flight3.toFrame == vis)

        // Stale completions from generation 1 & 2 are rejected; only generation 3 finalizes
        let staleShow1 = tc.completeShow(generation: show1.generation)
        let staleHide1 = tc.completeHide(generation: hide1.generation)
        let finalShow2 = tc.completeShow(generation: show2.generation)
        #expect(!staleShow1)
        #expect(!staleHide1)
        #expect(finalShow2)
        #expect(tc.phase == .visible)

        // Reduce Motion mode: zero positional translation, alpha-only fade & mid-flight alpha reversal
        let rmShow = PanelAnimationPlanner.planShow(
            hiddenFrame: hid,
            visibleFrame: vis,
            anchor: .bottomRight,
            generation: 10,
            now: 80.0,
            baseDuration: 0.20,
            reduceMotion: true
        )
        #expect(rmShow.fromFrame == vis && rmShow.toFrame == vis)
        #expect(rmShow.fromAlpha == 0.0 && rmShow.toAlpha == 1.0)
        let rmMid = rmShow.presentationState(at: 80.05)
        #expect(rmMid.frame == vis && rmMid.alpha > 0.0 && rmMid.alpha < 1.0)

        let rmHide = PanelAnimationPlanner.planHide(
            visibleFrame: vis,
            hiddenFrame: hid,
            anchor: .bottomRight,
            generation: 11,
            now: 80.05,
            baseDuration: 0.20,
            reduceMotion: true,
            reversedInFlight: true,
            inFlight: rmShow
        )
        #expect(rmHide.fromFrame == vis && rmHide.toFrame == vis)
        #expect(abs(rmHide.fromAlpha - rmMid.alpha) < 0.001)
        #expect(rmHide.toAlpha == 0.0)
    }

    @Test("User-Agent diagnostics handle nil/empty WebKit overrides without blank output, distinguish configured/sampled/observed states, and avoid speculative /sorry blame")
    func userAgentDiagnosticsEmptyOverrideFallbacksSorryNonInferenceAndSanitization() {
        // 1. Reproduce exact MacBook bug: WKWebView.customUserAgent returning `""` (non-nil empty string)
        let emptyWebViewUA = UserAgentDiagnostics.resolve(
            preset: .desktopSafari,
            padCustomUserAgent: nil,
            liveWebViewCustomUserAgent: "",
            applicationNameForUserAgent: "Version/26.3 Safari/605.1.15",
            sampledNavigatorUA: .pending(),
            observedHTTPRequestUA: .notObserved()
        )
        #expect(emptyWebViewUA.usesNativeWebKitDefault == true)
        #expect(emptyWebViewUA.configuredCustomOverride == nil)
        #expect(!emptyWebViewUA.configuredSummary.isEmpty)
        #expect(emptyWebViewUA.configuredSummary.contains("native WebKit default"))
        #expect(emptyWebViewUA.sampledNavigatorUserAgent.status == .pending)
        #expect(emptyWebViewUA.observedHTTPRequestUserAgent.status == .notObserved)

        // 2. Custom preset with whitespace-empty custom string must NOT obscure readout or show blank UA
        let emptyCustomPresetUA = UserAgentDiagnostics.resolve(
            preset: .custom,
            padCustomUserAgent: "   ",
            liveWebViewCustomUserAgent: nil,
            applicationNameForUserAgent: "Version/26.3 Safari/605.1.15",
            sampledNavigatorUA: .measured("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", elapsedMilliseconds: 9),
            observedHTTPRequestUA: .measured("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15", source: "loopback")
        )
        #expect(emptyCustomPresetUA.usesNativeWebKitDefault == true)
        #expect(emptyCustomPresetUA.configuredCustomOverride == nil)
        #expect(emptyCustomPresetUA.configuredSummary.contains("empty override"))
        #expect(emptyCustomPresetUA.sampledNavigatorUserAgent.status == .measured)
        #expect(emptyCustomPresetUA.observedHTTPRequestUserAgent.status == .measured)

        // 3. Empty string passed to `.measured("")` degrades safely to `.unavailable` / `.notObserved`
        #expect(SampledNavigatorUADiagnostic(status: .measured, value: "  ").status == .unavailable)
        #expect(ObservedHTTPHeaderUADiagnostic(status: .measured, value: "", source: "test").status == .notObserved)

        // 4. `/sorry` route records location observation ONLY — never claiming Google rejected WKWebView or extensions!
        let sorryURL = URL(string: "https://www.google.com/sorry/index?continue=https://www.google.com/search%3Fq%3Dswift&q=secretToken99")!
        let sorryObs = SiteCompatibilityInspector.evaluatePassiveObservation(url: sorryURL, topLevelHTTPStatus: 200)
        #expect(sorryObs.locationCategory == .googleSorryVerificationRoute)
        #expect(sorryObs.issueKind == .verificationRouteObserved)
        let summaryText = (sorryObs.summary ?? "").lowercased()
        #expect(summaryText.contains("does not indicate wkwebview or extension rejection"))
        #expect(!summaryText.contains("immersive"))
        #expect(!summaryText.contains("may be rejected"))

        let report = SiteDiagnosticsReport(
            macOSVersion: "Version 26.3 (Build 25D125)",
            webKitVersion: "21623",
            topLevelOrigin: SiteCompatibilityInspector.sanitizedOrigin(for: sorryURL),
            locationCategory: sorryObs.locationCategory,
            userAgent: emptyWebViewUA,
            javaScriptEnabled: true,
            customModificationsPaused: false,
            contentBlockerEnabled: false,
            blockedDomainCount: 0,
            matchingInjectionRuleCount: 0,
            loadedExtensions: [],
            issueKind: sorryObs.issueKind,
            issueSummary: sorryObs.summary
        )
        let plain = report.formattedPlainText()
        #expect(plain.contains("Configured User-Agent: native WebKit default"))
        #expect(plain.contains("Sampled navigator.userAgent: pending"))
        #expect(plain.contains("Observed HTTP User-Agent Header: not observed"))
        #expect(plain.contains("Loaded Extensions: none"))
        #expect(plain.contains("does NOT disable loaded WKWebExtensions"))
        #expect(!plain.contains("secretToken99"))

        // 5. Sanitization strips paths, queries, credentials, tokens, and IPv4/IPv6 literals
        let ipURL = URL(string: "http://admin:pass@192.168.10.25:8080/private/path?token=xyz123")!
        #expect(SiteCompatibilityInspector.sanitizedOrigin(for: ipURL) == "http://<ip-redacted>")
        let ipv6URL = URL(string: "https://[2607:f8b0:4005:80a::2004]:443/sorry?session=abc")!
        #expect(SiteCompatibilityInspector.sanitizedOrigin(for: ipv6URL) == "https://<ip-redacted>")
        let sanitizedErr = SiteCompatibilityInspector.sanitizeNavigationError(
            domain: NSURLErrorDomain,
            code: -1004,
            localizedDescription: "Could not connect to 192.168.10.25:8080 at https://example.com/login?token=mySecret999 auth=bearerTok"
        )
        #expect(!sanitizedErr.contains("192.168.10.25"))
        #expect(!sanitizedErr.contains("mySecret999"))
        #expect(!sanitizedErr.contains("bearerTok"))
        #expect(!sanitizedErr.contains("/login"))
    }

    private final class LoopbackDiagnosticFixtureServer: @unchecked Sendable {
        private let listener: NWListener
        private let lock = NSLock()
        private(set) var observedUserAgents: [String] = []
        private(set) var requestedPaths: [String] = []

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            self.listener = try NWListener(using: params)
        }

        var port: UInt16? {
            listener.port?.rawValue
        }

        func start() async throws -> UInt16 {
            let queue = DispatchQueue(label: "veypane.test.loopback.fixture")
            listener.newConnectionHandler = { [weak self] conn in
                self?.handleConnection(conn, queue: queue)
            }
            return try await withCheckedThrowingContinuation { cont in
                final class Gate: @unchecked Sendable { var resumed = false }
                let gate = Gate()
                listener.stateUpdateHandler = { [weak self] state in
                    guard !gate.resumed else { return }
                    switch state {
                    case .ready:
                        if let p = self?.listener.port?.rawValue {
                            gate.resumed = true
                            cont.resume(returning: p)
                        }
                    case .failed(let err):
                        gate.resumed = true
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
            conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
                guard let self, let data, let reqText = String(data: data, encoding: .utf8) else {
                    conn.cancel()
                    return
                }
                let lines = reqText.components(separatedBy: "\r\n")
                let requestLine = lines.first ?? "GET / HTTP/1.1"
                let parts = requestLine.split(separator: " ")
                let rawTarget = parts.count >= 2 ? String(parts[1]) : "/"
                let pathOnly = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

                var uaHeader: String?
                for line in lines.dropFirst() {
                    if line.lowercased().hasPrefix("user-agent:") {
                        uaHeader = String(line.dropFirst("user-agent:".count)).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }

                self.lock.lock()
                self.requestedPaths.append(pathOnly)
                if let uaHeader, !uaHeader.isEmpty {
                    self.observedUserAgents.append(uaHeader)
                }
                self.lock.unlock()

                let (statusLine, contentType, body): (String, String, String)
                switch pathOnly {
                case "/main":
                    statusLine = "HTTP/1.1 200 OK"
                    contentType = "text/html; charset=utf-8"
                    body = """
                    <!doctype html>
                    <html><head><title>Controlled Diagnostics Fixture</title></head>
                    <body>
                      <iframe id="sized-verif" title="reCAPTCHA challenge" src="/subframe-error?token=dontleak123" style="width:300px;height:78px;border:0"></iframe>
                      <iframe id="collapsed-verif" src="/subframe-ok?challenge=1&secret=hidden999" style="width:0px;height:0px;border:0"></iframe>
                      <img src="/broken.png?sig=privateSig" alt="broken">
                    </body></html>
                    """
                case "/subframe-error":
                    statusLine = "HTTP/1.1 403 Forbidden"
                    contentType = "text/html; charset=utf-8"
                    body = "<html><body>Forbidden subframe</body></html>"
                case "/subframe-ok":
                    statusLine = "HTTP/1.1 200 OK"
                    contentType = "text/html; charset=utf-8"
                    body = "<html><body>Collapsed subframe</body></html>"
                default:
                    statusLine = "HTTP/1.1 404 Not Found"
                    contentType = "text/plain; charset=utf-8"
                    body = "missing"
                }

                let bodyBytes = Data(body.utf8)
                let header = "\(statusLine)\r\nContent-Type: \(contentType)\r\nContent-Length: \(bodyBytes.count)\r\nConnection: close\r\n\r\n"
                var payload = Data(header.utf8)
                payload.append(bodyBytes)
                conn.send(content: payload, completion: .contentProcessed { _ in
                    conn.cancel()
                })
            }
        }
    }

    @MainActor
    private final class HeadlessWebKitDiagnosticProbe: NSObject, WKNavigationDelegate {
        var mainHTTPStatus: Int?
        var uiProcessObservedRequestUA: String?
        var subframeStatuses: [(origin: String, status: Int)] = []
        var didFinish = false

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if let ua = SiteCompatibilityInspector.nonEmptyTrimmed(
                navigationAction.request.value(forHTTPHeaderField: "User-Agent")
            ) {
                uiProcessObservedRequestUA = ua
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = navigationResponse.response as? HTTPURLResponse {
                if navigationResponse.isForMainFrame {
                    mainHTTPStatus = http.statusCode
                } else {
                    subframeStatuses.append((
                        origin: SiteCompatibilityInspector.sanitizedOrigin(for: http.url),
                        status: http.statusCode
                    ))
                }
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didFinish = true
        }
    }

    @Test("Controlled local loopback fixture verifies native WebKit wire User-Agent, sampled navigator.userAgent, iframe bounds, and subframe HTTP 403 without GUI")
    @MainActor
    func controlledLoopbackFixtureForIframeSubframeHTTPAndUserAgentDiagnostics() async throws {
        let server = try LoopbackDiagnosticFixtureServer()
        let port = try await server.start()
        defer { server.stop() }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = UserAgentPreset.desktopSafariApplicationName

        let delegate = HeadlessWebKitDiagnosticProbe()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = delegate
        webView.customUserAgent = nil // Native WebKit mode (same as Veypane default)

        let fixtureURL = URL(string: "http://127.0.0.1:\(port)/main?session=secretSessionToken")!
        webView.load(URLRequest(url: fixtureURL))

        let deadline = Date().addingTimeInterval(8.0)
        while !delegate.didFinish && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        // Allow subframes and broken image resource to settle
        try await Task.sleep(nanoseconds: 250_000_000)

        #expect(delegate.didFinish == true)
        #expect(delegate.mainHTTPStatus == 200)
        let sawSubframe403 = delegate.subframeStatuses.contains { item in
            item.status == 403 && item.origin == "http://<ip-redacted>"
        }
        #expect(sawSubframe403)

        // Empirical proof of Feedback A: even when `webView.customUserAgent` is nil/empty,
        // the wire HTTP request received by loopback server carries WebKit's full native User-Agent!
        let wireUA = try #require(server.observedUserAgents.first)
        #expect(wireUA.contains("Mozilla/5.0"))
        #expect(wireUA.contains("AppleWebKit/"))

        // Sample `navigator.userAgent` and passive iframe/image metadata from the live windowless WKWebView
        let sampleJS = """
        (function() {
            var frames = Array.from(document.querySelectorAll('iframe'));
            var sized = frames.filter(function(f) { var r = f.getBoundingClientRect(); return r.width >= 10 && r.height >= 10; }).length;
            var collapsed = frames.filter(function(f) { var r = f.getBoundingClientRect(); return r.width < 10 || r.height < 10; }).length;
            var brokenImgs = Array.from(document.querySelectorAll('img')).filter(function(i) { return i.complete && i.naturalWidth === 0; }).length;
            return JSON.stringify({
                ua: navigator.userAgent || "",
                total: frames.length,
                sized: sized,
                collapsed: collapsed,
                brokenImgs: brokenImgs
            });
        })()
        """
        let rawJSON: String? = await withCheckedContinuation { cont in
            webView.evaluateJavaScript(sampleJS) { val, _ in
                cont.resume(returning: val as? String)
            }
        }
        let dict = try #require(
            rawJSON?.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        )
        let sampledUA = try #require(dict["ua"] as? String)
        #expect(sampledUA == wireUA)
        #expect((dict["total"] as? Int) == 2)
        #expect((dict["sized"] as? Int) == 1)
        #expect((dict["collapsed"] as? Int) == 1)
        #expect((dict["brokenImgs"] as? Int) == 1)

        // Verify diagnostics report separates UI-process unobserved vs loopback-observed HTTP header and leaks zero secrets/IPs
        let uiProcessReportUA = UserAgentDiagnostics.resolve(
            preset: .desktopSafari,
            padCustomUserAgent: nil,
            liveWebViewCustomUserAgent: webView.customUserAgent,
            applicationNameForUserAgent: webView.configuration.applicationNameForUserAgent,
            sampledNavigatorUA: .measured(sampledUA, elapsedMilliseconds: 5),
            observedHTTPRequestUA: delegate.uiProcessObservedRequestUA.map { .measured($0, source: "WKNavigationAction") }
                ?? .notObserved()
        )
        #expect(uiProcessReportUA.usesNativeWebKitDefault == true)
        #expect(uiProcessReportUA.sampledNavigatorUserAgent.value == wireUA)

        let iframeSummary = PassiveIframeDiagnosticSummary(
            sampled: true,
            totalIframeCount: 2,
            verificationIframeCount: 2,
            sizedVerificationIframeCount: 1,
            collapsedVerificationIframeCount: 1,
            brokenImageCount: 1,
            observedIframeOrigins: [SiteCompatibilityInspector.sanitizedOrigin(for: fixtureURL)]
        )
        let subObs = delegate.subframeStatuses.map {
            SubframeNavigationDiagnostic(frameOrigin: $0.origin, policyDecision: "allow", httpStatusCode: $0.status)
        }
        let evaluated = SiteCompatibilityInspector.evaluatePassiveObservation(
            url: webView.url,
            topLevelHTTPStatus: delegate.mainHTTPStatus,
            iframeSummary: iframeSummary,
            subframeObservations: subObs
        )
        #expect(evaluated.issueKind == .subframeOrWidgetLoadIssue)

        let fullReport = SiteDiagnosticsReport(
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            webKitVersion: "System WebKit",
            topLevelOrigin: SiteCompatibilityInspector.sanitizedOrigin(for: webView.url),
            locationCategory: evaluated.locationCategory,
            userAgent: uiProcessReportUA,
            javaScriptEnabled: true,
            customModificationsPaused: false,
            contentBlockerEnabled: false,
            blockedDomainCount: 0,
            matchingInjectionRuleCount: 0,
            loadedExtensions: [],
            topLevelNavigation: TopLevelNavigationDiagnostic(lastPolicyDecision: "allow", lastHTTPStatusCode: 200),
            subframeObservations: subObs,
            iframeDiagnostics: iframeSummary,
            failureCategories: [PassiveFailureCategoryDiagnostic(category: "subframeHTTPError", origin: "http://<ip-redacted>", detail: "HTTP 403")],
            issueKind: evaluated.issueKind,
            issueSummary: evaluated.summary
        ).formattedPlainText()

        #expect(fullReport.contains("Origin: http://<ip-redacted>"))
        #expect(fullReport.contains("http=403"))
        #expect(!fullReport.contains("127.0.0.1"))
        #expect(!fullReport.contains("dontleak123"))
        #expect(!fullReport.contains("hidden999"))
        #expect(!fullReport.contains("secretSessionToken"))
        #expect(!fullReport.contains("privateSig"))
    }

    // MARK: - 11. Maintenance Patch (t267u & t268u): Clipboard-Safe Editing Routing & Navigation-Scoped Diagnostics

    /// Isolated responder spy for unit tests: records standard editing action selectors in memory
    /// without calling `super` and without touching `NSPasteboard` under any circumstance.
    @MainActor
    private final class TestEditingResponderSpyView: NSView {
        var log: [String] = []
        override var acceptsFirstResponder: Bool { true }

        @objc func copy(_ sender: Any?) { log.append("copy:") }
        @objc func paste(_ sender: Any?) { log.append("paste:") }
        @objc func cut(_ sender: Any?) { log.append("cut:") }
        override func selectAll(_ sender: Any?) { log.append("selectAll:") }
        @objc func undo(_ sender: Any?) { log.append("undo:") }
        @objc func redo(_ sender: Any?) { log.append("redo:") }
    }

    @MainActor
    private final class TestNonActivatingEditPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var isKeyWindow: Bool { true }

        @objc func undo(_ sender: Any?) {
            (firstResponder?.undoManager ?? undoManager)?.undo()
        }

        @objc func redo(_ sender: Any?) {
            (firstResponder?.undoManager ?? undoManager)?.redo()
        }

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if super.performKeyEquivalent(with: event) { return true }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            var mods: HotkeyModifiers = []
            if flags.contains(.control) { mods.insert(.control) }
            if flags.contains(.option) { mods.insert(.option) }
            if flags.contains(.shift) { mods.insert(.shift) }
            if flags.contains(.command) { mods.insert(.command) }
            guard let cmd = StandardEditCommand.match(
                modifiers: mods,
                charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                keyCode: event.keyCode
            ) else {
                return false
            }
            if NSApp?.keyWindow === self,
               let mainMenu = NSApp?.mainMenu,
               mainMenu.performKeyEquivalent(with: event) {
                return true
            }
            return dispatchEditCommand(cmd)
        }

        func dispatchEditCommand(_ cmd: StandardEditCommand) -> Bool {
            let sel = Selector((cmd.selectorName))
            let item = NSMenuItem(title: cmd.rawValue, action: sel, keyEquivalent: cmd.keyEquivalent)
            item.target = nil
            var candidate: NSResponder? = self.firstResponder
            while let responder = candidate {
                if responder.responds(to: sel) {
                    return NSApp.sendAction(sel, to: responder, from: item)
                }
                candidate = responder.nextResponder
            }
            return false
        }
    }

    @MainActor
    private final class TestInactivePanelAppDelegateBridge: NSObject, NSApplicationDelegate {
        weak var activePanel: TestNonActivatingEditPanel?
        @objc func undo(_ sender: Any?) { _ = activePanel?.dispatchEditCommand(.undo) }
        @objc func redo(_ sender: Any?) { _ = activePanel?.dispatchEditCommand(.redo) }
        @objc func cut(_ sender: Any?) { _ = activePanel?.dispatchEditCommand(.cut) }
        @objc func copy(_ sender: Any?) { _ = activePanel?.dispatchEditCommand(.copy) }
        @objc func paste(_ sender: Any?) { _ = activePanel?.dispatchEditCommand(.paste) }
        @objc func selectAll(_ sender: Any?) { _ = activePanel?.dispatchEditCommand(.selectAll) }
    }

    private static func makeTestCommandKeyEvent(
        char: String,
        keyCode: UInt16,
        shift: Bool = false,
        windowNumber: Int = 0
    ) -> NSEvent? {
        var flags: NSEvent.ModifierFlags = [.command]
        if shift { flags.insert(.shift) }
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: 1.0,
            windowNumber: windowNumber,
            context: nil,
            characters: shift ? char.uppercased() : char.lowercased(),
            charactersIgnoringModifiers: char.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        )
    }

    @Test("StandardEditCommand matching and nil-target responder-spy key-event routing for Cmd+C/V/X/A/Z/Shift+Z without touching clipboard")
    @MainActor
    func standardEditCommandMatchingAndNilTargetResponderSpyRoutingWithoutClipboard() throws {
        // 1. Exact Command / Command+Shift matching + non-interception of Option/Control/plain keys
        #expect(StandardEditCommand.match(modifiers: [.command], charactersIgnoringModifiers: "c", keyCode: 0x08) == .copy)
        #expect(StandardEditCommand.match(modifiers: [.command], charactersIgnoringModifiers: "v", keyCode: 0x09) == .paste)
        #expect(StandardEditCommand.match(modifiers: [.command], charactersIgnoringModifiers: "x", keyCode: 0x07) == .cut)
        #expect(StandardEditCommand.match(modifiers: [.command], charactersIgnoringModifiers: "a", keyCode: 0x00) == .selectAll)
        #expect(StandardEditCommand.match(modifiers: [.command], charactersIgnoringModifiers: "z", keyCode: 0x06) == .undo)
        #expect(StandardEditCommand.match(modifiers: [.command, .shift], charactersIgnoringModifiers: "z", keyCode: 0x06) == .redo)

        // KeyCode fallback when charactersIgnoringModifiers is empty (e.g. non-Latin / IME layout)
        #expect(StandardEditCommand.match(modifiers: [.command], charactersIgnoringModifiers: "", keyCode: 0x08) == .copy)
        #expect(StandardEditCommand.match(modifiers: [.command], charactersIgnoringModifiers: "", keyCode: 0x09) == .paste)

        // Must NOT match extension shortcut `Alt+A`, DevTools `Opt+Cmd+C`, or plain typing
        #expect(StandardEditCommand.match(modifiers: [.option], charactersIgnoringModifiers: "a") == nil)
        #expect(StandardEditCommand.match(modifiers: [.command, .option], charactersIgnoringModifiers: "c") == nil)
        #expect(StandardEditCommand.match(modifiers: [], charactersIgnoringModifiers: "c") == nil)

        // 2. Responder-spy key-event routing across two responders (web spy vs URL-field spy) with ZERO clipboard touch
        _ = NSApplication.shared
        let editMenu = NSMenu(title: "Edit")
        for cmd in StandardEditCommand.allCases {
            let item = NSMenuItem(title: cmd.rawValue, action: Selector((cmd.selectorName)), keyEquivalent: cmd.keyEquivalent)
            item.keyEquivalentModifierMask = cmd.requiresShift ? [.command, .shift] : [.command]
            item.target = nil
            editMenu.addItem(item)
        }
        let mainMenu = NSMenu(title: "Main")
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editRoot.submenu = editMenu
        mainMenu.addItem(editRoot)
        NSApplication.shared.mainMenu = mainMenu

        let panel = TestNonActivatingEditPanel(
            contentRect: NSRect(x: -16000, y: -16000, width: 500, height: 400),
            styleMask: [.nonactivatingPanel, .titled],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 400))
        let webSpy = TestEditingResponderSpyView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let urlFieldSpy = TestEditingResponderSpyView(frame: NSRect(x: 0, y: 310, width: 400, height: 40))
        root.addSubview(webSpy)
        root.addSubview(urlFieldSpy)
        panel.contentView = root

        // Focus `webSpy`: all 6 shortcuts route to `webSpy`, none to `urlFieldSpy`
        #expect(panel.makeFirstResponder(webSpy))
        let specs: [(String, UInt16, Bool)] = [
            ("c", 0x08, false),
            ("v", 0x09, false),
            ("x", 0x07, false),
            ("a", 0x00, false),
            ("z", 0x06, false),
            ("z", 0x06, true)
        ]
        for (ch, code, shift) in specs {
            let ev = try #require(Self.makeTestCommandKeyEvent(char: ch, keyCode: code, shift: shift, windowNumber: panel.windowNumber))
            #expect(panel.performKeyEquivalent(with: ev) == true)
        }
        #expect(webSpy.log == ["copy:", "paste:", "cut:", "selectAll:", "undo:", "redo:"])
        #expect(urlFieldSpy.log.isEmpty)

        // Focus `urlFieldSpy`: nil-target routing follows real `firstResponder` (never hard-routed to webSpy!)
        #expect(panel.makeFirstResponder(urlFieldSpy))
        for (ch, code, shift) in specs {
            let ev = try #require(Self.makeTestCommandKeyEvent(char: ch, keyCode: code, shift: shift, windowNumber: panel.windowNumber))
            #expect(panel.performKeyEquivalent(with: ev) == true)
        }
        #expect(urlFieldSpy.log == ["copy:", "paste:", "cut:", "selectAll:", "undo:", "redo:"])
        #expect(webSpy.log.count == 6)
    }

    @Test("Safe native Cmd+A, Cmd+Z, and Cmd+Shift+Z editing on synthetic local NSTextField and WKWebView fixtures without clipboard access")
    @MainActor
    func safeNativeEditingSelectAllUndoRedoOnSyntheticWebAndNativeFixtures() async throws {
        let app = NSApplication.shared
        let editMenu = NSMenu(title: "Edit")
        for cmd in StandardEditCommand.allCases {
            let item = NSMenuItem(title: cmd.rawValue, action: Selector((cmd.selectorName)), keyEquivalent: cmd.keyEquivalent)
            item.keyEquivalentModifierMask = cmd.requiresShift ? [.command, .shift] : [.command]
            item.target = nil
            editMenu.addItem(item)
        }
        let mainMenu = NSMenu(title: "Main")
        let editRoot = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editRoot.submenu = editMenu
        mainMenu.addItem(editRoot)
        app.mainMenu = mainMenu

        let panel = TestNonActivatingEditPanel(
            contentRect: NSRect(x: -16000, y: -16000, width: 700, height: 500),
            styleMask: [.nonactivatingPanel, .titled],
            backing: .buffered,
            defer: false
        )
        let delegateBridge = TestInactivePanelAppDelegateBridge()
        delegateBridge.activePanel = panel
        app.delegate = delegateBridge
        defer {
            app.delegate = nil
            panel.orderOut(nil)
        }
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0.01
        panel.ignoresMouseEvents = true
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let textField = NSTextField(frame: NSRect(x: 10, y: 450, width: 400, height: 28))
        textField.stringValue = "https://synthetic.local/path"

        let wkConfig = WKWebViewConfiguration()
        wkConfig.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 430), configuration: wkConfig)
        root.addSubview(webView)
        root.addSubview(textField)
        panel.contentView = root
        panel.orderBack(nil)

        // 1. Native NSTextField field editor: Cmd+A selects entire synthetic URL string (no clipboard access)
        #expect(panel.makeFirstResponder(textField))
        let editor = try #require(textField.currentEditor())
        editor.selectedRange = NSRange(location: 0, length: 0)
        let cmdA = try #require(Self.makeTestCommandKeyEvent(char: "a", keyCode: 0x00, windowNumber: panel.windowNumber))
        #expect(panel.performKeyEquivalent(with: cmdA) == true)
        #expect(editor.selectedRange.length == textField.stringValue.utf16.count)

        // 2. WKWebView synthetic HTML fixture: <input>, <textarea>, contenteditable, and document selection
        let html = """
        <!doctype html>
        <html><body>
          <input id="inp" type="text" value="alpha">
          <textarea id="ta">beta gamma</textarea>
          <div id="ce" contenteditable="true">delta epsilon</div>
          <p id="doc">zeta eta theta</p>
        </body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
        try await Task.sleep(nanoseconds: 400_000_000)

        #expect(panel.makeFirstResponder(webView))
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        try await Task.sleep(nanoseconds: 100_000_000)

        func evalStr(_ js: String) async -> String {
            await withCheckedContinuation { cont in
                webView.evaluateJavaScript(js) { val, _ in
                    cont.resume(returning: val.map { String(describing: $0) } ?? "")
                }
            }
        }

        // <input>: insert character via DOM undoable command, then verify Cmd+Z (undo), Cmd+Shift+Z (redo), Cmd+A (selectAll)
        _ = await evalStr("(function(){ var i=document.getElementById('inp'); i.focus(); i.setSelectionRange(5,5); document.execCommand('insertText', false, 'X'); return i.value; })()")
        #expect(await evalStr("document.getElementById('inp').value") == "alphaX")

        let cmdZ = try #require(Self.makeTestCommandKeyEvent(char: "z", keyCode: 0x06, shift: false, windowNumber: panel.windowNumber))
        #expect(panel.performKeyEquivalent(with: cmdZ) == true)
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect(await evalStr("document.getElementById('inp').value") == "alpha")

        let cmdShiftZ = try #require(Self.makeTestCommandKeyEvent(char: "z", keyCode: 0x06, shift: true, windowNumber: panel.windowNumber))
        #expect(panel.performKeyEquivalent(with: cmdShiftZ) == true)
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect(await evalStr("document.getElementById('inp').value") == "alphaX")

        #expect(panel.performKeyEquivalent(with: cmdA) == true)
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect(await evalStr("(function(){ var i=document.getElementById('inp'); return String(i.selectionEnd - i.selectionStart); })()") == "6")

        // <textarea>: Cmd+A
        _ = await evalStr("(function(){ var t=document.getElementById('ta'); t.focus(); t.setSelectionRange(0,0); return ''; })()")
        #expect(panel.performKeyEquivalent(with: cmdA) == true)
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect(await evalStr("(function(){ var t=document.getElementById('ta'); return String(t.selectionEnd - t.selectionStart); })()") == "10")

        // contenteditable: Cmd+A
        _ = await evalStr("(function(){ var c=document.getElementById('ce'); c.focus(); window.getSelection().removeAllRanges(); return ''; })()")
        #expect(panel.performKeyEquivalent(with: cmdA) == true)
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect((await evalStr("window.getSelection().toString()")).contains("delta epsilon"))

        // Document body selection: Cmd+A
        _ = await evalStr("(function(){ if (document.activeElement) document.activeElement.blur(); window.getSelection().removeAllRanges(); return ''; })()")
        #expect(panel.performKeyEquivalent(with: cmdA) == true)
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect((await evalStr("window.getSelection().toString()")).contains("zeta eta theta"))
    }

    @Test("NavigationDiagnosticsTracker separates current vs archived errors, guards late callbacks, records origin-only redirects, and isolates pads")
    func navigationDiagnosticsTrackerLifecycleFailThenSuccessLateCallbackRedirectsAndTwoPadIsolation() {
        var pad1 = NavigationDiagnosticsTracker<String>()
        var pad2 = NavigationDiagnosticsTracker<String>()

        let urlA = URL(string: "https://slow-a.example.com/private/search?q=secret1&token=tokA")!
        let urlB = URL(string: "https://clean-b.example.org/docs/page?session=tokB")!

        // 1. Fail/timeout on A -> current error recorded on A (`navID == 1`), Pad 2 completely unaffected
        let nav1 = pad1.prepareExplicitMainNavigation(targetURL: urlA)
        #expect(nav1 == 1)
        _ = pad1.didStartProvisionalNavigation(token: "tok-A1", currentURL: urlA)
        let recordedFailA = pad1.recordNavigationFailure(
            token: "tok-A1",
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            localizedDescription: "The request timed out at https://slow-a.example.com/private?token=tokA",
            fallbackURL: urlA
        )
        #expect(recordedFailA == true)
        #expect(pad1.currentNavigationError?.contains("-1001") == true)
        #expect(pad1.currentNavigationError?.contains("tokA") == false)
        #expect(pad1.issueKind == .navigationError)
        #expect(pad1.failureCategories.count == 1)
        #expect(pad1.failureCategories.first?.origin == "https://slow-a.example.com")

        // Pad 2 loads cleanly in parallel -> zero cross-pad leakage
        _ = pad2.prepareExplicitMainNavigation(targetURL: urlB)
        _ = pad2.didStartProvisionalNavigation(token: "pad2-B", currentURL: urlB)
        pad2.recordMainFrameResponse(url: urlB, statusCode: 200)
        _ = pad2.didCommit(token: "pad2-B", committedURL: urlB)
        let pad2Fin = pad2.didFinish(token: "pad2-B", finalURL: urlB)
        #expect(pad2Fin == 1)
        #expect(pad2.currentNavigationError == nil)
        #expect(pad2.previousNavigationFailure == nil)
        #expect(pad2.issueKind == .none)

        //Now Pad 1 navigates to B -> A's timeout is archived to `previousNavigationFailure`, current state is clean!
        let nav2 = pad1.prepareExplicitMainNavigation(targetURL: urlB)
        #expect(nav2 == 2)
        #expect(pad1.currentNavigationError == nil)
        #expect(pad1.failureCategories.isEmpty)
        #expect(pad1.issueKind == .none)
        #expect(pad1.previousNavigationFailure?.navigationID == 1)
        #expect(pad1.previousNavigationFailure?.origin == "https://slow-a.example.com")
        #expect(pad1.previousNavigationFailure?.wasLateSupersededCallback == false)

        _ = pad1.didStartProvisionalNavigation(token: "tok-B2", currentURL: urlB)
        pad1.recordMainFrameResponse(url: urlB, statusCode: 200)
        _ = pad1.didCommit(token: "tok-B2", committedURL: urlB)
        let fin2 = pad1.didFinish(token: "tok-B2", finalURL: urlB)
        #expect(fin2 == 2)

        // 2. Delayed failure callback & stale JS completion from an older in-flight navigation MUST NOT poison current page!
        var raceTracker = NavigationDiagnosticsTracker<String>()
        _ = raceTracker.prepareExplicitMainNavigation(targetURL: urlA)
        _ = raceTracker.didStartProvisionalNavigation(token: "inFlight-A", currentURL: urlA) // navID = 1

        // User immediately navigates to B before A finishes failing
        _ = raceTracker.prepareExplicitMainNavigation(targetURL: urlB) // navID = 2!
        _ = raceTracker.didStartProvisionalNavigation(token: "inFlight-B", currentURL: urlB)
        raceTracker.recordMainFrameResponse(url: urlB, statusCode: 200)
        _ = raceTracker.didCommit(token: "inFlight-B", committedURL: urlB)
        let raceFinB = raceTracker.didFinish(token: "inFlight-B", finalURL: urlB)
        #expect(raceFinB == 2)
        _ = raceTracker.applyPassiveSample(
            forNavigationID: 2,
            currentURL: urlB,
            sampledUA: .measured("Mozilla/5.0 AppleWebKit/605.1.15", elapsedMilliseconds: 4),
            iframeSummary: PassiveIframeDiagnosticSummary(sampled: true)
        )

        // Late timeout callback arrives for `inFlight-A` (`navID == 1 < 2`)!
        _ = raceTracker.recordNavigationFailure(
            token: "inFlight-A",
            domain: NSURLErrorDomain,
            code: NSURLErrorTimedOut,
            localizedDescription: "Timed out",
            fallbackURL: urlB // even if webView.url is already urlB, tracker uses nav#1's recorded origin `slow-a.example.com`!
        )
        // Late async JS completion arrives for `navID == 1`!
        let staleSampleAccepted = raceTracker.applyPassiveSample(
            forNavigationID: 1,
            currentURL: urlA,
            sampledUA: .unavailable(reason: "stale"),
            iframeSummary: PassiveIframeDiagnosticSummary(sampled: true, verificationIframeCount: 1, collapsedVerificationIframeCount: 1)
        )
        #expect(staleSampleAccepted == false)
        #expect(raceTracker.currentNavigationError == nil)
        #expect(raceTracker.failureCategories.isEmpty)
        #expect(raceTracker.issueKind == .none)
        #expect(raceTracker.sampledNavigatorUserAgent.status == .measured)
        #expect(raceTracker.previousNavigationFailure?.navigationID == 1)
        #expect(raceTracker.previousNavigationFailure?.origin == "https://slow-a.example.com")
        #expect(raceTracker.previousNavigationFailure?.wasLateSupersededCallback == true)

        // 3. Same-navigation 302 redirect chain keeps single navigationID and origin-only sanitized chain
        var redirectTracker = NavigationDiagnosticsTracker<String>()
        let hop1 = URL(string: "https://entry.example.com/go?token=secret1")!
        let hop2 = URL(string: "https://auth-hop.example.net/step?code=secret2")!
        let hop3 = URL(string: "https://app.example.org/home?user=alice")!

        _ = redirectTracker.prepareExplicitMainNavigation(targetURL: hop1)
        redirectTracker.recordMainFramePolicy(url: hop1, policyDecision: "allow", observedRequestUA: nil, isDefinitelyNewNavigation: false)
        let rNavID = redirectTracker.didStartProvisionalNavigation(token: "redir-1", currentURL: hop1)
        #expect(rNavID == 1)

        redirectTracker.recordMainFramePolicy(url: hop2, policyDecision: "allow", observedRequestUA: nil, isDefinitelyNewNavigation: false)
        redirectTracker.didReceiveServerRedirect(token: "redir-1", redirectedURL: hop2)

        redirectTracker.recordMainFramePolicy(url: hop3, policyDecision: "allow", observedRequestUA: nil, isDefinitelyNewNavigation: false)
        redirectTracker.didReceiveServerRedirect(token: "redir-1", redirectedURL: hop3)
        redirectTracker.recordMainFrameResponse(url: hop3, statusCode: 200)
        _ = redirectTracker.didCommit(token: "redir-1", committedURL: hop3)
        #expect(redirectTracker.didFinish(token: "redir-1", finalURL: hop3) == 1)

        let topDiag = redirectTracker.buildTopLevelDiagnostic()
        #expect(topDiag.navigationID == 1)
        #expect(topDiag.redirectChainOrigins == [
            "https://entry.example.com",
            "https://auth-hop.example.net",
            "https://app.example.org"
        ])
        #expect(topDiag.lastNavigationError == nil)
    }

    private final class LoopbackNavLifecycleServer: @unchecked Sendable {
        private let listener: NWListener

        init() throws {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
            self.listener = try NWListener(using: params)
        }

        func start() async throws -> UInt16 {
            let queue = DispatchQueue(label: "veypane.test.nav.lifecycle")
            listener.newConnectionHandler = { [weak self] conn in
                self?.handle(conn, queue: queue)
            }
            return try await withCheckedThrowingContinuation { cont in
                final class Once: @unchecked Sendable { var done = false }
                let once = Once()
                listener.stateUpdateHandler = { [weak self] st in
                    guard !once.done else { return }
                    if case .ready = st, let p = self?.listener.port?.rawValue {
                        once.done = true
                        cont.resume(returning: p)
                    } else if case .failed(let err) = st {
                        once.done = true
                        cont.resume(throwing: err)
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
        }

        private func handle(_ conn: NWConnection, queue: DispatchQueue) {
            conn.start(queue: queue)
            conn.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                guard let data, let text = String(data: data, encoding: .utf8) else {
                    conn.cancel()
                    return
                }
                let firstLine = text.components(separatedBy: "\r\n").first ?? ""
                let parts = firstLine.split(separator: " ")
                let rawTarget = parts.count >= 2 ? String(parts[1]) : "/"
                let path = rawTarget.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"

                if path == "/drop" {
                    // Abruptly close socket without HTTP response to trigger a genuine NSURLErrorDomain navigation failure
                    conn.cancel()
                    return
                }
                if path == "/redirect" {
                    let resp = "HTTP/1.1 302 Found\r\nLocation: /healthy?tok=secretRedir\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
                    return
                }
                let body = "<!doctype html><html><head><title>Healthy Page</title></head><body><p>OK</p></body></html>"
                let bytes = Data(body.utf8)
                let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
                var payload = Data(resp.utf8)
                payload.append(bytes)
                conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
            }
        }
    }

    @MainActor
    private final class TrackerBoundWebDelegate: NSObject, WKNavigationDelegate {
        var tracker = NavigationDiagnosticsTracker<ObjectIdentifier>()

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            let isMain = navigationAction.targetFrame?.isMainFrame ?? true
            if isMain {
                let isNew = navigationAction.navigationType != .other || tracker.phase != .provisional
                tracker.recordMainFramePolicy(
                    url: navigationAction.request.url,
                    policyDecision: "allow",
                    observedRequestUA: navigationAction.request.value(forHTTPHeaderField: "User-Agent"),
                    isDefinitelyNewNavigation: isNew
                )
            }
            decisionHandler(.allow)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame {
                let code = (navigationResponse.response as? HTTPURLResponse)?.statusCode
                tracker.recordMainFrameResponse(url: navigationResponse.response.url, statusCode: code)
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            _ = tracker.didStartProvisionalNavigation(token: navigation.map { ObjectIdentifier($0) }, currentURL: webView.url)
        }

        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            tracker.didReceiveServerRedirect(token: navigation.map { ObjectIdentifier($0) }, redirectedURL: webView.url)
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            _ = tracker.didCommit(token: navigation.map { ObjectIdentifier($0) }, committedURL: webView.url)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            _ = tracker.didFinish(token: navigation.map { ObjectIdentifier($0) }, finalURL: webView.url)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            let ns = error as NSError
            _ = tracker.recordNavigationFailure(
                token: navigation.map { ObjectIdentifier($0) },
                domain: ns.domain,
                code: ns.code,
                localizedDescription: ns.localizedDescription,
                fallbackURL: webView.url
            )
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            let ns = error as NSError
            _ = tracker.recordNavigationFailure(
                token: navigation.map { ObjectIdentifier($0) },
                domain: ns.domain,
                code: ns.code,
                localizedDescription: ns.localizedDescription,
                fallbackURL: webView.url
            )
        }
    }

    @Test("Controlled local loopback WKWebView navigation fixture: fail A -> redirect/succeed B archives A's error without poisoning B or Pad 2")
    @MainActor
    func controlledLoopbackNavigationLifecycleFixtureWithRedirectTimeoutAndTwoWebViews() async throws {
        let server = try LoopbackNavLifecycleServer()
        let port = try await server.start()
        defer { server.stop() }

        let cfg1 = WKWebViewConfiguration()
        cfg1.websiteDataStore = .nonPersistent()
        let del1 = TrackerBoundWebDelegate()
        let wv1 = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: cfg1)
        wv1.navigationDelegate = del1

        let cfg2 = WKWebViewConfiguration()
        cfg2.websiteDataStore = .nonPersistent()
        let del2 = TrackerBoundWebDelegate()
        let wv2 = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 400), configuration: cfg2)
        wv2.navigationDelegate = del2

        // Step 1: Pad 1 loads `/drop` (real network failure), while Pad 2 loads `/healthy` (`200 OK`)
        let dropURL = URL(string: "http://127.0.0.1:\(port)/drop?token=secretDrop")!
        let healthyURL = URL(string: "http://127.0.0.1:\(port)/healthy?token=secretHealthy")!
        _ = del1.tracker.prepareExplicitMainNavigation(targetURL: dropURL)
        wv1.load(URLRequest(url: dropURL))

        _ = del2.tracker.prepareExplicitMainNavigation(targetURL: healthyURL)
        wv2.load(URLRequest(url: healthyURL))

        let step1Deadline = Date().addingTimeInterval(6.0)
        while (del1.tracker.phase != .failed || del2.tracker.phase != .finished) && Date() < step1Deadline {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        #expect(del1.tracker.phase == .failed)
        #expect(del1.tracker.currentNavigationError != nil)
        #expect(del1.tracker.issueKind == .navigationError)

        #expect(del2.tracker.phase == .finished)
        #expect(del2.tracker.currentNavigationError == nil)
        #expect(del2.tracker.issueKind == .none)

        // Step 2: Pad 1 navigates to `/redirect` -> HTTP 302 -> `/healthy` (`200 OK`)
        let redirURL = URL(string: "http://127.0.0.1:\(port)/redirect?auth=secretAuth")!
        _ = del1.tracker.prepareExplicitMainNavigation(targetURL: redirURL)
        wv1.load(URLRequest(url: redirURL))

        let step2Deadline = Date().addingTimeInterval(6.0)
        while del1.tracker.phase != .finished && Date() < step2Deadline {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        #expect(del1.tracker.phase == .finished)
        let diag1 = del1.tracker.buildTopLevelDiagnostic()
        #expect(diag1.navigationID == 2)
        #expect(diag1.lastHTTPStatusCode == 200)
        #expect(diag1.lastNavigationError == nil)
        #expect(del1.tracker.failureCategories.isEmpty)
        #expect(del1.tracker.issueKind == .none)
        #expect(diag1.previousNavigationFailure?.navigationID == 1)
        #expect(diag1.previousNavigationFailure?.origin == "http://<ip-redacted>")
        #expect(diag1.previousNavigationFailure?.sanitizedError.contains("secretDrop") == false)
    }

    // MARK: - 12. T269 WKWebView Popup Contract & Authorized Native Clipboard E2E Acceptance

    @Test("PopupNavigationPolicy classifies auth/script popups, about:blank, target=_blank links, and external schemes")
    func popupNavigationPolicyClassificationAndSchemeSafety() {
        let authURL = URL(string: "https://example.com/oauth/authorize")!
        let blankURL = URL(string: "about:blank")!
        let mailURL = URL(string: "mailto:support@example.com")!
        let appSchemeURL = URL(string: "veypane://toggle")!

        // 1. Nil or about:blank URL -> ephemeralPopupWindow (never creates blank persistent sidebar pads)
        #expect(PopupNavigationPolicy.classifyCreateWebView(
            requestURL: nil,
            isLinkActivated: false,
            hasExplicitPopupWindowFeatures: false,
            newWindowBehavior: .openInNewPad
        ) == .ephemeralPopupWindow)

        #expect(PopupNavigationPolicy.classifyCreateWebView(
            requestURL: blankURL,
            isLinkActivated: true,
            hasExplicitPopupWindowFeatures: false,
            newWindowBehavior: .openInNewPad
        ) == .ephemeralPopupWindow)

        // 2. Explicit dialog windowFeatures (width/height/toolbar=no) -> ephemeralPopupWindow even on link click
        #expect(PopupNavigationPolicy.classifyCreateWebView(
            requestURL: authURL,
            isLinkActivated: true,
            hasExplicitPopupWindowFeatures: true,
            newWindowBehavior: .openInNewPad
        ) == .ephemeralPopupWindow)

        // 3. Scripted window.open (!isLinkActivated) -> ephemeralPopupWindow preserving window.opener & postMessage
        #expect(PopupNavigationPolicy.classifyCreateWebView(
            requestURL: authURL,
            isLinkActivated: false,
            hasExplicitPopupWindowFeatures: false,
            newWindowBehavior: .openInNewPad
        ) == .ephemeralPopupWindow)

        // 4. Ordinary user-clicked <a href="..." target="_blank"> -> honors newWindowBehavior with supplied config
        #expect(PopupNavigationPolicy.classifyCreateWebView(
            requestURL: authURL,
            isLinkActivated: true,
            hasExplicitPopupWindowFeatures: false,
            newWindowBehavior: .openInNewPad
        ) == .newPadWithSuppliedConfiguration(authURL))

        #expect(PopupNavigationPolicy.classifyCreateWebView(
            requestURL: authURL,
            isLinkActivated: true,
            hasExplicitPopupWindowFeatures: false,
            newWindowBehavior: .openInCurrentPad
        ) == .navigateCurrentPadAndReturnNil(authURL))

        #expect(PopupNavigationPolicy.classifyCreateWebView(
            requestURL: authURL,
            isLinkActivated: true,
            hasExplicitPopupWindowFeatures: false,
            newWindowBehavior: .openInDefaultBrowser
        ) == .openExternallyAndReturnNil(authURL))

        // 5. Non-web / app schemes -> handed off externally, returning nil to WebKit
        #expect(PopupNavigationPolicy.classifyCreateWebView(
            requestURL: mailURL,
            isLinkActivated: true,
            hasExplicitPopupWindowFeatures: false,
            newWindowBehavior: .openInNewPad
        ) == .openExternallyAndReturnNil(mailURL))

        #expect(PopupNavigationPolicy.classifyCreateWebView(
            requestURL: appSchemeURL,
            isLinkActivated: true,
            hasExplicitPopupWindowFeatures: false,
            newWindowBehavior: .openInNewPad
        ) == .openExternallyAndReturnNil(appSchemeURL))
    }

    @Test("Authorized native clipboard E2E acceptance (Cmd+C/V/X/A/Z/Shift+Z) across production SlideOverPanel, NSTextField, and WKWebView")
    @MainActor
    func authorizedNativeClipboardAndResponderEditingAcceptance() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneAuthorizedClipboardTest-\(UUID().uuidString)", isDirectory: true)
        defer {
            // Reinforce synthetic exit marker in case of early throw; never read or restore previous clipboard
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(EditingShortcutProbeRunner.finalSyntheticMarker, forType: .string)
            try? FileManager.default.removeItem(at: outDir)
        }

        let reportURL = outDir.appendingPathComponent("editing-shortcut-probe.json")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.mainMenu = MainMenuBuilder.buildMainMenu()
        if !app.isRunning {
            app.finishLaunching()
        }
        do {
            try await EditingShortcutProbeRunner.runProbe(into: outDir)
        } catch {
            if let raw = try? String(contentsOf: reportURL, encoding: .utf8) {
                print("EDITING_PROBE_JSON:\n\(raw)")
            }
            throw error
        }

        let data = try Data(contentsOf: reportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(EditingShortcutProbeReport.self, from: data)

        #expect(report.isolatedTemporaryStore == true)
        #expect(report.nonPersistentWebDataStore == true)
        #expect(report.previousClipboardReadOrBackedUp == false)
        #expect(report.initialClipboardUnconditionallyOverwrittenWithSyntheticSeed == true)
        #expect(report.finalSyntheticMarkerWritten == EditingShortcutProbeRunner.finalSyntheticMarker)
        #expect(report.mainMenuNilTargetSelectorsVerified == true)
        #expect(report.localShortcutMonitorBypassVerified == true)
        #expect(report.extensionShortcutBypassVerified == true)
        #expect(report.responderSpyAllSixMatched == true)
        #expect(report.focusRestoredOnShowAndPadSwitch == true)
        #expect(report.windowUndoEmptyBeforeWebTests == true)
        #expect(report.nativeFieldFocusPreservedDuringAddressEdit == true)
        #expect(report.focusRestoredAfterAddressCancel == true)
        #expect(report.nativeAddressFieldE2E.allPassed == true)
        #expect(report.nativeAddressFieldE2E.undoCutVerified == true)
        #expect(report.nativeAddressFieldE2E.redoCutVerified == true)
        #expect(report.nativeAddressFieldE2E.undoPasteVerified == true)
        #expect(report.nativeAddressFieldE2E.redoPasteVerified == true)
        #expect(report.webInputE2E.allPassed == true)
        #expect(report.webInputE2E.valueAfterUndoCut == "synthetic-input-seed")
        #expect(report.webInputE2E.valueAfterRedoCut == "")
        #expect(report.webInputE2E.valueAfterUndoPaste == "")
        #expect(report.webInputE2E.valueAfterRedoPaste == "synthetic-input-pasted")
        #expect(report.webTextareaE2E.allPassed == true)
        #expect(report.webTextareaE2E.valueAfterUndoCut == "synthetic-textarea-seed")
        #expect(report.webTextareaE2E.valueAfterRedoCut == "")
        #expect(report.webTextareaE2E.valueAfterUndoPaste == "")
        #expect(report.webTextareaE2E.valueAfterRedoPaste == "synthetic-textarea-pasted")
        #expect(report.webContentEditableE2E.allPassed == true)
        #expect(report.webContentEditableE2E.valueAfterUndoCut == "synthetic-editable-seed")
        #expect(report.webContentEditableE2E.valueAfterRedoCut == "")
        #expect(report.webContentEditableE2E.valueAfterUndoPaste == "")
        #expect(report.webContentEditableE2E.valueAfterRedoPaste == "synthetic-editable-pasted")
        #expect(report.webDocumentSelectionCopyAndSelectAllVerified == true)
        #expect(report.passedAllChecks == true)

        // Also directly verify SlideOverPanel validates undo:/redo: against firstResponder's own UndoManager
        // when the window's own undoManager is completely empty (both validateMenuItem and canDispatchSelectorInResponderChain).
        final class SeparateUndoResponderView: NSView {
            let customUndo = UndoManager()
            override var acceptsFirstResponder: Bool { true }
            override var undoManager: UndoManager? { customUndo }
            var state = "initial"
            func applyState(_ next: String) {
                let prev = state
                state = next
                customUndo.registerUndo(withTarget: self) { target in
                    target.applyState(prev)
                }
            }
        }
        let checkPanel = SlideOverPanel(contentRect: NSRect(x: -16000, y: -16000, width: 320, height: 200))
        defer { checkPanel.orderOut(nil) }
        let sepView = SeparateUndoResponderView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        checkPanel.contentView = sepView
        #expect(checkPanel.makeFirstResponder(sepView))
        #expect(checkPanel.undoManager?.canUndo != true)

        let undoItem = try #require(MainMenuBuilder.editMenuItem(for: .undo, in: app.mainMenu))
        let redoItem = try #require(MainMenuBuilder.editMenuItem(for: .redo, in: app.mainMenu))
        #expect(checkPanel.validateMenuItem(undoItem) == false)
        #expect(checkPanel.canDispatchSelectorInResponderChain(undoItem.action!, menuItem: undoItem) == false)

        sepView.applyState("edited")
        #expect(checkPanel.undoManager?.canUndo != true)
        #expect(checkPanel.validateMenuItem(undoItem) == true)
        #expect(checkPanel.validateUserInterfaceItem(undoItem) == true)
        #expect(checkPanel.canDispatchSelectorInResponderChain(undoItem.action!, menuItem: undoItem) == true)
        #expect(checkPanel.dispatchStandardEditCommandToResponderChain(.undo) == true)
        #expect(sepView.state == "initial")
        #expect(checkPanel.validateMenuItem(redoItem) == true)
        #expect(checkPanel.dispatchStandardEditCommandToResponderChain(.redo) == true)
        #expect(sepView.state == "edited")

        // Confirm synthetic exit marker is present on NSPasteboard.general after probe completes
        #expect(NSPasteboard.general.string(forType: .string) == EditingShortcutProbeRunner.finalSyntheticMarker)
    }

    @Test("Production WKWebView popup delegate & targetFrame==nil loopback acceptance (opener, postMessage, about:blank, reuse, close, 302, target=_blank)")
    @MainActor
    func productionPopupDelegateAndTargetFrameNilLoopbackAcceptance() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypanePopupAcceptanceTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let reportURL = outDir.appendingPathComponent("popup-acceptance-probe.json")
        do {
            try await PopupAcceptanceProbeRunner.runProbe(into: outDir)
        } catch {
            if let raw = try? String(contentsOf: reportURL, encoding: .utf8) {
                print("POPUP_PROBE_JSON:\n\(raw)")
            }
            throw error
        }

        let data = try Data(contentsOf: reportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(PopupAcceptanceProbeReport.self, from: data)

        #expect(report.isolatedTemporaryStore == true)
        #expect(report.nonPersistentWebDataStore == true)
        #expect(report.loopbackOnlyZeroExternalRequests == true)
        #expect(report.cookiesOrStorageInspected == false)
        #expect(report.namedPopupOpenerAndPostMessageVerified == true)
        #expect(report.windowCloseCleanupVerified == true)
        #expect(report.aboutBlankToScriptedLocationVerified == true)
        #expect(report.namedWindowReuseWithoutDuplicatePadsVerified == true)
        #expect(report.closedThenReopenedNamedPopupVerified == true)
        #expect(report.targetFrameNilNoDuplicatePadVerified == true)
        #expect(report.normalTargetBlankNewPadVerified == true)
        #expect(report.inheritedSameWebsiteDataStoreInstanceVerified == true)
        #expect(report.childPopupRedirectAndIsolatedDiagnosticsVerified == true)
        #expect(report.unsolicitedBackgroundPopupBlockedVerified == true)
        #expect(report.passedAllChecks == true)
    }

    // MARK: - 13. t304 Outside-Click Dismissal Policy, Matrix & Exceptions

    @Test("OutsideClickDismissalPolicy covers external/same-app clicks, mid-animation reversal, pin, modals/sheets, menus, inspector, and child OAuth popups")
    func outsideClickDismissalPolicyAndTriggerRetriggerGuardMatrix() {
        let panelFrame = CGRect(x: 639, y: 122, width: 1267, height: 773)

        // 1. Hidden / hiding panel is a no-op
        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: false,
            transitionPhase: .hidden,
            isPinnedOpen: false,
            origin: .externalApplicationOrDesktop,
            screenLocation: CGPoint(x: 200, y: 500),
            livePanelFrame: panelFrame
        )) == .keepOpen(.panelNotVisible))

        // 2. External desktop / other-app click dismisses both when `.visible` and mid-flight when `.showing`
        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: false,
            origin: .externalApplicationOrDesktop,
            screenLocation: CGPoint(x: 635, y: 500), // even 4pt outside card border (inside old 14pt retentionPadding!)
            livePanelFrame: panelFrame
        )) == .dismissPanel(.externalClick))

        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .showing,
            isPinnedOpen: false,
            origin: .externalApplicationOrDesktop,
            screenLocation: CGPoint(x: 200, y: 500),
            livePanelFrame: panelFrame
        )) == .dismissPanel(.midAnimationExternalClick))

        // 3. Same-app standalone window (`Settings` / `Welcome`) outside panel dismisses when unpinned
        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: false,
            origin: .sameApplicationOtherStandardWindow,
            screenLocation: CGPoint(x: 600, y: 400),
            livePanelFrame: panelFrame
        )) == .dismissPanel(.sameApplicationOtherWindowClick))

        // 4. Inside panel, child popover, menu/status-bar item, Web Inspector, modal/sheet/NSOpenPanel, child OAuth popup, and pinned state keep open
        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: true,
            origin: .externalApplicationOrDesktop,
            screenLocation: CGPoint(x: 200, y: 500),
            livePanelFrame: panelFrame
        )) == .keepOpen(.panelPinnedOpen))

        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: false,
            isAlwaysOnTop: true,
            origin: .externalApplicationOrDesktop,
            screenLocation: CGPoint(x: 200, y: 500),
            livePanelFrame: panelFrame
        )) == .dismissPanel(.externalClick))

        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: false,
            hasActiveModalOrSheetOrFileDialog: true,
            origin: .externalApplicationOrDesktop,
            screenLocation: CGPoint(x: 200, y: 500),
            livePanelFrame: panelFrame
        )) == .keepOpen(.activeModalOrSheetOrFileDialog))

        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: false,
            hasActiveEphemeralChildPopup: true,
            origin: .externalApplicationOrDesktop,
            screenLocation: CGPoint(x: 200, y: 500),
            livePanelFrame: panelFrame
        )) == .keepOpen(.activeEphemeralChildPopup))

        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: false,
            origin: .sameApplicationPanel,
            screenLocation: CGPoint(x: 900, y: 500),
            livePanelFrame: panelFrame
        )) == .keepOpen(.insidePanelWindow))

        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: false,
            origin: .sameApplicationPanelChildOrPopover
        )) == .keepOpen(.insideChildOrPopoverWindow))

        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: false,
            origin: .sameApplicationMenuOrStatusItem
        )) == .keepOpen(.activeMenuOrStatusItemWindow))

        #expect(OutsideClickDismissalPolicy.evaluate(OutsideClickContext(
            isPanelTargetVisible: true,
            transitionPhase: .visible,
            isPinnedOpen: false,
            origin: .sameApplicationInspectorWindow
        )) == .keepOpen(.activeInspectorWindow))

        // 5. EdgeTriggerEngine `requireTriggerExitBeforeReshow` prevents immediate re-show if dismissed while pointer is in trigger strip
        var engine = EdgeTriggerEngine()
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        engine.setPanelVisible(false, pointerAlreadyInside: false, requireTriggerExitBeforeReshow: true)
        #expect(engine.mustExitTriggerZoneBeforeNextShow == true)

        let inStrip = PointerContext(location: CGPoint(x: 1919, y: 500), timestamp: 1.0, screenFrame: screen, visiblePanelFrame: panelFrame)
        #expect(engine.evaluate(context: inStrip, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100)) == .none)
        var inStripAfterDwell = inStrip
        inStripAfterDwell.timestamp = 1.5
        #expect(engine.evaluate(context: inStripAfterDwell, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100)) == .none)

        // Exiting trigger strip clears guard so next visit triggers normally
        let outsideStrip = PointerContext(location: CGPoint(x: 1850, y: 500), timestamp: 2.0, screenFrame: screen, visiblePanelFrame: panelFrame)
        #expect(engine.evaluate(context: outsideStrip, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100)) == .none)
        #expect(engine.mustExitTriggerZoneBeforeNextShow == false)

        var nextEnter = inStrip
        nextEnter.timestamp = 3.0
        _ = engine.evaluate(context: nextEnter, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100))
        var nextDwell = inStrip
        nextDwell.timestamp = 3.2
        #expect(engine.evaluate(context: nextDwell, anchor: .right, settings: EdgeTriggerSettings(dwellMilliseconds: 100)) == .showPanel)
    }

    @Test("Production outside-click probe covers full show/dismiss matrix, same-app windows, web input, pin, Always on Top, and popup/menu/sheet exceptions")
    @MainActor
    func outsideClickProductionProbeAcceptance() async throws {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneOutsideClickTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let reportURL = outDir.appendingPathComponent("outside-click-probe.json")
        do {
            try await OutsideClickProbeRunner.runProbe(into: outDir)
        } catch {
            if let raw = try? String(contentsOf: reportURL, encoding: .utf8) {
                print("OUTSIDE_CLICK_PROBE_JSON:\n\(raw)")
            }
            throw error
        }

        let data = try Data(contentsOf: reportURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let report = try decoder.decode(OutsideClickProbeReport.self, from: data)

        #expect(report.isolatedTemporaryStore == true)
        #expect(report.nonPersistentWebDataStore == true)
        #expect(report.firstAndRepeatedShowExternalClickDismissVerified == true)
        #expect(report.hotkeyOrStatusShowWithoutHoverExternalClickDismissVerified == true)
        #expect(report.edgeTriggerDisabledExternalClickDismissVerified == true)
        #expect(report.midAnimationShowExternalClickReversalVerified == true)
        #expect(report.rapidShowHideBurstCoherenceVerified == true)
        #expect(report.sameAppSettingsAndWelcomeWindowClickDismissVerified == true)
        #expect(report.insidePanelAndSyntheticWebInputClickKeepsOpenVerified == true)
        #expect(report.pinnedPanelStaysOpenThenUnpinDismissesVerified == true)
        #expect(report.alwaysOnTopUnpinnedDismissesAndPinnedStaysOpenVerified == true)
        #expect(report.childPopoverSheetMenuInspectorAndOAuthPopupKeepOpenVerified == true)
        #expect(report.triggerMarginDismissSuppressesImmediateRetriggerVerified == true)
        #expect(report.passedAllChecks == true)
    }

    @Test(
        "Genuine OS CGEvent mouse outside-click acceptance (opt-in via VEYPANE_RUN_OS_MOUSE_TESTS=1)",
        .enabled(if: ProcessInfo.processInfo.environment["VEYPANE_RUN_OS_MOUSE_TESTS"] == "1")
    )
    @MainActor
    func genuineOSOutsideClickAcceptance() async throws {
        let env = ProcessInfo.processInfo.environment
        let customOutPath = env["VEYPANE_OS_MOUSE_REPORT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesCustomDir = (customOutPath?.isEmpty == false)
        let outDir = usesCustomDir
            ? URL(fileURLWithPath: customOutPath!, isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent(
                "VeypaneOSOutsideClickTest-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            if !usesCustomDir {
                try? FileManager.default.removeItem(at: outDir)
            }
        }

        let report = try await NativeOSOutsideClickAcceptanceRunner.runAcceptance(
            into: outDir,
            reportFilename: NativeOSOutsideClickAcceptanceRunner.defaultReportFilename,
            executionContext: "Opt-in Swift Testing real OS CGEvent acceptance (VEYPANE_RUN_OS_MOUSE_TESTS=1)"
        )

        #expect(report.cgPostEventAccess == true)
        #expect(report.isolatedTemporaryStore == true)
        #expect(report.nonPersistentWebDataStore == true)
        #expect(report.monitorBackend == "cgEventTap+nsEventFallback")
        #expect(report.totalCases == 13)
        #expect(report.passedCases == report.totalCases)
        #expect(report.passedAllChecks == true)
        for item in report.cases {
            #expect(item.preClickPanelOnscreenConfirmed == true, "Panel was not confirmed onscreen before click in \(item.caseName)")
            #expect(item.passed == true, "Failed real OS outside-click acceptance case: \(item.caseName)")
        }
    }

    // MARK: - 14. t314/t315/t316 Native Window Resize Geometry, Corner Priority, Public Cursors & Persistence

    @Test("PanelGeometry resize hit-testing enforces corner priority over left/top edges and anchors opposite sides with min/screen bounds")
    func panelResizeHitTestCornerPriorityAndOppositeSideAnchoringMatrix() {
        let winSize = CGSize(width: 1000, height: 700)

        // 1. Strict TOP-LEFT corner priority across full 15x15 rounded-corner region (never falls into left-only or top-only)
        for pt in [
            CGPoint(x: 0, y: 700),
            CGPoint(x: 1.5, y: 698.5),
            CGPoint(x: 1.5, y: 692.0), // lower arc of cornerRadius=12
            CGPoint(x: 1.5, y: 686.0),
            CGPoint(x: 10.0, y: 696.5), // upper arc inside 32pt titlebar band
            CGPoint(x: 14.5, y: 685.5),
            CGPoint(x: -2.0, y: 702.0)
        ] {
            #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: pt, windowSize: winSize) == .topLeft, "Expected .topLeft at \(pt)")
        }

        // Other three corners
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 992, y: 694), windowSize: winSize) == .topRight)
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 4, y: 8), windowSize: winSize) == .bottomLeft)
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 995, y: 5), windowSize: winSize) == .bottomRight)

        // 2. Single-edge perimeter bands
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 500, y: 696.5), windowSize: winSize) == .top)
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 500, y: 701.5), windowSize: winSize) == .top)
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 500, y: 3.5), windowSize: winSize) == .bottom)
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 2.0, y: 350), windowSize: winSize) == .left)
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 998.0, y: 350), windowSize: winSize) == .right)

        // 3. Interior toolbar buttons, sidebar pad avatars, and webpage area pass through (`nil`)
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 20, y: 685), windowSize: winSize) == nil)
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 28, y: 670), windowSize: winSize) == nil)
        #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 500, y: 350), windowSize: winSize) == nil)

        // 4. Opposite-side anchoring, grow & shrink, minSize (320x340), and screenVisibleFrame bounds
        let screenVis = CGRect(x: 0, y: 40, width: 1920, height: 1016) // maxY = 1056
        let start = CGRect(x: 680, y: 200, width: 1000, height: 660)   // maxX = 1680, maxY = 860

        // LEFT edge: grow & shrink keep maxX=1680 and y/height fixed
        let leftGrow = PanelGeometry.resizedFrame(
            initialFrame: start,
            handle: .left,
            initialMouseScreen: CGPoint(x: 681, y: 500),
            currentMouseScreen: CGPoint(x: 601, y: 500),
            screenVisibleFrame: screenVis
        )
        #expect(leftGrow == CGRect(x: 600, y: 200, width: 1080, height: 660))

        let leftShrinkClamped = PanelGeometry.resizedFrame(
            initialFrame: start,
            handle: .left,
            initialMouseScreen: CGPoint(x: 681, y: 500),
            currentMouseScreen: CGPoint(x: 1850, y: 500),
            screenVisibleFrame: screenVis
        )
        #expect(leftShrinkClamped == CGRect(x: 1680 - 320, y: 200, width: 320, height: 660))

        // TOP edge: grow & shrink keep minY=200 (bottom edge) and x/width fixed
        let topGrow = PanelGeometry.resizedFrame(
            initialFrame: start,
            handle: .top,
            initialMouseScreen: CGPoint(x: 1180, y: 857),
            currentMouseScreen: CGPoint(x: 1180, y: 937),
            screenVisibleFrame: screenVis
        )
        #expect(topGrow == CGRect(x: 680, y: 200, width: 1000, height: 740))

        let topShrink = PanelGeometry.resizedFrame(
            initialFrame: start,
            handle: .top,
            initialMouseScreen: CGPoint(x: 1180, y: 857),
            currentMouseScreen: CGPoint(x: 1180, y: 747),
            screenVisibleFrame: screenVis
        )
        #expect(topShrink == CGRect(x: 680, y: 200, width: 1000, height: 550))

        let topShrinkClamped = PanelGeometry.resizedFrame(
            initialFrame: start,
            handle: .top,
            initialMouseScreen: CGPoint(x: 1180, y: 857),
            currentMouseScreen: CGPoint(x: 1180, y: 100),
            screenVisibleFrame: screenVis
        )
        #expect(topShrinkClamped == CGRect(x: 680, y: 200, width: 1000, height: 340))

        // TOP-LEFT corner: true diagonal grow & shrink change BOTH width and height while anchoring (maxX=1680, minY=200)
        let tlGrow = PanelGeometry.resizedFrame(
            initialFrame: start,
            handle: .topLeft,
            initialMouseScreen: CGPoint(x: 682, y: 856),
            currentMouseScreen: CGPoint(x: 597, y: 921), // dx = -85, dy = +65
            screenVisibleFrame: screenVis
        )
        #expect(tlGrow == CGRect(x: 595, y: 200, width: 1085, height: 725))
        #expect(tlGrow.maxX == start.maxX && tlGrow.minY == start.minY)

        let tlShrink = PanelGeometry.resizedFrame(
            initialFrame: start,
            handle: .topLeft,
            initialMouseScreen: CGPoint(x: 682, y: 856),
            currentMouseScreen: CGPoint(x: 757, y: 796), // dx = +75, dy = -60
            screenVisibleFrame: screenVis
        )
        #expect(tlShrink == CGRect(x: 755, y: 200, width: 925, height: 600))
        #expect(tlShrink.maxX == start.maxX && tlShrink.minY == start.minY)

        // Screen bounds clamp on oversized diagonal grow
        let tlScreenClamped = PanelGeometry.resizedFrame(
            initialFrame: start,
            handle: .topLeft,
            initialMouseScreen: CGPoint(x: 682, y: 856),
            currentMouseScreen: CGPoint(x: -400, y: 1600),
            screenVisibleFrame: screenVis
        )
        #expect(tlScreenClamped.minX == screenVis.minX)
        #expect(tlScreenClamped.maxY == screenVis.maxY)
        #expect(tlScreenClamped.maxX == start.maxX)
        #expect(tlScreenClamped.minY == start.minY)
    }

    @Test("Synthetic NSEvent SlideOverPanel resize: public cursors, top-edge & top-left diagonal drag, persistence across pad switch/hide/show, and corner anchors")
    @MainActor
    func productionSlideOverPanelSyntheticEventResizeCursorsPersistenceAndAnchors() async throws {
        // NOTE: This test dispatches synthetic NSEvent mouse sequences directly through production
        // `SlideOverPanel.sendEvent(_:)` + `AppModel` + `NSHostingView<PanelRootView>` +
        // `PanelResizePerimeterCursorView`; it is synthetic AppKit event routing, NOT real OS CGEvent cursor injection.
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        if !app.isRunning { app.finishLaunching() }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "VeypaneSyntheticResizeTest-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = VeypaneStore(directoryURL: tempDir)
        var initial = WorkspaceState(pads: [
            Pad(title: "Pad Alpha", url: URL(string: "about:blank")!),
            Pad(title: "Pad Beta", url: URL(string: "about:blank")!)
        ])
        initial.settings.hasCompletedOnboarding = true
        initial.settings.animationDuration = 0.08
        try store.save(initial)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
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
            PanelRootView.makeHostingView(model: model)
        }
        model.panel?.alphaValue = 0.01
        model.panel?.reduceMotionOverride = false
        defer { model.stopRuntimeServices() }

        let panel = try #require(model.panel)
        #expect(panel.minSize == NSSize(width: PanelGeometry.minPanelWidth, height: PanelGeometry.minPanelHeight))

        model.showPanel(activateFocus: true, openedFromEdge: false)
        try await Task.sleep(nanoseconds: 160_000_000)
        #expect(panel.isVisible == true)

        func sendMouse(_ type: NSEvent.EventType, windowPoint: CGPoint) {
            if let ev = NSEvent.mouseEvent(
                with: type,
                location: windowPoint,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: panel.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: (type == .leftMouseDown || type == .leftMouseUp) ? 1 : 0,
                pressure: (type == .leftMouseDown || type == .leftMouseDragged) ? 1.0 : 0.0
            ) {
                panel.sendEvent(ev)
            }
        }

        func dragPanelViaSendEvent(fromStartInWindow startWinPt: CGPoint, screenDelta: CGPoint) {
            let startScreen = panel.convertPoint(toScreen: startWinPt)
            sendMouse(.mouseMoved, windowPoint: startWinPt)
            sendMouse(.leftMouseDown, windowPoint: startWinPt)
            for step in 1...5 {
                let t = CGFloat(step) / 5.0
                let targetScreen = CGPoint(x: startScreen.x + screenDelta.x * t, y: startScreen.y + screenDelta.y * t)
                let curWinPt = panel.convertPoint(fromScreen: targetScreen)
                sendMouse(.leftMouseDragged, windowPoint: curWinPt)
            }
            let finalScreen = CGPoint(x: startScreen.x + screenDelta.x, y: startScreen.y + screenDelta.y)
            sendMouse(.leftMouseUp, windowPoint: panel.convertPoint(fromScreen: finalScreen))
        }

        // 1. Public NSCursor verification across LEFT edge, TOP edge (inside 32pt titlebar zone), TOP-LEFT corner, and interior
        let baseFrame = panel.frame
        let leftCur = SlideOverPanel.resizeCursor(for: .left)
        let topCur = SlideOverPanel.resizeCursor(for: .top)
        let tlCur = SlideOverPanel.resizeCursor(for: .topLeft)
        #expect(topCur != NSCursor.arrow)
        #expect(tlCur != NSCursor.arrow)
        #expect(tlCur != leftCur)
        #expect(tlCur != topCur)

        // Verify topmost perimeter cursor-rect overlay registers all 8 handles pairwise-disjointly
        // and passes interior toolbar/webpage hit-tests through (`nil`).
        let cursorRects = panel.registeredResizeCursorRects()
        #expect(cursorRects.count == 8)
        #expect(Set(cursorRects.map(\.handle)) == Set(PanelResizeHandle.allCases))
        for i in 0..<cursorRects.count {
            for j in (i + 1)..<cursorRects.count {
                #expect(
                    cursorRects[i].rect.intersection(cursorRects[j].rect).isEmpty,
                    "Cursor rects overlapped: \(cursorRects[i].handle) vs \(cursorRects[j].handle)"
                )
            }
        }
        if let overlay = panel.perimeterCursorOverlayView {
            #expect(overlay.hitTest(CGPoint(x: baseFrame.width / 2, y: baseFrame.height - 3.5)) === overlay)
            #expect(overlay.hitTest(CGPoint(x: 1.5, y: baseFrame.height - 11.0)) === overlay)
            #expect(overlay.hitTest(CGPoint(x: 20.0, y: baseFrame.height - 15.0)) == nil) // Header button center passes through
            #expect(overlay.hitTest(CGPoint(x: 300.0, y: 300.0)) == nil)                 // Web content passes through
        }

        sendMouse(.mouseMoved, windowPoint: CGPoint(x: 1.5, y: baseFrame.height / 2))
        #expect(panel.hoveredResizeHandle == .left)
        #expect(panel.lastAppliedResizeCursor == leftCur)

        sendMouse(.mouseMoved, windowPoint: CGPoint(x: baseFrame.width / 2, y: baseFrame.height - 3.5))
        #expect(panel.hoveredResizeHandle == .top)
        #expect(panel.lastAppliedResizeCursor == topCur)

        for cornerPt in [
            CGPoint(x: 2.0, y: baseFrame.height - 2.0),
            CGPoint(x: 1.5, y: baseFrame.height - 11.0),
            CGPoint(x: 11.0, y: baseFrame.height - 3.5)
        ] {
            sendMouse(.mouseMoved, windowPoint: cornerPt)
            #expect(panel.hoveredResizeHandle == .topLeft)
            #expect(panel.lastAppliedResizeCursor == tlCur)
        }

        sendMouse(.mouseMoved, windowPoint: CGPoint(x: 220, y: 300))
        #expect(panel.hoveredResizeHandle == nil)

        // 2. Positive WIDTH control: LEFT edge grow (-80pt x => +80pt width) and shrink (+40pt x => -40pt width)
        dragPanelViaSendEvent(fromStartInWindow: CGPoint(x: 1.5, y: panel.frame.height / 2), screenDelta: CGPoint(x: -80, y: 0))
        #expect(panel.frame.width == baseFrame.width + 80)
        #expect(panel.frame.height == baseFrame.height)
        #expect(panel.frame.maxX == baseFrame.maxX)

        dragPanelViaSendEvent(fromStartInWindow: CGPoint(x: 1.5, y: panel.frame.height / 2), screenDelta: CGPoint(x: 40, y: 0))
        #expect(panel.frame.width == baseFrame.width + 40)
        #expect(panel.frame.maxX == baseFrame.maxX)

        // 3. TOP EDGE vertical resize (at maxY - 3.5pt inside titlebar zone): grow (+70pt y) and shrink (-110pt y), keeping minY anchored
        let beforeTop = panel.frame
        dragPanelViaSendEvent(fromStartInWindow: CGPoint(x: beforeTop.width / 2, y: beforeTop.height - 3.5), screenDelta: CGPoint(x: 0, y: 70))
        #expect(panel.frame.height == beforeTop.height + 70)
        #expect(panel.frame.minY == beforeTop.minY)
        #expect(panel.frame.width == beforeTop.width)

        let afterTopGrow = panel.frame
        dragPanelViaSendEvent(fromStartInWindow: CGPoint(x: afterTopGrow.width / 2, y: afterTopGrow.height - 3.5), screenDelta: CGPoint(x: 0, y: -110))
        #expect(panel.frame.height == afterTopGrow.height - 110)
        #expect(panel.frame.minY == afterTopGrow.minY)

        // 4. TOP-LEFT CORNER diagonal resize (at lower rounded-corner arc `(1.5, height - 11)`): grows AND shrinks BOTH width & height
        let beforeTL = panel.frame
        dragPanelViaSendEvent(fromStartInWindow: CGPoint(x: 1.5, y: beforeTL.height - 11.0), screenDelta: CGPoint(x: -70, y: 80))
        #expect(panel.frame.width == beforeTL.width + 70)
        #expect(panel.frame.height == beforeTL.height + 80)
        #expect(panel.frame.maxX == beforeTL.maxX)
        #expect(panel.frame.minY == beforeTL.minY)

        let afterTLGrow = panel.frame
        dragPanelViaSendEvent(fromStartInWindow: CGPoint(x: 1.5, y: afterTLGrow.height - 11.0), screenDelta: CGPoint(x: 50, y: -60))
        #expect(panel.frame.width == afterTLGrow.width - 50)
        #expect(panel.frame.height == afterTLGrow.height - 60)
        #expect(panel.frame.maxX == afterTLGrow.maxX)
        #expect(panel.frame.minY == afterTLGrow.minY)

        // 5. Persistence across disk reload, pad switch (`selectPad`), and hide/show (`topRight` corner anchor too)
        let persistedSize = panel.frame.size
        #expect(model.state.settings.panelSizeUserCustomized == true)
        let reloadedDisk = store.load().state
        #expect(abs(reloadedDisk.settings.widthPercent - model.state.settings.widthPercent) < 0.05)
        #expect(abs(reloadedDisk.settings.heightPercent - model.state.settings.heightPercent) < 0.05)

        // Pad switch keeps resized dimensions (does NOT snap back to 66% x 76%)
        model.selectPad(model.state.pads[1].id)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(abs(panel.frame.width - persistedSize.width) <= 2)
        #expect(abs(panel.frame.height - persistedSize.height) <= 2)

        // Switch anchor to `.topRight`, hide, and show -> preserves resized width & height and diagonal corner vector
        model.state.settings.anchor = .topRight
        model.refreshPanelGeometryAndAppearance()
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(abs(panel.frame.width - persistedSize.width) <= 2)
        #expect(abs(panel.frame.height - persistedSize.height) <= 2)

        model.hidePanel()
        try await Task.sleep(nanoseconds: 160_000_000)
        #expect(panel.isVisible == false)
        model.showPanel(activateFocus: true, openedFromEdge: false)
        try await Task.sleep(nanoseconds: 160_000_000)
        #expect(panel.isVisible == true)
        #expect(abs(panel.frame.width - persistedSize.width) <= 2)
        #expect(abs(panel.frame.height - persistedSize.height) <= 2)

        // 6. Value-based rendered pixel-signature distinctness of public cursors (no opaque pointer identity reliance)
        let arrowSig = NativeOSWindowResizeAcceptanceRunner.samplePublicCursorSignature(.arrow)
        let leftSig = NativeOSWindowResizeAcceptanceRunner.samplePublicCursorSignature(leftCur)
        let topSig = NativeOSWindowResizeAcceptanceRunner.samplePublicCursorSignature(topCur)
        let tlSig = NativeOSWindowResizeAcceptanceRunner.samplePublicCursorSignature(tlCur)
        #expect(Set([arrowSig.pixelHashHex, leftSig.pixelHashHex, topSig.pixelHashHex, tlSig.pixelHashHex]).count == 4)

        // 7. Mid-resize `hidePanel()` state-transition: clears `activeResizeSession` immediately and does not leave `isInInteractiveResize` stuck
        sendMouse(.leftMouseDown, windowPoint: CGPoint(x: panel.frame.width / 2, y: panel.frame.height - 3.5))
        #expect(panel.activeResizeSession != nil)
        #expect(panel.isInInteractiveResize == true)
        model.hidePanel()
        #expect(panel.activeResizeSession == nil)
        #expect(panel.isInInteractiveResize == false)
        sendMouse(.leftMouseUp, windowPoint: CGPoint(x: panel.frame.width / 2, y: panel.frame.height - 90))
        try await Task.sleep(nanoseconds: 160_000_000)
        model.showPanel(activateFocus: true, openedFromEdge: false)
        try await Task.sleep(nanoseconds: 160_000_000)
        #expect(panel.isInInteractiveResize == false)
        #expect(abs(panel.frame.height - persistedSize.height) <= 2)

        // 8. Oversized top-left shrink clamps strictly to 320x340 with opposite bottom-right `(maxX, minY)` anchored
        //    (verifies `PanelRootView.makeHostingView` sizingOptions=[] prevents SwiftUI 333pt floor drift).
        let beforeMinClamp = panel.frame
        dragPanelViaSendEvent(
            fromStartInWindow: CGPoint(x: 4.5, y: beforeMinClamp.height - 4.5),
            screenDelta: CGPoint(x: 1200, y: -1100)
        )
        #expect(panel.frame.width == PanelGeometry.minPanelWidth)
        #expect(panel.frame.height == PanelGeometry.minPanelHeight)
        #expect(panel.frame.maxX == beforeMinClamp.maxX)
        #expect(panel.frame.minY == beforeMinClamp.minY)
    }

    // MARK: - 19. Safari Web Extension Containing-App Discovery, WKWebExtension(appExtensionBundle:) Load & Update Reload (t328)

    private func writeSyntheticSafariContainingApp(
        at appURL: URL,
        appName: String = "SyntheticTranslator",
        appShortVersion: String,
        appBuild: String,
        appexName: String = "SyntheticSafariExt.appex",
        appexBundleID: String = "com.example.synthetic.safari-translator",
        manifestName: String = "__MSG_extName__",
        manifestVersion: String,
        permissions: [String] = ["storage", "activeTab"],
        adHocCodeSign: Bool = false
    ) throws -> URL {
        let fm = FileManager.default
        let appContents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let pluginsDir = appContents.appendingPathComponent("PlugIns", isDirectory: true)
        try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)

        let appPlist: [String: Any] = [
            "CFBundleIdentifier": "com.example.synthetic.translator-app",
            "CFBundleName": appName,
            "CFBundleDisplayName": appName,
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": appShortVersion,
            "CFBundleVersion": appBuild
        ]
        try PropertyListSerialization.data(fromPropertyList: appPlist, format: .xml, options: 0)
            .write(to: appContents.appendingPathComponent("Info.plist"))

        // Non-Safari helper `.appex` that must be ignored by Safari discovery
        let nonSafariAppex = pluginsDir.appendingPathComponent("ShareHelper.appex/Contents", isDirectory: true)
        try fm.createDirectory(at: nonSafariAppex, withIntermediateDirectories: true)
        let nonSafariPlist: [String: Any] = [
            "CFBundleIdentifier": "com.example.synthetic.share-helper",
            "CFBundleName": "ShareHelper",
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.share-services"
            ]
        ]
        try PropertyListSerialization.data(fromPropertyList: nonSafariPlist, format: .xml, options: 0)
            .write(to: nonSafariAppex.appendingPathComponent("Info.plist"))

        // Target Safari Web Extension `.appex`
        let appexURL = pluginsDir.appendingPathComponent(appexName, isDirectory: true)
        let appexContents = appexURL.appendingPathComponent("Contents", isDirectory: true)
        let appexResources = appexContents.appendingPathComponent("Resources", isDirectory: true)
        let enLocaleDir = appexResources.appendingPathComponent("_locales/en", isDirectory: true)
        try fm.createDirectory(at: enLocaleDir, withIntermediateDirectories: true)

        var appexPlist: [String: Any] = [
            "CFBundleIdentifier": appexBundleID,
            "CFBundleName": appexURL.deletingPathExtension().lastPathComponent,
            "CFBundleDisplayName": "Synthetic Safari Translator",
            "CFBundlePackageType": "XPC!",
            "CFBundleShortVersionString": appShortVersion,
            "CFBundleVersion": appBuild,
            "NSExtension": [
                "NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
                "NSExtensionPrincipalClass": "SafariWebExtensionHandler"
            ]
        ]

        if adHocCodeSign {
            let macosDir = appexContents.appendingPathComponent("MacOS", isDirectory: true)
            try fm.createDirectory(at: macosDir, withIntermediateDirectories: true)
            let execName = appexURL.deletingPathExtension().lastPathComponent
            let stubSrc = appURL.deletingLastPathComponent().appendingPathComponent("stub-\(UUID().uuidString).c")
            defer { try? fm.removeItem(at: stubSrc) }
            try Data("int main(void) { return 0; }\n".utf8).write(to: stubSrc)
            let stubBin = macosDir.appendingPathComponent(execName)
            let cc = Process()
            cc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
            cc.arguments = [stubSrc.path, "-o", stubBin.path]
            cc.standardOutput = Pipe()
            cc.standardError = Pipe()
            try cc.run()
            cc.waitUntilExit()
            #expect(cc.terminationStatus == 0)
            appexPlist["CFBundleExecutable"] = execName
        }

        try PropertyListSerialization.data(fromPropertyList: appexPlist, format: .xml, options: 0)
            .write(to: appexContents.appendingPathComponent("Info.plist"))

        let messagesJSON = """
        {
          "extName": { "message": "Synthetic Safari Translator" }
        }
        """
        try Data(messagesJSON.utf8).write(to: enLocaleDir.appendingPathComponent("messages.json"))

        let manifestDict: [String: Any] = [
            "manifest_version": 3,
            "default_locale": "en",
            "name": manifestName,
            "version": manifestVersion,
            "permissions": permissions,
            "host_permissions": ["<all_urls>"],
            "action": ["default_title": "Synthetic Translate"]
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifestDict, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: appexResources.appendingPathComponent("manifest.json"))

        if adHocCodeSign {
            let cs = Process()
            cs.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
            cs.arguments = ["--force", "--sign", "-", appexURL.path]
            cs.standardOutput = Pipe()
            cs.standardError = Pipe()
            try cs.run()
            cs.waitUntilExit()
            #expect(cs.terminationStatus == 0)
        }

        return appexURL
    }

    @Test("Safari containing-app discovery, in-place registration, version-update reload, legacy JSON compatibility, and CLI flow (own synthetic .app/.appex fixtures)")
    func safariContainingAppDiscoveryRegistrationUpdateAndCLI() throws {
        // NOTE: Uses OWN synthetic `.app`/`.appex` fixtures in temporaryDirectory; does NOT prove compatibility
        // with any third-party Mac App Store extension (such as Immersive Translate).
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("VeypaneSafariExtCoreTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let appURL = tempRoot.appendingPathComponent("SyntheticTranslator.app", isDirectory: true)
        let v1AppexURL = try writeSyntheticSafariContainingApp(
            at: appURL,
            appShortVersion: "1.0.0",
            appBuild: "10",
            appexName: "SyntheticSafariExt.appex",
            manifestVersion: "1.0.0",
            permissions: ["storage", "activeTab", "cookies"]
        )

        // 1. Discover strictly Safari `.appex` (ignoring ShareHelper.appex)
        let discovered = try ExtensionPackageInstaller.discoverSafariWebExtensions(in: appURL)
        #expect(discovered.count == 1)
        #expect(discovered[0].containingAppURL?.standardizedFileURL == appURL.standardizedFileURL)
        #expect(discovered[0].appExtensionURL.standardizedFileURL == v1AppexURL.standardizedFileURL)
        #expect(discovered[0].appExtensionBundleID == "com.example.synthetic.safari-translator")
        #expect(discovered[0].appShortVersion == "1.0.0")
        #expect(discovered[0].appBuildVersion == "10")
        #expect(discovered[0].manifest.displayName == "Synthetic Safari Translator")
        #expect(discovered[0].manifest.version == "1.0.0")

        // Non-Safari `.app` returns clear error
        let emptyAppURL = tempRoot.appendingPathComponent("PlainApp.app", isDirectory: true)
        try fm.createDirectory(at: emptyAppURL.appendingPathComponent("Contents", isDirectory: true), withIntermediateDirectories: true)
        #expect(throws: ExtensionInstallError.safariWebExtensionNotFound(emptyAppURL.standardizedFileURL.path)) {
            _ = try ExtensionPackageInstaller.discoverSafariWebExtensions(in: emptyAppURL)
        }

        // 2. Register in-place (no files copied into Veypane's store)
        let registered = try ExtensionPackageInstaller.registerSafariAppExtensions(from: appURL)
        #expect(registered.count == 1)
        var record = registered[0]
        #expect(record.sourceKind == .safariAppExtension)
        #expect(record.folderName.isEmpty)
        #expect(record.sourceAppPath == appURL.standardizedFileURL.path)
        #expect(record.sourceAppExtensionPath == v1AppexURL.standardizedFileURL.path)
        #expect(record.sourceAppVersion == "1.0.0")
        #expect(record.sourceAppBuild == "10")
        #expect(!record.contextUniqueIdentifier.isEmpty)

        // Simulate user customizing Veypane's own permissions before app update
        record.websiteAccessMode = .specificSites
        record.allURLsGranted = false
        record.deniedPermissions = ["cookies"]
        record.grantedPermissions.removeAll { $0 == "cookies" }
        record.pinnedToToolbar = false

        // Up-to-date check before change
        let upToDateCheck = ExtensionPackageInstaller.checkSafariExtensionForUpdate(record)
        #expect(upToDateCheck.status == .upToDate)

        // 3. Simulate Mac App Store updating containing `.app` (1.0.0/10 -> 2.1.0/21) AND renaming `.appex` while keeping bundle ID
        try fm.removeItem(at: appURL)
        let v2AppexURL = try writeSyntheticSafariContainingApp(
            at: appURL,
            appShortVersion: "2.1.0",
            appBuild: "21",
            appexName: "SyntheticSafariExtV2.appex",
            manifestVersion: "2.1.0",
            permissions: ["storage", "activeTab", "cookies", "tabs"]
        )
        let updateCheck = ExtensionPackageInstaller.checkSafariExtensionForUpdate(record)
        guard case .updated(let oldV, let newV, let oldAppV, let newAppV) = updateCheck.status,
              let updated = updateCheck.updatedRecord else {
            Issue.record("Expected Safari extension .updated status, got \(updateCheck.status)")
            return
        }
        #expect(oldV == "1.0.0" && newV == "2.1.0")
        #expect(oldAppV == "1.0.0" && newAppV == "2.1.0")
        #expect(updated.id == record.id)
        #expect(updated.contextUniqueIdentifier == record.contextUniqueIdentifier)
        #expect(updated.sourceAppExtensionPath == v2AppexURL.standardizedFileURL.path)
        #expect(updated.websiteAccessMode == .specificSites)
        #expect(updated.pinnedToToolbar == false)
        #expect(updated.deniedPermissions == ["cookies"])
        #expect(!updated.grantedPermissions.contains("cookies"))
        #expect(updated.grantedPermissions.contains("tabs"))

        // 4. Legacy workspace JSON without Safari fields still decodes cleanly as `.copiedPackage`
        let legacyJSON = """
        {
          "id": "legacy-ext",
          "folderName": "legacy-ext",
          "displayName": "Legacy Ext",
          "version": "0.9"
        }
        """
        let decodedLegacy = try JSONDecoder().decode(InstalledExtension.self, from: Data(legacyJSON.utf8))
        #expect(decodedLegacy.sourceKind == .copiedPackage)
        #expect(decodedLegacy.sourceAppPath == nil)

        // 5. CLI `extensions add <app>` -> `extensions refresh` -> `extensions remove` (never deletes containing `.app`!)
        let cliStoreDir = tempRoot.appendingPathComponent("CLIStore", isDirectory: true)
        let ipc = MockIPCSender()
        let addOut = VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", cliStoreDir.path, "extensions", "add", appURL.path], ipcSender: ipc)
        #expect(addOut.exitCode == 0)
        #expect(addOut.stdout.contains("Linked Safari extension"))
        #expect(addOut.stdout.contains("v2.1.0"))

        // Update app again -> `extensions refresh` picks it up
        try fm.removeItem(at: appURL)
        _ = try writeSyntheticSafariContainingApp(
            at: appURL,
            appShortVersion: "2.2.0",
            appBuild: "22",
            appexName: "SyntheticSafariExtV2.appex",
            manifestVersion: "2.2.0"
        )
        let refreshOut = VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", cliStoreDir.path, "extensions", "refresh"], ipcSender: ipc)
        #expect(refreshOut.exitCode == 0)
        #expect(refreshOut.stdout.contains("2.1.0 -> 2.2.0"))

        let rmOut = VeypaneCLIRunner.run(arguments: ["veypanectl", "--store", cliStoreDir.path, "extensions", "remove", updated.id], ipcSender: ipc)
        #expect(rmOut.exitCode == 0)
        // CRITICAL: Unlinking Safari extension in Veypane must NEVER remove the installed `.app`!
        #expect(fm.fileExists(atPath: appURL.path) == true)

        // Missing source detection after `.app` is deleted
        try fm.removeItem(at: appURL)
        let missingCheck = ExtensionPackageInstaller.checkSafariExtensionForUpdate(updated)
        if case .sourceMissing = missingCheck.status {
            // Expected
        } else {
            Issue.record("Expected .sourceMissing after containing app removal, got \(missingCheck.status)")
        }
    }

    @Test("macOS 15.4+ ExtensionManager loads signed synthetic Safari .appex via WKWebExtension(appExtensionBundle:), reloads on app update preserving own context/permissions, and fails closed on unsigned or post-signing-tampered .appex")
    @MainActor
    func safariAppExtensionWKWebExtensionLoadUpdateAndIsolation() async throws {
        // NOTE: Own synthetic `.app`/`.appex` fixture runtime verification on macOS 15.4+ WKWebExtensionController;
        // does NOT constitute compatibility proof for third-party Mac App Store extensions (e.g. Immersive Translate).
        guard #available(macOS 15.4, *) else { return }

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent("VeypaneSafariRuntimeTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempRoot) }
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)

        let storeDir = tempRoot.appendingPathComponent("Store", isDirectory: true)
        let store = VeypaneStore(directoryURL: storeDir)
        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        let manager = model.extensionManager

        // 1. Install ad-hoc codesigned synthetic Safari `.app` once -> loads via `WKWebExtension(appExtensionBundle:)`
        let signedAppURL = tempRoot.appendingPathComponent("SignedSyntheticSafari.app", isDirectory: true)
        _ = try writeSyntheticSafariContainingApp(
            at: signedAppURL,
            appName: "SignedSyntheticSafari",
            appShortVersion: "1.0.0",
            appBuild: "100",
            appexBundleID: "com.example.synthetic.signed-safari",
            manifestVersion: "1.0.0",
            adHocCodeSign: true
        )

        let installedList = try await manager.installSafariAppExtensions(from: signedAppURL)
        #expect(installedList.count == 1)
        let extID = installedList[0].id
        let originalContextUID = installedList[0].contextUniqueIdentifier

        #expect(manager.loadedMode(for: extID) == .appExtensionBundle)
        let settingsBefore = try #require(manager.settingsItems().first(where: { $0.id == extID }))
        #expect(settingsBefore.isLoaded == true)
        #expect(settingsBefore.sourceKind == .safariAppExtension)
        #expect(settingsBefore.sourceAppDisplayName == "SignedSyntheticSafari")
        #expect(settingsBefore.version == "1.0.0")
        #expect(settingsBefore.loadMode == .appExtensionBundle)
        // Confirm zero extension files were copied into Veypane's `Extensions/` store directory
        let copiedEntries = (try? fm.contentsOfDirectory(atPath: store.extensionsDirectoryURL.path)) ?? []
        #expect(copiedEntries.isEmpty)

        // Configure Veypane's own isolated permissions (never touching Safari)
        manager.setWebsiteAccessMode(id: extID, mode: .specificSites)
        manager.addSpecificSitePattern(id: extID, pattern: "https://example.com/*")

        // 2. Update the containing `.app` on disk (1.0.0 -> 2.0.0) and trigger update-reload
        try fm.removeItem(at: signedAppURL)
        _ = try writeSyntheticSafariContainingApp(
            at: signedAppURL,
            appName: "SignedSyntheticSafari",
            appShortVersion: "2.0.0",
            appBuild: "200",
            appexBundleID: "com.example.synthetic.signed-safari",
            manifestVersion: "2.0.0",
            adHocCodeSign: true
        )

        let updateResults = await manager.checkAndReloadSafariExtensionUpdates(extensionID: extID)
        #expect(updateResults.count == 1)
        if case .updated(let oldV, let newV, _, _) = updateResults[0].status {
            #expect(oldV == "1.0.0" && newV == "2.0.0")
        } else {
            Issue.record("Expected .updated on containing app upgrade, got \(updateResults[0].status)")
        }
        #expect(manager.loadedMode(for: extID) == .appExtensionBundle)
        let updatedRecord = try #require(model.state.installedExtensions.first(where: { $0.id == extID }))
        #expect(updatedRecord.version == "2.0.0")
        #expect(updatedRecord.sourceAppVersion == "2.0.0")
        #expect(updatedRecord.contextUniqueIdentifier == originalContextUID)
        #expect(updatedRecord.websiteAccessMode == .specificSites)
        #expect(updatedRecord.grantedMatchPatterns.contains("https://example.com/*"))

        // 3. Unsigned synthetic `.appex` MUST fail closed (never silently downgrade to `resourceBaseURL`)
        let unsignedAppURL = tempRoot.appendingPathComponent("UnsignedSyntheticSafari.app", isDirectory: true)
        _ = try writeSyntheticSafariContainingApp(
            at: unsignedAppURL,
            appName: "UnsignedSyntheticSafari",
            appShortVersion: "1.0.0",
            appBuild: "1",
            appexBundleID: "com.example.synthetic.unsigned-safari",
            manifestVersion: "1.0.0",
            adHocCodeSign: false
        )
        let unsignedInstalled = try await manager.installSafariAppExtensions(from: unsignedAppURL)
        #expect(unsignedInstalled.count == 1)
        let unsignedID = unsignedInstalled[0].id
        #expect(manager.loadedMode(for: unsignedID) == nil)
        let unsignedItem = try #require(manager.settingsItems().first(where: { $0.id == unsignedID }))
        #expect(unsignedItem.isLoaded == false)
        #expect(unsignedItem.errors.contains(where: { $0.contains("code signature validation failed") }))

        // 4. Post-signing-tampered synthetic `.appex` (ad-hoc signed first, then `manifest.json` modified)
        //    MUST ALSO fail closed and never silently load unsigned resources!
        let tamperedAppURL = tempRoot.appendingPathComponent("TamperedSyntheticSafari.app", isDirectory: true)
        let tamperedAppexURL = try writeSyntheticSafariContainingApp(
            at: tamperedAppURL,
            appName: "TamperedSyntheticSafari",
            appShortVersion: "1.0.0",
            appBuild: "1",
            appexBundleID: "com.example.synthetic.tampered-safari",
            manifestVersion: "1.0.0",
            adHocCodeSign: true
        )
        let tamperedManifestURL = tamperedAppexURL
            .appendingPathComponent("Contents/Resources/manifest.json", isDirectory: false)
        var tamperedManifestData = try Data(contentsOf: tamperedManifestURL)
        tamperedManifestData.append(Data("\n".utf8))
        try tamperedManifestData.write(to: tamperedManifestURL, options: .atomic)

        let tamperedInstalled = try await manager.installSafariAppExtensions(from: tamperedAppURL)
        #expect(tamperedInstalled.count == 1)
        let tamperedID = tamperedInstalled[0].id
        #expect(manager.loadedMode(for: tamperedID) == nil)
        let tamperedItem = try #require(manager.settingsItems().first(where: { $0.id == tamperedID }))
        #expect(tamperedItem.isLoaded == false)
        #expect(tamperedItem.errors.contains(where: { $0.contains("code signature validation failed") }))

        // 5. Removing linked Safari extensions clears Veypane state without deleting any containing `.app`
        await manager.removeExtension(id: extID)
        await manager.removeExtension(id: unsignedID)
        await manager.removeExtension(id: tamperedID)
        #expect(model.state.installedExtensions.isEmpty)
        #expect(fm.fileExists(atPath: signedAppURL.path) == true)
        #expect(fm.fileExists(atPath: unsignedAppURL.path) == true)
        #expect(fm.fileExists(atPath: tamperedAppURL.path) == true)
    }

    @Test("Sidebar movePad persistence and Escape cancellation during active sidebar drag without hiding panel")
    @MainActor
    func sidebarMovePadPersistenceAndEscapeCancelDuringDrag() throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("VeypaneSidebarUnitTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        let store = VeypaneStore(directoryURL: tempDir)
        let pA = Pad(title: "Alpha", hasCustomTitle: true, url: URL(string: "about:blank")!)
        let pB = Pad(title: "Beta", hasCustomTitle: true, url: URL(string: "about:blank")!)
        let pC = Pad(title: "Gamma", hasCustomTitle: true, url: URL(string: "about:blank")!)
        var st = WorkspaceState(pads: [pA, pB, pC])
        st.selectedPadID = pA.id
        try store.save(st)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.isPanelVisible = true

        // Move down & to bottom, verify exact IDs and persistence across fresh AppModel
        model.movePad(id: pA.id, toIndex: 2)
        #expect(model.state.pads.map(\.id) == [pB.id, pC.id, pA.id])
        let reloaded = AppModel(store: VeypaneStore(directoryURL: tempDir), allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        #expect(reloaded.state.pads.map(\.id) == [pB.id, pC.id, pA.id])

        // Escape key while sidebar drag is active increments cancel token synchronously, clears drag state, and does NOT hide panel
        model.isSidebarPadDragActive = true
        let tokenBefore = model.sidebarPadDragCancelToken
        let escEvent = try #require(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: 0,
                context: nil,
                characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}",
                isARepeat: false,
                keyCode: 53
            )
        )
        let consumed = model.processPanelKeyDownEvent(escEvent)
        #expect(consumed == nil)
        #expect(model.isSidebarPadDragActive == false)
        #expect(model.sidebarPadDragCancelToken == tokenBefore + 1)
        #expect(model.isPanelVisible == true)
    }

    @Test("Active resize session preserves diagonal cursor on out-of-band hover events and resyncs perimeter cursor rects on frame shrink")
    @MainActor
    func resizeCursorActiveSessionGuardAndSynchronousRectResync() throws {
        _ = NSApplication.shared
        let panel = SlideOverPanel(contentRect: NSRect(x: 712, y: 245, width: 1194, height: 720))
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1194, height: 720))

        let tlCur = SlideOverPanel.resizeCursor(for: .topLeft)
        let started = panel.beginInteractiveResize(
            atScreenPoint: CGPoint(x: 716, y: 960),
            windowPointOverride: CGPoint(x: 4.0, y: 715.0)
        )
        #expect(started == .topLeft)
        #expect(panel.hoveredResizeHandle == .topLeft)
        #expect(panel.lastAppliedResizeCursor == tlCur)

        // Out-of-frame and interior hover callbacks during an active resize session must never wipe the resize cursor.
        #expect(panel.evaluateResizeHover(atWindowPoint: CGPoint(x: -6.5, y: 726.0)) == .topLeft)
        #expect(panel.hoveredResizeHandle == .topLeft)
        #expect(panel.lastAppliedResizeCursor == tlCur)
        #expect(panel.evaluateResizeHover(atWindowPoint: CGPoint(x: 400, y: 300)) == .topLeft)
        #expect(panel.hoveredResizeHandle == .topLeft)

        panel.cancelInteractiveResizeIfNeeded()
        #expect(panel.activeResizeSession == nil)
        #expect(panel.hoveredResizeHandle == nil)

        // Shrinking the panel back to 1114x652 must synchronously resync cursor rects so the topLeft rect
        // covers (10, 648.5) and (4.5, 647.5) immediately instead of retaining stale 1194x720 rects.
        panel.setFrame(NSRect(x: 792, y: 245, width: 1114, height: 652), display: true)
        panel.syncPerimeterCursorOverlayFrame()

        let overlay = try #require(panel.perimeterCursorOverlayView)
        let topLeftRect = try #require(overlay.lastRegisteredCursorRects.first(where: { $0.handle == .topLeft })?.rect)
        #expect(topLeftRect.contains(CGPoint(x: 10.0, y: 648.5)))
        #expect(topLeftRect.contains(CGPoint(x: 4.5, y: 647.5)))
        #expect(abs(topLeftRect.maxY - 652.0) <= 0.5)
    }

    @Test("t347 seamless borderless top-edge chrome eliminates 32pt titlebar band while keeping top/corner resize, menubar clamping, and unobstructed navigation")
    @MainActor
    func seamlessTopEdgeChromeMenubarClampAndUnobstructedNavigation() throws {
        _ = NSApplication.shared
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("VeypaneT347Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = VeypaneStore(directoryURL: tempDir)
        var state = WorkspaceState(pads: [
            Pad(title: "Alpha", url: URL(string: "about:blank")!)
        ])
        state.settings.hasCompletedOnboarding = true
        state.settings.appearance.cornerRadius = 12
        state.settings.appearance.hasShadow = true
        try store.save(state)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        let hosting = PanelRootView.makeHostingView(model: model)
        let visibleBounds = NSRect(x: 0, y: 40, width: 1920, height: 1015) // maxY = 1055 (right below 25pt menu bar)
        let panel = SlideOverPanel(contentRect: NSRect(x: 800, y: 260, width: 900, height: 600))
        panel.screenVisibleFrameForResizeProvider = { visibleBounds }
        panel.contentView = hosting
        panel.applyAppearance(state.settings.appearance, isAlwaysOnTop: false)
        panel.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        panel.syncPerimeterCursorOverlayFrame()

        // 1. Borderless seamless chrome: zero titlebar subviews, zero top safe-area gap, clear backing, continuous rounded clip
        #expect(!panel.styleMask.contains(.titled))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.styleMask.contains(.resizable))
        #expect(panel.isOpaque == false)
        #expect(panel.hasShadow == true)
        #expect((panel.backgroundColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? panel.backgroundColor.alphaComponent) == 0.0)
        #expect(hosting.safeAreaInsets.top == 0.0)
        #expect(abs(panel.contentLayoutRect.height - panel.frame.height) <= 0.5)
        #expect(hosting.layer?.cornerRadius == 12.0)
        #expect(hosting.layer?.masksToBounds == true)
        let frameView = try #require(hosting.superview)
        #expect(frameView.subviews.filter { NSStringFromClass(type(of: $0)).contains("Titlebar") }.isEmpty)

        // 2. Top-edge & top-left corner hit-test cleanly while 34pt header navigation buttons (ptFromTop = 6..30, center = 18) pass through
        let overlay = try #require(panel.perimeterCursorOverlayView)
        let h = panel.frame.height
        #expect(overlay.hitTest(CGPoint(x: panel.frame.width / 2, y: h - 3.5)) === overlay)
        #expect(overlay.hitTest(CGPoint(x: 3.5, y: h - 10.0)) === overlay)
        #expect(overlay.hitTest(CGPoint(x: 10.0, y: h - 3.5)) === overlay)
        #expect(overlay.hitTest(CGPoint(x: 4.5, y: h - 4.5)) === overlay)
        for navButtonPt in [
            CGPoint(x: 74, y: h - 18),   // Back
            CGPoint(x: 100, y: h - 18),  // Forward
            CGPoint(x: 126, y: h - 18),  // Reload
            CGPoint(x: 840, y: h - 18)   // Trailing toolbar actions
        ] {
            #expect(overlay.hitTest(navButtonPt) == nil, "Resize overlay must not obstruct nav button at \(navButtonPt)")
        }

        // 3. Menubar-adjacent top-edge & top-left resize: dragging upward clamps strictly to screenVisibleFrame.maxY (never over menu bar)
        let startTop = CGPoint(x: panel.frame.midX, y: panel.frame.maxY - 3.5)
        #expect(panel.beginInteractiveResize(atScreenPoint: startTop) == .top)
        let clampedAtMenubar = try #require(panel.endInteractiveResize(atScreenPoint: CGPoint(x: startTop.x, y: visibleBounds.maxY + 120)))
        #expect(abs(clampedAtMenubar.maxY - visibleBounds.maxY) <= 0.5)
        #expect(abs(clampedAtMenubar.minY - 260) <= 0.5)

        // Right below the menu bar, top-left diagonal handle remains directly hittable and shrinks cleanly to min size
        let nearMenubarCorner = CGPoint(x: panel.frame.minX + 4.5, y: panel.frame.maxY - 4.5)
        #expect(panel.evaluateResizeHover(atWindowPoint: panel.convertPoint(fromScreen: nearMenubarCorner)) == .topLeft)
        #expect(panel.beginInteractiveResize(atScreenPoint: nearMenubarCorner) == .topLeft)
        let minClamped = try #require(panel.endInteractiveResize(atScreenPoint: CGPoint(x: nearMenubarCorner.x + 1200, y: nearMenubarCorner.y - 1200)))
        #expect(abs(minClamped.width - PanelGeometry.minPanelWidth) <= 1.0)
        #expect(abs(minClamped.height - PanelGeometry.minPanelHeight) <= 1.0)
        #expect(abs(minClamped.maxX - clampedAtMenubar.maxX) <= 1.0)
        #expect(abs(minClamped.minY - clampedAtMenubar.minY) <= 1.0)
    }

    @Test("t385 disableAnimations instant show/hide/resize, pin/always-on-top helpers, chrome-only swipe isolation, and Settings dismissal decision tracking")
    @MainActor
    func t385DisableAnimationsPinAlwaysOnTopSwipeIsolationAndSettingsDecision() throws {
        _ = NSApplication.shared
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("VeypaneT385Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // 1. Backward-compatible AppSettings decoding (`disableAnimations` defaults to false when absent, round-trips true)
        let legacyJSON = Data("{\"isPinnedOpen\":true}".utf8)
        let decodedLegacy = try JSONDecoder().decode(AppSettings.self, from: legacyJSON)
        #expect(decodedLegacy.isPinnedOpen == true)
        #expect(decodedLegacy.disableAnimations == false)

        let store = VeypaneStore(directoryURL: tempDir)
        var state = WorkspaceState(pads: [
            Pad(title: "Alpha", url: URL(string: "about:blank")!),
            Pad(title: "Beta", url: URL(string: "about:blank")!)
        ])
        state.settings.hasCompletedOnboarding = true
        state.settings.disableAnimations = false
        try store.save(state)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.startRuntimeServices {
            PanelRootView.makeHostingView(model: model)
        }
        defer { model.stopRuntimeServices() }

        let panel = try #require(model.panel)

        // 2. Pin & Always-on-Top helpers + live cornerRadius / compactSidebar sync
        #expect(panel.level == .floating)
        model.setAlwaysOnTop(true)
        #expect(model.state.settings.isAlwaysOnTop == true)
        #expect(panel.level == .statusBar)
        #expect(store.load().state.settings.isAlwaysOnTop == true)

        model.togglePinnedOpen()
        #expect(model.state.settings.isPinnedOpen == true)
        #expect(store.load().state.settings.isPinnedOpen == true)

        let compactMetrics = PanelChromeMetrics.forAppearance(compactSidebar: true)
        model.state.settings.appearance.cornerRadius = 18
        model.state.settings.appearance.compactSidebar = true
        model.refreshPanelGeometryAndAppearance()
        #expect(panel.contentView?.layer?.cornerRadius == 18.0)
        #expect(panel.sidebarStripWidth == compactMetrics.sidebarStripWidth)

        // 3. Disable animations: instant synchronous show, resize, and hide with zero activeAnimationFlight
        model.setDisableAnimations(true)
        #expect(panel.animationsDisabled == true)
        #expect(store.load().state.settings.disableAnimations == true)

        let visRect = NSRect(x: -15000, y: -15000, width: 800, height: 540)
        let hidRect = NSRect(x: -14000, y: -15000, width: 800, height: 540)
        var showCompletedGen: UInt64 = 0
        panel.slideIn(
            from: hidRect,
            to: visRect,
            generation: 11,
            duration: 0.22,
            activateKeyFocus: false
        ) { gen in
            showCompletedGen = gen
        }
        #expect(showCompletedGen == 11)
        #expect(panel.activeAnimationFlight == nil)
        #expect(panel.alphaValue == 1.0)
        #expect(panel.frame == visRect)

        let resizedRect = NSRect(x: -15050, y: -15000, width: 850, height: 540)
        panel.resizeSmoothly(to: resizedRect, duration: 0.22)
        #expect(panel.frame == resizedRect)

        var hideCompleted = false
        panel.slideOut(
            from: resizedRect,
            to: hidRect,
            generation: 12,
            duration: 0.22,
            shouldFinalizeHide: { $0 == 12 }
        ) {
            hideCompleted = true
        }
        #expect(hideCompleted == true)
        #expect(panel.activeAnimationFlight == nil)
        #expect(panel.alphaValue == 0.0)
        #expect(panel.isVisible == false)

        // 4. Back/Forward gesture preservation: WKWebView has allowsBackForwardNavigationGestures == true,
        // and SlideOverPanel does NOT hijack swipes over the webpage (even at y = H - 38 or x = 52 in compact 48pt mode).
        let padWC = model.webController(for: model.state.pads[0])
        #expect(padWC.webView.allowsBackForwardNavigationGestures == true)

        var capturedActions: [PanelGestureAction] = []
        panel.onGestureAction = { capturedActions.append($0) }
        panel.gesturesEnabled = true
        panel.setFrame(NSRect(x: -15000, y: -15000, width: 800, height: 540), display: false)

        // Directly verify SlideOverPanel's exact chrome boundary geometry from shared PanelChromeMetrics
        #expect(panel.headerBarHeight == PanelChromeMetrics.headerBarHeight)
        #expect(panel.sidebarStripWidth == compactMetrics.sidebarStripWidth)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 400, y: 540 - 16)) == true)  // inside 34pt header
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: compactMetrics.sidebarStripWidth / 2.0, y: 270)) == true) // inside compact sidebar
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 400, y: 540 - 38)) == false) // webpage top (never stolen by header)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: compactMetrics.sidebarStripWidth + 4.0, y: 270)) == false) // webpage left (never stolen by sidebar)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 400, y: 270)) == false)      // webpage center
        #expect(capturedActions.isEmpty)

        // 5. Settings outside-click dismissal decision is preserved even if a trailing event arrives after panel hides
        model.setPinnedOpen(false)
        model.setAlwaysOnTop(false)
        _ = model.transitionController.beginShow()
        _ = model.transitionController.completeShow(generation: model.transitionController.generation)
        let dis0 = model.outsideClickDismissalsTriggered
        let firstDec = model.handlePointerDownForOutsideDismissal(
            origin: .sameApplicationOtherStandardWindow,
            screenLocation: CGPoint(x: 100, y: 100)
        )
        #expect(firstDec == .dismissPanel(.sameApplicationOtherWindowClick))
        #expect(model.outsideClickDismissalsTriggered == dis0 + 1)
        #expect(model.lastOutsideClickDismissalDecision == .dismissPanel(.sameApplicationOtherWindowClick))

        // Trailing event after panel is already hidden records panelNotVisible in lastOutsideClickDecision
        // without clobbering lastOutsideClickDismissalDecision.
        let trailingDec = model.handlePointerDownForOutsideDismissal(
            origin: .sameApplicationOtherStandardWindow,
            screenLocation: CGPoint(x: 100, y: 100)
        )
        #expect(trailingDec == .keepOpen(.panelNotVisible))
        #expect(model.lastOutsideClickDecision == .keepOpen(.panelNotVisible))
        #expect(model.lastOutsideClickDismissalDecision == .dismissPanel(.sameApplicationOtherWindowClick))
    }

    @Test(
        "Genuine OS CGEvent window resize acceptance on production SlideOverPanel & NSHostingView (opt-in via VEYPANE_RUN_OS_RESIZE_TESTS=1)",
        .enabled(if: ProcessInfo.processInfo.environment["VEYPANE_RUN_OS_RESIZE_TESTS"] == "1")
    )
    @MainActor
    func genuineOSWindowResizeAcceptance() async throws {
        let env = ProcessInfo.processInfo.environment
        let customOutPath = env["VEYPANE_OS_RESIZE_REPORT_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let usesCustomDir = (customOutPath?.isEmpty == false)
        let outDir = usesCustomDir
            ? URL(fileURLWithPath: customOutPath!, isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent(
                "VeypaneOSWindowResizeTest-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            if !usesCustomDir {
                try? FileManager.default.removeItem(at: outDir)
            }
        }

        let report = try await NativeOSWindowResizeAcceptanceRunner.runAcceptance(
            into: outDir,
            reportFilename: NativeOSWindowResizeAcceptanceRunner.defaultReportFilename
        )

        #expect(report.cgPostEventAccess == true)
        #expect(report.isolatedTemporaryStore == true)
        #expect(report.nonPersistentWebDataStore == true)
        #expect(report.selfOwnedBackdropVerified == true)
        #expect(report.interiorHoverRestoresArrowVerified == true)
        #expect(report.leftEdgePositiveWidthControlVerified == true)
        #expect(report.topEdgeVerticalGrowAndShrinkVerified == true)
        #expect(report.topLeftCornerDiagonalGrowAndShrinkVerified == true)
        #expect(report.minSizeAndScreenBoundsClampVerified == true)
        #expect(report.persistenceAcrossPadSwitchAndHideShowVerified == true)
        #expect(report.midResizeHideCancelsSessionCleanlyVerified == true)
        #expect(report.totalDragCases == 8)
        #expect(report.passedDragCases == report.totalDragCases)
        #expect(report.passedAllChecks == true)
        for item in report.cases {
            #expect(item.preDragPanelOnscreenConfirmed == true, "Panel not onscreen in \(item.caseName)")
            #expect(item.targetOwnedBySelfPIDConfirmed == true, "Target not owned by selfPID in \(item.caseName)")
            #expect(item.osHIDEventsDequeued >= 8, "Insufficient OS HID events dequeued in \(item.caseName)")
            #expect(item.cursorMatchesExpectedPublicFrameResize == true, "Public hover cursor mismatch in \(item.caseName)")
            #expect(item.oppositeSideAnchored == true, "Opposite side not anchored in \(item.caseName)")
            #expect(item.passed == true, "Failed OS resize case: \(item.caseName)")
        }
    }

    @Test("Veypane branding uses unified Veypane identifiers across storage, bundle, IPC, URL, CLI, menu, intents, and notifications")
    @MainActor
    func veypaneUnifiedIdentityRegression() throws {
        // 1. Display and bundle branding use canonical Veypane identifiers
        #expect(AppBrandIdentity.productName == "Veypane")
        #expect(AppBrandIdentity.appBundleName == "Veypane.app")
        #expect(AppBrandIdentity.appArchiveName == "Veypane.zip")

        // 2. Storage, bundle, IPC, URL, CLI, CSS rule, and notification identifiers use Veypane exclusively
        #expect(AppBrandIdentity.bundleIdentifier == "com.veypane.app")
        #expect(AppBrandIdentity.urlSchemeBundleName == "com.veypane.urlscheme")
        #expect(AppBrandIdentity.applicationSupportFolderName == "Veypane")
        #expect(AppBrandIdentity.bundleExecutableName == "VeypaneApp")
        #expect(AppBrandIdentity.primaryURLScheme == "veypane")
        #expect(AppBrandIdentity.supportedURLSchemes == ["veypane"])
        #expect(AppBrandIdentity.primaryCLIName == "veypanectl")
        #expect(AppBrandIdentity.supportedCLINames == ["veypanectl"])
        #expect(VeypaneIPC.distributedNotificationName == Notification.Name("com.veypane.ipc.command"))
        #expect(WebNotificationBridge.handlerName == "veypaneNotify")
        #expect(WebNotificationBridge.bootstrapJavaScript.contains("window.__veypaneNotificationsInstalled"))
        #expect(WebNotificationBridge.bootstrapJavaScript.contains("messageHandlers.veypaneNotify"))
        #expect(VeypaneStore().directoryURL.lastPathComponent == "Veypane")
        #expect(VeypaneStore.defaultiCloudSyncFolderURL.lastPathComponent == "Veypane")
        #expect(VeypaneStore.syncSnapshotFileName == "veypane-sync.json")
        let cssScript = try #require(ContentRulesEngine.makeCSSInjectionScript(css: "body {}", ruleID: UUID()))
        #expect(cssScript.contains("veypane-css-"))

        // 3. Menus, AppIntents, and Diagnostics reflect Veypane branding
        let mainMenu = MainMenuBuilder.buildMainMenu()
        #expect(mainMenu.items.first?.title == "Veypane")
        #expect(mainMenu.items.first?.submenu?.title == "Veypane")
        #expect(SiteDiagnosticsReport.pauseModificationsScopeStatement.contains("Veypane"))
        #expect(String(localized: ToggleVeypaneIntent.title) == "Toggle Veypane Panel")
        #expect(String(localized: OpenVeypanePadIntent.title) == "Open URL in Veypane Pad")
        #expect(String(localized: AddVeypanePadIntent.title) == "Add Veypane Pad")

        // 4. Both en and zh-Hans Localizable.strings resolve Veypane strings cleanly
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        for lang in ["en", "zh-Hans"] {
            let stringsURL = repoRoot
                .appendingPathComponent("Sources/VeypaneCore/Resources/\(lang).lproj/Localizable.strings")
            let raw = try String(contentsOf: stringsURL, encoding: .utf8)
            #expect(raw.contains("Veypane"), "Expected Veypane branding in \(lang) Localizable.strings")
            #expect(L10n.string("app.name", language: lang) == "Veypane")
            #expect(L10n.string("settings.window_title", language: lang).contains("Veypane"))
            #expect(L10n.string("welcome.window_title", language: lang).contains("Veypane"))
            #expect(L10n.string("menu.quit", language: lang).contains("Veypane"))
        }

        // 5. Packaging script produces pure Veypane bundle metadata, executable, CLI, icon, and URL scheme
        let bundleScript = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/bundle.sh"),
            encoding: .utf8
        )
        #expect(bundleScript.contains("APP_BUNDLE=\"$OUTPUT_DIR/Veypane.app\""))
        #expect(bundleScript.contains("APP_ARCHIVE=\"$OUTPUT_DIR/Veypane.zip\""))
        #expect(bundleScript.contains("<key>CFBundleDisplayName</key>\n    <string>Veypane</string>"))
        #expect(bundleScript.contains("<key>CFBundleName</key>\n    <string>Veypane</string>"))
        #expect(bundleScript.contains("<key>CFBundleIdentifier</key>\n    <string>com.veypane.app</string>"))
        #expect(bundleScript.contains("<key>CFBundleExecutable</key>\n    <string>VeypaneApp</string>"))
        #expect(bundleScript.contains("<key>CFBundleURLName</key>\n            <string>com.veypane.urlscheme</string>"))
        #expect(bundleScript.contains("<key>CFBundleIconFile</key>\n    <string>Veypane</string>"))
        #expect(bundleScript.contains("<string>veypane</string>"))
        #expect(bundleScript.contains("<key>CFBundleShortVersionString</key>\n    <string>\(AppBrandIdentity.marketingVersion)</string>"))
        #expect(bundleScript.contains("<key>CFBundleVersion</key>\n    <string>\(AppBrandIdentity.buildNumber)</string>"))
    }

    @Test("t396 slimmer narrow sidebar metrics, visual-vs-hit separation, resize perimeter clearance, chrome gesture boundaries, and 1.2.7 build 10 version sync")
    @MainActor
    func t393NarrowSidebarMetricsHitBoundsAndVersionSync() throws {
        let regular = PanelChromeMetrics.forAppearance(compactSidebar: false)
        let compact = PanelChromeMetrics.forAppearance(compactSidebar: true)

        // 1. Tightened macOS point dimensions vs 1.2.6 b9 (44/38pt -> 36/32pt strip, 22/20pt -> 18/16pt icons, 41/36pt -> 34/29pt pitch)
        #expect(regular.sidebarStripWidth == 36.0)
        #expect(regular.totalSidebarRailWidth == 37.0)
        #expect(compact.sidebarStripWidth == 32.0)
        #expect(compact.totalSidebarRailWidth == 33.0)
        #expect(PanelChromeMetrics.headerBarHeight == 34.0)
        #expect(PanelChromeMetrics.topResizeEdgeThickness == 5.0)

        // 2. Visual icon footprint is crisp and strictly smaller than interactive clickable hit target
        #expect(regular.padVisualIconSize == 18.0)
        #expect(regular.padHighlightSize == 24.0)
        #expect(regular.padHitTargetWidth == 26.0)
        #expect(regular.padHitTargetHeight == 30.0)
        #expect(regular.padVisualIconSize < regular.padHighlightSize)
        #expect(regular.padHighlightSize < regular.padHitTargetWidth)
        #expect(regular.padRowSpacing == 4.0)
        #expect(regular.padRowPitch == 34.0)
        #expect(regular.addButtonVisualSize == 22.0)
        #expect(regular.addButtonHitHeight == 28.0)
        #expect(regular.bottomActionVisualSize == 22.0)
        #expect(regular.bottomActionHitHeight == 26.0)

        #expect(compact.padVisualIconSize == 16.0)
        #expect(compact.padHighlightSize == 21.0)
        #expect(compact.padHitTargetWidth == 22.0)
        #expect(compact.padHitTargetHeight == 26.0)
        #expect(compact.padVisualIconSize < compact.padHighlightSize)
        #expect(compact.padHighlightSize < compact.padHitTargetWidth)
        #expect(compact.padRowSpacing == 3.0)
        #expect(compact.padRowPitch == 29.0)
        #expect(compact.addButtonVisualSize == 20.0)
        #expect(compact.addButtonHitHeight == 24.0)
        #expect(compact.bottomActionVisualSize == 20.0)
        #expect(compact.bottomActionHitHeight == 24.0)

        // 3. Resize perimeter non-overlap: hit target clears left 5pt resize edge AND first pad clears top-left 15pt corner
        let panelSize = CGSize(width: 800, height: 540)
        for m in [regular, compact] {
            #expect(m.padHitHorizontalInset >= PanelGeometry.defaultResizeEdgeBand)
            #expect(m.padListTopPadding >= PanelGeometry.defaultResizeCornerSpan)

            let firstCenter = m.fallbackPadCenterInWindow(index: 0, panelHeight: panelSize.height)
            #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: firstCenter, windowSize: panelSize) == nil)

            // Top-left corner and 5pt top/left resize edges remain intact
            #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 4, y: panelSize.height - 4), windowSize: panelSize) == .topLeft)
            #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 3, y: panelSize.height / 2), windowSize: panelSize) == .left)
            #expect(PanelGeometry.hitTestResizeHandle(pointInWindow: CGPoint(x: 200, y: panelSize.height - 2), windowSize: panelSize) == .top)
        }

        // 4. SlideOverPanel live appearance & chrome-only gesture boundaries track PanelChromeMetrics identically
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneNarrowSidebarTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = VeypaneStore(directoryURL: tempDir)
        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.startRuntimeServices {
            PanelRootView.makeHostingView(model: model)
        }
        defer { model.stopRuntimeServices() }

        let panel = try #require(model.panel)
        panel.setFrame(NSRect(x: -15000, y: -15000, width: panelSize.width, height: panelSize.height), display: false)
        panel.gesturesEnabled = true

        // Regular (36pt) mode
        model.state.settings.appearance.compactSidebar = false
        model.refreshPanelGeometryAndAppearance()
        #expect(panel.sidebarStripWidth == regular.sidebarStripWidth)
        #expect(panel.headerBarHeight == PanelChromeMetrics.headerBarHeight)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 18, y: 270)) == true)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 36, y: 270)) == true)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 38, y: 270)) == false) // webpage left (never stolen by old 44pt!)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 400, y: panelSize.height - 34)) == true)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 400, y: panelSize.height - 36)) == false)

        // Compact (32pt) mode
        model.state.settings.appearance.compactSidebar = true
        model.refreshPanelGeometryAndAppearance()
        #expect(panel.sidebarStripWidth == compact.sidebarStripWidth)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 16, y: 270)) == true)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 34, y: 270)) == false) // webpage left (never stolen by old 38pt!)

        // 5. Version consistency across AppBrandIdentity, en/zh-Hans About strings, and scripts/bundle.sh
        #expect(AppBrandIdentity.marketingVersion == "1.2.10")
        #expect(AppBrandIdentity.buildNumber == "13")
        #expect(L10n.string("settings.about.version", language: "en") == "Version 1.2.10")
        #expect(L10n.string("settings.about.version", language: "zh-Hans") == "版本 1.2.10")
    }

    @Test("t398 customizable sidebar width & icon size: defaults, bounds clamping, per-mode isolation, live panel layout/gestures, persistence, reset, and export/import/sync compatibility")
    @MainActor
    func t398CustomizableSidebarSizingPersistenceExportAndLivePanelRegression() throws {
        // 1. Default values match 1.2.7 build 10 defaults cleanly
        var appearance = AppearanceSettings()
        #expect(appearance.isActiveSidebarSizingCustomized == false)
        let defReg = PanelChromeMetrics.forAppearance(appearance)
        #expect(defReg.sidebarStripWidth == 36.0)
        #expect(defReg.padVisualIconSize == 18.0)

        appearance.compactSidebar = true
        let defCmp = PanelChromeMetrics.forAppearance(appearance)
        #expect(defCmp.sidebarStripWidth == 32.0)
        #expect(defCmp.padVisualIconSize == 16.0)

        // 2. Exhaustive bounds & icon-fit invariant check across all (width, icon) inputs including out-of-range
        for compact in [false, true] {
            for rawW in [-20.0, 28.0, 32.0, 36.0, 44.0, 56.0, 64.0, 120.0] {
                for rawI in [-5.0, 12.0, 16.0, 18.0, 24.0, 36.0, 80.0] {
                    var a = AppearanceSettings(compactSidebar: compact)
                    a.setActiveSidebarWidth(rawW)
                    a.setActiveSidebarIconSize(rawI)
                    let m = PanelChromeMetrics.forAppearance(a)
                    #expect(m.sidebarStripWidth >= PanelChromeMetrics.minSidebarWidth)
                    #expect(m.sidebarStripWidth <= PanelChromeMetrics.maxSidebarWidth)
                    #expect(m.padVisualIconSize >= PanelChromeMetrics.minPadIconSize)
                    #expect(m.padVisualIconSize <= PanelChromeMetrics.maxIconSize(forSidebarWidth: m.sidebarStripWidth))
                    #expect(m.padVisualIconSize <= m.sidebarStripWidth - PanelChromeMetrics.minIconHorizontalClearance)
                    #expect(m.padVisualIconSize < m.padHighlightSize)
                    #expect(m.padHighlightSize < m.padHitTargetWidth)
                    #expect(m.padHitHorizontalInset >= PanelGeometry.defaultResizeEdgeBand)
                    #expect(m.padListTopPadding >= PanelGeometry.defaultResizeCornerSpan)
                }
            }
        }

        // Narrowing width dynamically clamps an oversized icon so icon never overflows sidebar
        var narrowTest = AppearanceSettings(compactSidebar: false)
        narrowTest.setActiveSidebarWidth(54.0)
        narrowTest.setActiveSidebarIconSize(30.0)
        #expect(PanelChromeMetrics.forAppearance(narrowTest).padVisualIconSize == 30.0)
        narrowTest.setActiveSidebarWidth(30.0)
        #expect(narrowTest.sidebarWidthRegular == 30.0)
        #expect(narrowTest.sidebarIconSizeRegular == 18.0) // 30 - 12 = 18 max
        #expect(PanelChromeMetrics.forAppearance(narrowTest).padVisualIconSize == 18.0)

        // 3. Live AppModel + mounted SlideOverPanel + NSHostingView<PanelRootView>:
        //    proves live panel layout, chrome-only gesture boundaries, per-mode isolation, restart persistence, and one-click reset
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneT398Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = VeypaneStore(directoryURL: tempDir)
        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.startRuntimeServices {
            PanelRootView.makeHostingView(model: model)
        }
        defer { model.stopRuntimeServices() }

        let panel = try #require(model.panel)
        let panelSize = CGSize(width: 820, height: 560)
        panel.setFrame(NSRect(x: -15000, y: -15000, width: panelSize.width, height: panelSize.height), display: false)
        panel.gesturesEnabled = true

        // Customize Default mode to 52pt width / 26pt icon -> panel chrome & gesture boundary update immediately
        model.state.settings.appearance.compactSidebar = false
        model.setSidebarWidth(52.0)
        model.setSidebarIconSize(26.0)
        #expect(panel.sidebarStripWidth == 52.0)
        #expect(panel.headerBarHeight == 34.0)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 50, y: 280)) == true)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 54, y: 280)) == false) // webpage never hijacked
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 400, y: panelSize.height - 34)) == true)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 400, y: panelSize.height - 36)) == false)

        // Switch to Compact mode -> defaults to 32/16 without clobbering Regular's 52/26; customize Compact to 30/14
        model.state.settings.appearance.compactSidebar = true
        model.refreshPanelGeometryAndAppearance()
        #expect(panel.sidebarStripWidth == 32.0)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 34, y: 280)) == false)
        model.setSidebarWidth(30.0)
        model.setSidebarIconSize(14.0)
        #expect(panel.sidebarStripWidth == 30.0)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 29, y: 280)) == true)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 32, y: 280)) == false)

        // Switch back to Regular -> Regular's 52/26 is preserved intact!
        model.state.settings.appearance.compactSidebar = false
        model.refreshPanelGeometryAndAppearance()
        model.persistState()
        #expect(panel.sidebarStripWidth == 52.0)
        #expect(PanelChromeMetrics.forAppearance(model.state.settings.appearance).padVisualIconSize == 26.0)

        // Restart persistence: fresh VeypaneStore load recovers BOTH Regular (52/26) and Compact (30/14)
        let reloaded = VeypaneStore(directoryURL: tempDir).load().state
        #expect(reloaded.settings.appearance.sidebarWidthRegular == 52.0)
        #expect(reloaded.settings.appearance.sidebarIconSizeRegular == 26.0)
        #expect(reloaded.settings.appearance.sidebarWidthCompact == 30.0)
        #expect(reloaded.settings.appearance.sidebarIconSizeCompact == 14.0)

        // 4. Settings Export / Import AND Folder Sync include all 4 custom sidebar sizing fields
        let exportedData = try store.exportData(from: reloaded)
        let freshBase = WorkspaceState.makeDefault()
        let imported = try store.importData(exportedData, into: freshBase, merge: false)
        #expect(imported.settings.appearance.sidebarWidthRegular == 52.0)
        #expect(imported.settings.appearance.sidebarIconSizeRegular == 26.0)
        #expect(imported.settings.appearance.sidebarWidthCompact == 30.0)
        #expect(imported.settings.appearance.sidebarIconSizeCompact == 14.0)

        let syncDir = tempDir.appendingPathComponent("SyncMirror", isDirectory: true)
        var newerState = reloaded
        newerState.updatedAt = Date().addingTimeInterval(60)
        try store.writeSyncSnapshot(for: newerState, toDirectory: syncDir)
        let synced = try #require(try store.loadNewerSyncSnapshotIfAvailable(fromDirectory: syncDir, currentState: freshBase))
        #expect(synced.settings.appearance.sidebarWidthRegular == 52.0)
        #expect(synced.settings.appearance.sidebarIconSizeRegular == 26.0)
        #expect(synced.settings.appearance.sidebarWidthCompact == 30.0)
        #expect(synced.settings.appearance.sidebarIconSizeCompact == 14.0)

        // 5. Legacy JSON without new fields decodes cleanly to safe defaults; out-of-bounds JSON clamps safely
        let legacyAppearanceJSON = """
        {
          "theme": "dark",
          "vibrancySidebar": true,
          "cornerRadius": 12,
          "hasShadow": true,
          "compactSidebar": false,
          "launchAtLogin": false,
          "showMenuBarIcon": true
        }
        """
        let decodedLegacy = try JSONDecoder().decode(AppearanceSettings.self, from: Data(legacyAppearanceJSON.utf8))
        #expect(decodedLegacy.sidebarWidthRegular == nil)
        #expect(decodedLegacy.sidebarIconSizeRegular == nil)
        #expect(PanelChromeMetrics.forAppearance(decodedLegacy).sidebarStripWidth == 36.0)
        #expect(PanelChromeMetrics.forAppearance(decodedLegacy).padVisualIconSize == 18.0)

        let outOfBoundsJSON = """
        {
          "theme": "system",
          "vibrancySidebar": true,
          "cornerRadius": 12,
          "hasShadow": true,
          "compactSidebar": false,
          "sidebarWidthRegular": 10,
          "sidebarIconSizeRegular": 99,
          "sidebarWidthCompact": 200,
          "sidebarIconSizeCompact": 2,
          "launchAtLogin": false,
          "showMenuBarIcon": true
        }
        """
        let decodedClamped = try JSONDecoder().decode(AppearanceSettings.self, from: Data(outOfBoundsJSON.utf8))
        #expect(decodedClamped.sidebarWidthRegular == 28.0)
        #expect(decodedClamped.sidebarIconSizeRegular == 16.0) // 28 - 12 = 16
        #expect(decodedClamped.sidebarWidthCompact == 64.0)
        #expect(decodedClamped.sidebarIconSizeCompact == 12.0)

        // 6. One-click restore default resets ONLY the active mode back to 1.2.7 default & persists cleanly
        model.resetSidebarSizingToDefault()
        #expect(model.state.settings.appearance.sidebarWidthRegular == nil)
        #expect(model.state.settings.appearance.sidebarIconSizeRegular == nil)
        #expect(model.state.settings.appearance.sidebarWidthCompact == 30.0) // Compact preserved!
        #expect(model.state.settings.appearance.sidebarIconSizeCompact == 14.0)
        #expect(panel.sidebarStripWidth == 36.0)
        #expect(panel.shouldHandleChromeGesture(atWindowPoint: CGPoint(x: 38, y: 280)) == false)
        let afterReset = VeypaneStore(directoryURL: tempDir).load().state
        #expect(afterReset.settings.appearance.sidebarWidthRegular == nil)
        #expect(afterReset.settings.appearance.sidebarWidthCompact == 30.0)

        // Localized labels present in both en & zh-Hans
        for lang in ["en", "zh-Hans"] {
            #expect(L10n.string("settings.appearance.sidebar_width", language: lang) != "settings.appearance.sidebar_width")
            #expect(L10n.string("settings.appearance.sidebar_icon_size", language: lang) != "settings.appearance.sidebar_icon_size")
            #expect(L10n.format("settings.appearance.sidebar_reset_default", language: lang, 36, 18).contains("36"))
        }
    }

    @Test("t455 A->B->A preserves WKWebView identity/DOM/scroll without reload, fixes departing lastActiveAt bug, and verifies timeout/capacity/Always Keep/persistence/export/memory-pressure/renderer-crash degradation")
    @MainActor
    func t455PadLifecycleKeepAliveMemoryPressureAndRendererRecovery() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneT455Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = VeypaneStore(directoryURL: tempDir)

        let t0 = Date(timeIntervalSince1970: 1_760_000_000)
        var initial = WorkspaceState.makeDefault()
        initial.settings.autoHibernateMinutes = 30
        initial.settings.maxLivePads = 0
        let padA = Pad(title: "Local A", url: URL(string: "about:blank")!, lastActiveAt: t0)
        let padB = Pad(title: "Local B", url: URL(string: "about:blank")!, lastActiveAt: t0)
        let padC = Pad(title: "Local C", url: URL(string: "about:blank")!, lastActiveAt: t0)
        initial.pads = [padA, padB, padC]
        initial.selectedPadID = padA.id
        try store.save(initial)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.areExtensionsReady = true

        // Mount real PadDeckContainerNSView offscreen (zero GUI shown, zero external network)
        let deck = PadDeckContainerNSView(frame: NSRect(x: 0, y: 0, width: 720, height: 500))
        let wcA = model.webController(for: padA)
        let wcB = model.webController(for: padB)
        deck.syncDeck(entries: model.deckMountedWebViews(), selectedPadID: model.selectedPad?.id)

        let htmlA = """
        <!doctype html><html><body style="height:2000px;margin:0;">
        <input id="draft" value="initial" />
        <script>window.__t455Marker = "alive-A";</script>
        </body></html>
        """
        let htmlB = "<!doctype html><html><body><p>Page B</p></body></html>"
        wcA.webView.loadHTMLString(htmlA, baseURL: nil)
        wcB.webView.loadHTMLString(htmlB, baseURL: nil)

        // Wait briefly for local HTML loads to complete
        for _ in 0..<40 {
            if !wcA.webView.isLoading && !wcB.webView.isLoading {
                let marker = try? await wcA.webView.evaluateJavaScript("window.__t455Marker") as? String
                if marker == "alive-A" { break }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        // Mutate DOM input & scroll position on Pad A
        _ = try await wcA.webView.evaluateJavaScript("""
            document.getElementById('draft').value = 'unsaved-user-text';
            window.__t455Marker = 'mutated-A';
            window.scrollTo(0, 320);
            true;
        """)

        let creationsBefore = model.diagnostics.webViewCreations
        let loadsBefore = model.diagnostics.loadRequests
        let reloadsBefore = model.diagnostics.reloadRequests

        // 1. Reproduce the pre-fix stale-lastActiveAt bug scenario:
        //    User stayed on Pad A for 45 minutes (> 30m timeout), then switches A -> B.
        //    selectPad MUST refresh A's lastActiveAt so a timer tick 2 minutes later does NOT evict A!
        let idxA = try #require(model.state.pads.firstIndex(where: { $0.id == padA.id }))
        model.state.pads[idxA].lastActiveAt = Date().addingTimeInterval(-45 * 60)
        model.selectPad(padB.id)
        deck.syncDeck(entries: model.deckMountedWebViews(), selectedPadID: model.selectedPad?.id)
        #expect(wcA.webView.isHidden == true)
        #expect(wcB.webView.isHidden == false)

        let hibernatedAfter2Min = model.runIdleHibernationPass(now: Date().addingTimeInterval(2 * 60))
        #expect(!hibernatedAfter2Min.contains(padA.id), "Departing Pad A must NOT be evicted right after switching A->B")
        #expect(model.existingWebController(for: padA.id) === wcA)

        // Switch B -> A: exact same WKWebView instance, zero new creations/loads/reloads, DOM + scroll intact
        model.selectPad(padA.id)
        deck.syncDeck(entries: model.deckMountedWebViews(), selectedPadID: model.selectedPad?.id)
        #expect(model.existingWebController(for: padA.id) === wcA)
        #expect(model.existingWebView(for: padA.id) === wcA.webView)
        #expect(wcA.webView.isHidden == false)
        #expect(model.diagnostics.webViewCreations == creationsBefore)
        #expect(model.diagnostics.loadRequests == loadsBefore)
        #expect(model.diagnostics.reloadRequests == reloadsBefore)

        let preservedMarker = try await wcA.webView.evaluateJavaScript("window.__t455Marker") as? String
        let preservedInput = try await wcA.webView.evaluateJavaScript("document.getElementById('draft').value") as? String
        let preservedScrollY = try await wcA.webView.evaluateJavaScript("window.scrollY") as? Double
        #expect(preservedMarker == "mutated-A")
        #expect(preservedInput == "unsaved-user-text")
        #expect((preservedScrollY ?? 0) >= 200.0)

        // 2. Timeout logic: after 35 minutes truly idle in background, Pad B sleeps while selected Pad A stays live
        let hibernatedAfter35Min = model.runIdleHibernationPass(now: Date().addingTimeInterval(35 * 60))
        #expect(hibernatedAfter35Min.contains(padB.id))
        #expect(!hibernatedAfter35Min.contains(padA.id))
        #expect(model.existingWebController(for: padB.id) == nil)
        #expect(model.existingWebController(for: padA.id) === wcA)

        // 3. Always Keep (`autoHibernateMinutes == 0`): 72 hours idle evicts ZERO pads
        model.setPageRetention(autoHibernateMinutes: 0, maxLivePads: 0)
        model.setHibernated(false, for: padB.id)
        _ = model.webController(for: padC)
        let alwaysKeepEvicted = model.runIdleHibernationPass(now: Date().addingTimeInterval(72 * 3600))
        #expect(alwaysKeepEvicted.isEmpty)
        #expect(model.existingWebController(for: padA.id) != nil)
        #expect(model.existingWebController(for: padB.id) != nil)
        #expect(model.existingWebController(for: padC.id) != nil)

        // 4. Capacity limit (`maxLivePads == 2`): LRU evicts stalest background pad while keeping selected + newest background
        let nowCap = Date()
        if let iB = model.state.pads.firstIndex(where: { $0.id == padB.id }) {
            model.state.pads[iB].lastActiveAt = nowCap.addingTimeInterval(-600) // stalest
        }
        if let iC = model.state.pads.firstIndex(where: { $0.id == padC.id }) {
            model.state.pads[iC].lastActiveAt = nowCap.addingTimeInterval(-60) // newer
        }
        model.setPageRetention(maxLivePads: 2)
        #expect(model.existingWebController(for: padB.id) == nil)
        #expect(model.existingWebController(for: padA.id) === wcA)
        #expect(model.existingWebController(for: padC.id) != nil)
        #expect(model.diagnostics.capacityEvictions >= 1)

        // 5. Memory-pressure degradation:
        //    - `.warning` in Always Keep (0) does NOT proactively evict
        //    - `.warning` in timed mode evicts stalest background pad
        //    - `.critical` evicts eligible background pad even in Always Keep, ALWAYS protecting selected Pad A
        model.setPageRetention(autoHibernateMinutes: 0, maxLivePads: 0)
        model.setHibernated(false, for: padB.id)
        let warnAlways = model.handleSystemMemoryPressure(.warning)
        #expect(warnAlways.isEmpty)
        #expect(model.existingWebController(for: padB.id) != nil)
        #expect(model.existingWebController(for: padC.id) != nil)

        model.setPageRetention(autoHibernateMinutes: 120, maxLivePads: 0)
        let warnTimed = model.handleSystemMemoryPressure(.warning)
        #expect(warnTimed.count == 1)
        #expect(!warnTimed.contains(padA.id))

        model.setPageRetention(autoHibernateMinutes: 0, maxLivePads: 0)
        model.setHibernated(false, for: padB.id)
        let critAlways = model.handleSystemMemoryPressure(.critical)
        #expect(!critAlways.isEmpty)
        #expect(!critAlways.contains(padA.id))
        #expect(model.existingWebController(for: padA.id) === wcA)
        #expect(model.diagnostics.memoryPressureEvictions >= critAlways.count)

        // 6. Renderer crash (`webViewWebContentProcessDidTerminate`) degradation + anti-loop guard:
        //    Background pad defers reload until selected; foreground repeated crashes suppress infinite reload loop.
        model.setHibernated(false, for: padB.id)
        let wcBLive = try #require(model.existingWebController(for: padB.id))
        let reloadsBeforeBgCrash = model.diagnostics.reloadRequests
        let creationsBeforeBgCrash = model.diagnostics.webViewCreations
        wcBLive.handleWebContentProcessTermination(now: Date())
        #expect(wcBLive.processRecoveryState.needsRecovery == true)
        #expect(model.diagnostics.reloadRequests == reloadsBeforeBgCrash, "Background crash must defer reload until focused")

        model.selectPad(padB.id)
        #expect(model.existingWebController(for: padB.id) === wcBLive)
        #expect(model.diagnostics.webViewCreations == creationsBeforeBgCrash)
        #expect(model.diagnostics.reloadRequests == reloadsBeforeBgCrash + 1)
        #expect(model.diagnostics.webContentAutoRecoveries >= 1)

        // Rapid second foreground crash within cooldown suppresses auto-reload loop cleanly
        let reloadsBeforeRapidCrash = model.diagnostics.reloadRequests
        wcBLive.handleWebContentProcessTermination(now: Date())
        #expect(model.diagnostics.reloadRequests == reloadsBeforeRapidCrash, "Rapid repeated crash must not infinite-loop reload")
        #expect(model.statusMessage == L10n.string("panel.status.web_process_manual_reload"))

        // 7. Removing a pad releases its WKWebView cleanly
        model.removePad(padC.id)
        #expect(model.existingWebController(for: padC.id) == nil)

        // 8. Persistence, Export/Import, Folder Sync & Legacy JSON Migration/Clamping
        model.setPageRetention(autoHibernateMinutes: 0, maxLivePads: 10)
        let reloaded = VeypaneStore(directoryURL: tempDir).load().state
        #expect(reloaded.settings.autoHibernateMinutes == 0)
        #expect(reloaded.settings.maxLivePads == 10)

        let exported = try store.exportData(from: reloaded)
        let imported = try store.importData(exported, into: WorkspaceState.makeDefault(), merge: false)
        #expect(imported.settings.autoHibernateMinutes == 0)
        #expect(imported.settings.maxLivePads == 10)

        let syncDir = tempDir.appendingPathComponent("SyncT455", isDirectory: true)
        var newer = reloaded
        newer.updatedAt = Date().addingTimeInterval(60)
        try store.writeSyncSnapshot(for: newer, toDirectory: syncDir)
        let synced = try #require(try store.loadNewerSyncSnapshotIfAvailable(fromDirectory: syncDir, currentState: WorkspaceState.makeDefault()))
        #expect(synced.settings.autoHibernateMinutes == 0)
        #expect(synced.settings.maxLivePads == 10)

        // Legacy AppSettings JSON missing autoHibernateMinutes & maxLivePads -> safe defaults (120, 0); invalid values clamp
        let legacyEmpty = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(legacyEmpty.autoHibernateMinutes == AppSettings.defaultAutoHibernateMinutes)
        #expect(legacyEmpty.maxLivePads == AppSettings.defaultMaxLivePads)

        let invalidBounds = try JSONDecoder().decode(
            AppSettings.self,
            from: Data(#"{"autoHibernateMinutes": -25, "maxLivePads": 999}"#.utf8)
        )
        #expect(invalidBounds.autoHibernateMinutes == 0)
        #expect(invalidBounds.maxLivePads == AppSettings.maxLivePadsUpperBound)

        // Honest localized caption & labels exist in both en & zh-Hans
        for lang in ["en", "zh-Hans"] {
            #expect(L10n.string("settings.profiles.retention_always", language: lang) != "settings.profiles.retention_always")
            #expect(L10n.string("settings.profiles.retention_caption", language: lang) != "settings.profiles.retention_caption")
        }
    }

    @Test("Veypane canonical interfaces, URL/CLI/HTTP auth enforcement, store/sync migration, MIT LICENSE, and 1.2.10 build 13 verification")
    @MainActor
    func veypaneCanonicalInterfacesMigrationAndLicenseRegression() async throws {
        // 1. Primary Veypane URL scheme (and OmniboxParser support); unknown schemes rejected
        let openURL = try #require(URL(string: "veypane://open?url=https%3A%2F%2Fswift.org&pad=Docs"))
        #expect(VeypaneURLCommand.parse(openURL) == .openURL(url: URL(string: "https://swift.org")!, padQuery: "Docs", inNewPad: false))
        #expect(OmniboxParser.resolve(input: "veypane://toggle") == .directURL(URL(string: "veypane://toggle")!))
        #expect(VeypaneURLCommand.parse(try #require(URL(string: "unknownapp://toggle"))) == nil)
        #expect(VeypaneURLCommand.makeURL(for: .showPanel)?.absoluteString == "veypane://show")

        // 2. Primary veypanectl CLI interface
        let ipc = MockIPCSender()
        #expect(VeypaneCLIRunner.run(arguments: ["veypanectl", "url", "toggle"], ipcSender: ipc).stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "veypane://toggle")
        let extUsage = VeypaneCLIRunner.run(arguments: ["veypanectl", "extensions", "unknown-cmd"], ipcSender: ipc)
        #expect(extUsage.exitCode == 2)
        #expect(extUsage.stderr.contains("Usage: veypanectl extensions"))

        // 3. LocalAutomationServer accepts Authorization: Bearer and X-Veypane-Token only
        let bridge = MockAutomationBridge()
        let server = LocalAutomationServer(
            settings: AutomationSettings(isEnabled: true, port: 0, authToken: "veypane-secret", allowLimitedJS: false),
            bridge: bridge
        )
        try await server.start()
        defer { Task { await server.stop() } }
        let port = try #require(await server.boundPort)
        let healthURL = URL(string: "http://127.0.0.1:\(port)/v1/health")!

        for (header, value) in [
            ("Authorization", "Bearer veypane-secret"),
            ("X-Veypane-Token", "veypane-secret")
        ] {
            var req = URLRequest(url: healthURL)
            req.setValue(value, forHTTPHeaderField: header)
            let (_, resp) = try await URLSession.shared.data(for: req)
            let http = try #require(resp as? HTTPURLResponse)
            #expect(http.statusCode == 200, "Expected 200 for auth header \(header)")
        }

        // Unrecognized custom token header is rejected with 401
        var badHeaderReq = URLRequest(url: healthURL)
        badHeaderReq.setValue("veypane-secret", forHTTPHeaderField: "X-Other-Token")
        let (_, badResp) = try await URLSession.shared.data(for: badHeaderReq)
        #expect((badResp as? HTTPURLResponse)?.statusCode == 401)

        // MCP initialize reports Veypane + 1.2.10
        var mcpReq = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        mcpReq.httpMethod = "POST"
        mcpReq.setValue("veypane-secret", forHTTPHeaderField: "X-Veypane-Token")
        mcpReq.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let (mcpData, _) = try await URLSession.shared.data(for: mcpReq)
        let mcpText = String(decoding: mcpData, as: UTF8.self)
        #expect(mcpText.contains("\"name\":\"Veypane\""))
        #expect(mcpText.contains("\"version\":\"1.2.10\""))

        // 4. Canonical Application Support/Veypane path, v1 workspace.json schema migration, and veypane-sync.json
        #expect(VeypaneStore().directoryURL.lastPathComponent == "Veypane")
        #expect(VeypaneStore.defaultiCloudSyncFolderURL.lastPathComponent == "Veypane")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VeypaneIdentity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let v1JSON = """
        {
          "schemaVersion": 1,
          "pads": [
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "title": "Custom Title",
              "url": "https://example.com"
            }
          ]
        }
        """
        try Data(v1JSON.utf8).write(to: tempDir.appendingPathComponent("workspace.json"))
        let store = VeypaneStore(directoryURL: tempDir)
        let loaded = store.load()
        #expect(loaded.didRecoverFromCorruption == false)
        #expect(loaded.migratedFromVersion == 1)
        #expect(loaded.state.pads.first?.title == "Custom Title")
        #expect(loaded.state.pads.first?.hasCustomTitle == true)

        // veypane-sync.json is written & read as the canonical sync snapshot
        let syncDir = tempDir.appendingPathComponent("SyncCanonical", isDirectory: true)
        var syncState = loaded.state
        syncState.settings.autoHibernateMinutes = 0
        syncState.updatedAt = Date().addingTimeInterval(120)
        try store.writeSyncSnapshot(for: syncState, toDirectory: syncDir)
        #expect(FileManager.default.fileExists(atPath: syncDir.appendingPathComponent("veypane-sync.json").path))
        let fromSync = try #require(try store.loadNewerSyncSnapshotIfAvailable(fromDirectory: syncDir, currentState: WorkspaceState.makeDefault()))
        #expect(fromSync.settings.autoHibernateMinutes == 0)

        var newerVeypaneState = syncState
        newerVeypaneState.settings.autoHibernateMinutes = 240
        newerVeypaneState.updatedAt = Date().addingTimeInterval(360)
        try store.writeSyncSnapshot(for: newerVeypaneState, toDirectory: syncDir)
        let fromUpdatedSync = try #require(try store.loadNewerSyncSnapshotIfAvailable(fromDirectory: syncDir, currentState: syncState))
        #expect(fromUpdatedSync.settings.autoHibernateMinutes == 240)

        // 5. Icon resource resolves Veypane.icns, MIT LICENSE & NOTICE.md present, bundle.sh registers veypane only
        let iconURL = try #require(L10n.iconFileURL)
        #expect(iconURL.lastPathComponent == "Veypane.icns")

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let licenseText = try String(contentsOf: repoRoot.appendingPathComponent("LICENSE"), encoding: .utf8)
        #expect(licenseText.contains("MIT License"))
        #expect(licenseText.contains("Copyright (c) 2026 Lorin Lee"))
        let noticeText = try String(contentsOf: repoRoot.appendingPathComponent("NOTICE.md"), encoding: .utf8)
        #expect(noticeText.contains("Apple"))
        #expect(noticeText.contains("SF Symbols"))
        let bundleScript = try String(contentsOf: repoRoot.appendingPathComponent("scripts/bundle.sh"), encoding: .utf8)
        #expect(bundleScript.contains("<string>veypane</string>"))
        #expect(bundleScript.contains("veypanectl"))
        #expect(bundleScript.contains("VeypaneApp"))
        #expect(bundleScript.contains("com.veypane.app"))
    }
}
