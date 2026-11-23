import AppKit
import Foundation
import SwiftUI
import WebKit
import VeypaneCore

/// Isolated responder spy that records standard macOS editing action selectors (`copy:`, `paste:`, `cut:`,
/// `selectAll:`, `undo:`, `redo:`) in memory without calling `super`.
@MainActor
public final class IsolatedEditingResponderSpyView: NSView {
    public private(set) var receivedSelectors: [String] = []

    public override var acceptsFirstResponder: Bool { true }

    @objc public func copy(_ sender: Any?) {
        receivedSelectors.append("copy:")
    }

    @objc public func paste(_ sender: Any?) {
        receivedSelectors.append("paste:")
    }

    @objc public func cut(_ sender: Any?) {
        receivedSelectors.append("cut:")
    }

    public override func selectAll(_ sender: Any?) {
        receivedSelectors.append("selectAll:")
    }

    @objc public func undo(_ sender: Any?) {
        receivedSelectors.append("undo:")
    }

    @objc public func redo(_ sender: Any?) {
        receivedSelectors.append("redo:")
    }
}

@MainActor
private final class ProbeEditFallbackDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    weak var activePanel: SlideOverPanel?

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action, let panel = activePanel else { return false }
        return panel.canDispatchSelectorInResponderChain(action, menuItem: menuItem)
    }

    @objc func undo(_ sender: Any?) { _ = activePanel?.dispatchStandardEditCommandToResponderChain(.undo) }
    @objc func redo(_ sender: Any?) { _ = activePanel?.dispatchStandardEditCommandToResponderChain(.redo) }
    @objc func cut(_ sender: Any?) { _ = activePanel?.dispatchStandardEditCommandToResponderChain(.cut) }
    @objc func copy(_ sender: Any?) { _ = activePanel?.dispatchStandardEditCommandToResponderChain(.copy) }
    @objc func paste(_ sender: Any?) { _ = activePanel?.dispatchStandardEditCommandToResponderChain(.paste) }
    @objc func selectAll(_ sender: Any?) { _ = activePanel?.dispatchStandardEditCommandToResponderChain(.selectAll) }
}

public struct EditingSurfaceE2EResult: Codable, Sendable {
    public var surface: String
    public var firstResponderClass: String
    public var responderCanUndoBeforeUndo: Bool
    public var seedValue: String
    public var valueAfterCut: String
    public var valueAfterUndoCut: String
    public var valueAfterRedoCut: String
    public var valueAfterPaste: String
    public var valueAfterUndoPaste: String
    public var valueAfterRedoPaste: String
    public var copyVerified: Bool
    public var cutVerified: Bool
    public var pasteVerified: Bool
    public var selectAllVerified: Bool
    public var undoCutVerified: Bool
    public var redoCutVerified: Bool
    public var undoPasteVerified: Bool
    public var redoPasteVerified: Bool
    public var undoVerified: Bool
    public var redoVerified: Bool

    public var allPassed: Bool {
        copyVerified && cutVerified && pasteVerified && selectAllVerified && undoVerified && redoVerified
    }
}

public struct EditingShortcutProbeReport: Codable, Sendable {
    public var generatedAt: Date
    public var isolatedTemporaryStore: Bool
    public var nonPersistentWebDataStore: Bool
    public var previousClipboardReadOrBackedUp: Bool
    public var initialClipboardUnconditionallyOverwrittenWithSyntheticSeed: Bool
    public var finalSyntheticMarkerWritten: String
    public var keyEventInjectionLevel: String
    public var mainMenuNilTargetSelectorsVerified: Bool
    public var localShortcutMonitorBypassVerified: Bool
    public var extensionShortcutBypassVerified: Bool
    public var responderSpyRoutedSelectors: [String]
    public var responderSpyAllSixMatched: Bool
    public var focusRestoredOnShowAndPadSwitch: Bool
    public var windowUndoEmptyBeforeWebTests: Bool
    public var nativeFieldFocusPreservedDuringAddressEdit: Bool
    public var focusRestoredAfterAddressCancel: Bool
    public var nativeAddressFieldE2E: EditingSurfaceE2EResult
    public var webInputE2E: EditingSurfaceE2EResult
    public var webTextareaE2E: EditingSurfaceE2EResult
    public var webContentEditableE2E: EditingSurfaceE2EResult
    public var webDocumentSelectionCopyAndSelectAllVerified: Bool
    public var passedAllChecks: Bool
}

/// Isolated `--editing-shortcut-probe <outputDir>` runner with authorized synthetic clipboard E2E verification.
/// Safety rules enforced strictly:
/// 1. Unconditionally `clearContents()` + writes known synthetic non-sensitive seed BEFORE any pasteboard read.
/// 2. NEVER reads, backs up, or attempts to restore prior clipboard contents.
/// 3. Uses isolated temporary store + `WKWebsiteDataStore.nonPersistent()`, never launching `AppModel.shared`.
/// 4. Injects synthetic `NSEvent.keyEvent` events through `AppModel.processPanelKeyDownEvent` ->
///    `SlideOverPanel.performKeyEquivalent` -> `WKWebView` / `NSTextField` -> production `MainMenuBuilder` Edit menu.
/// 5. Leaves a clearly synthetic marker (`VEYPANE_SYNTHETIC_TEST_MARKER_DO_NOT_RESTORE`) on exit.
@MainActor
public enum EditingShortcutProbeRunner {
    public static let initialSyntheticSeed = "VEYPANE_SYNTHETIC_INITIAL_SEED_000"
    public static let finalSyntheticMarker = "VEYPANE_SYNTHETIC_TEST_MARKER_DO_NOT_RESTORE"

    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.mainMenu = MainMenuBuilder.buildMainMenu()

        // Hard 50s watchdog (< 60s limit)
        DispatchQueue.global().asyncAfter(deadline: .now() + 50.0) {
            FileHandle.standardError.write(Data("Editing shortcut probe timed out after 50s\n".utf8))
            Darwin.exit(2)
        }

        Task { @MainActor in
            do {
                let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
                try await runProbe(into: outDir)
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Editing shortcut probe failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    public static func makeSyntheticCommandKeyEvent(
        characters: String,
        keyCode: UInt16,
        shift: Bool = false,
        windowNumber: Int = 0
    ) -> NSEvent? {
        var flags: NSEvent.ModifierFlags = [.command]
        if shift {
            flags.insert(.shift)
        }
        let charsWithMods = shift ? characters.uppercased() : characters.lowercased()
        return NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: windowNumber,
            context: nil,
            characters: charsWithMods,
            charactersIgnoringModifiers: characters.lowercased(),
            isARepeat: false,
            keyCode: keyCode
        )
    }

    private static func overwriteClipboardWithSynthetic(_ syntheticText: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(syntheticText, forType: .string)
    }

    private static func dispatchThroughProductionShortcutAndResponderPath(
        characters: String,
        keyCode: UInt16,
        shift: Bool = false,
        model: AppModel,
        panel: SlideOverPanel
    ) -> Bool {
        guard let rawEvent = makeSyntheticCommandKeyEvent(
            characters: characters,
            keyCode: keyCode,
            shift: shift,
            windowNumber: panel.windowNumber
        ) else {
            return false
        }
        // Step 1: Pass through production `AppModel.processPanelKeyDownEvent` (local shortcut monitor logic)
        guard let passedEvent = model.processPanelKeyDownEvent(rawEvent, activePanelOverride: panel) else {
            return false
        }
        // Step 2: Dispatch through production `SlideOverPanel.performKeyEquivalent` -> `WKWebView`/`NSTextField` -> `MainMenuBuilder`
        return panel.performKeyEquivalent(with: passedEvent)
    }

    private static func waitForValue(
        expected: String,
        timeoutNanoseconds: UInt64 = 600_000_000,
        readValue: @MainActor () async -> String
    ) async -> String {
        let start = DispatchTime.now().uptimeNanoseconds
        var latest = await readValue()
        while latest != expected && (DispatchTime.now().uptimeNanoseconds - start) < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 20_000_000)
            latest = await readValue()
        }
        return latest
    }

    private static func waitForCondition(
        timeoutNanoseconds: UInt64 = 600_000_000,
        predicate: @MainActor () async -> Bool
    ) async -> Bool {
        let start = DispatchTime.now().uptimeNanoseconds
        while !(await predicate()) && (DispatchTime.now().uptimeNanoseconds - start) < timeoutNanoseconds {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return await predicate()
    }

    public static func runProbe(into outputDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        // MANDATORY STEP 0: Unconditionally overwrite pasteboard BEFORE any read; leave synthetic marker on exit.
        overwriteClipboardWithSynthetic(initialSyntheticSeed)
        defer {
            overwriteClipboardWithSynthetic(finalSyntheticMarker)
        }

        if NSApplication.shared.mainMenu == nil {
            NSApplication.shared.mainMenu = MainMenuBuilder.buildMainMenu()
        }

        // 1. Verify standard nil-target Edit menu items
        let menuOK = StandardEditCommand.allCases.allSatisfy { cmd in
            guard let item = MainMenuBuilder.editMenuItem(for: cmd, in: NSApplication.shared.mainMenu) else {
                return false
            }
            let expectedMask: NSEvent.ModifierFlags = cmd.requiresShift ? [.command, .shift] : [.command]
            return item.target == nil
                && item.keyEquivalent == cmd.keyEquivalent
                && item.keyEquivalentModifierMask == expectedMask
        }

        // 2. Isolated temporary store + nonPersistent WKWebsiteDataStore
        let tempDir = fm.temporaryDirectory.appendingPathComponent("VeypaneEditProbe-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempDir) }

        let store = VeypaneStore(directoryURL: tempDir)
        var initial = WorkspaceState(pads: [])
        initial.settings.hasCompletedOnboarding = true
        try store.save(initial)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.forceOffscreenPopupWindows = true

        // 3. Verify responder spy + local/extension shortcut bypass for all 6 editing shortcuts
        let spyPanel = SlideOverPanel(contentRect: NSRect(x: -15000, y: -15000, width: 640, height: 480))
        spyPanel.simulatedKeyWindowOverride = true
        spyPanel.alphaValue = 0.01
        spyPanel.ignoresMouseEvents = true
        let spyContainer = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let spyView = IsolatedEditingResponderSpyView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        spyContainer.addSubview(spyView)
        spyPanel.contentView = spyContainer
        _ = spyPanel.makeFirstResponder(spyView)

        let keySpecs: [(String, UInt16, Bool)] = [
            ("c", 0x08, false),
            ("v", 0x09, false),
            ("x", 0x07, false),
            ("a", 0x00, false),
            ("z", 0x06, false),
            ("z", 0x06, true)
        ]
        var localBypassOK = true
        var extBypassOK = true
        for (ch, code, sh) in keySpecs {
            if let ev = makeSyntheticCommandKeyEvent(characters: ch, keyCode: code, shift: sh, windowNumber: spyPanel.windowNumber) {
                if model.processPanelKeyDownEvent(ev, activePanelOverride: spyPanel) == nil {
                    localBypassOK = false
                }
                if model.extensionManager.handleKeyEvent(ev) {
                    extBypassOK = false
                }
                _ = spyPanel.performKeyEquivalent(with: ev)
            }
        }
        let expectedSpyOrder = ["copy:", "paste:", "cut:", "selectAll:", "undo:", "redo:"]
        let spyMatched = (spyView.receivedSelectors == expectedSpyOrder)
        spyPanel.orderOut(nil)

        // 4. Mount 2 pads + native transient URL field inside production SlideOverPanel
        let pad1 = model.addPad(url: URL(string: "about:blank")!, title: "FixtureOne", select: true)
        let pad2 = model.addPad(url: URL(string: "about:blank")!, title: "FixtureTwo", select: false)
        let wc1 = model.webController(for: pad1)
        let wc2 = model.webController(for: pad2)

        let html = """
        <!doctype html>
        <html><body>
          <input id="inp" type="text" value="synthetic-input-seed">
          <textarea id="ta">synthetic-textarea-seed</textarea>
          <div id="ce" contenteditable="true">synthetic-editable-seed</div>
          <p id="doc">synthetic-document-selection-text</p>
        </body></html>
        """
        wc1.webView.loadHTMLString(html, baseURL: nil)
        wc2.webView.loadHTMLString(html, baseURL: nil)
        try await Task.sleep(nanoseconds: 400_000_000)

        let hostPanel = SlideOverPanel(contentRect: NSRect(x: -15000, y: -15000, width: 820, height: 600))
        hostPanel.simulatedKeyWindowOverride = true
        let fallbackDelegate = ProbeEditFallbackDelegate()
        fallbackDelegate.activePanel = hostPanel
        NSApplication.shared.delegate = fallbackDelegate
        defer {
            NSApplication.shared.delegate = nil
            hostPanel.orderOut(nil)
        }
        hostPanel.alphaValue = 0.01
        hostPanel.ignoresMouseEvents = true
        let rootContainer = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 600))
        let deck = PadDeckContainerNSView(frame: NSRect(x: 0, y: 0, width: 820, height: 540))
        let nativeURLField = NSTextField(frame: NSRect(x: 20, y: 550, width: 420, height: 28))
        nativeURLField.stringValue = "https://synthetic.local/address-seed"
        nativeURLField.isHidden = true // Transient URL editor is hidden until Cmd+L / new-pad reveal
        rootContainer.addSubview(deck)
        rootContainer.addSubview(nativeURLField)
        deck.syncDeck(entries: model.deckMountedWebViews(), selectedPadID: model.selectedPad?.id)
        hostPanel.contentView = rootContainer
        hostPanel.orderBack(nil)

        // Focus restore on show & pad switch
        _ = hostPanel.makeFirstResponder(nil)
        let restoredPad1 = model.restoreWebViewFocusIfAppropriate(in: hostPanel)
            && ((hostPanel.firstResponder as? NSView).map { $0 === wc1.webView || $0.isDescendant(of: wc1.webView) } ?? false)
        model.selectPad(pad2.id)
        deck.syncDeck(entries: model.deckMountedWebViews(), selectedPadID: model.selectedPad?.id)
        let restoredPad2 = model.restoreWebViewFocusIfAppropriate(in: hostPanel)
            && ((hostPanel.firstResponder as? NSView).map { $0 === wc2.webView || $0.isDescendant(of: wc2.webView) } ?? false)
        let focusShowSwitchOK = restoredPad1 && restoredPad2

        // 5. Run ALL WKWebView surfaces FIRST while `hostPanel.undoManager` is completely clean (`canUndo == false`),
        // proving `SlideOverPanel` validates and dispatches `undo:`/`redo:` against `firstResponder?.undoManager` (`_WKWebViewUndoManager`).
        _ = hostPanel.makeFirstResponder(wc2.webView)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: hostPanel)
        try await Task.sleep(nanoseconds: 120_000_000)

        let windowUndoCleanBeforeWeb = !(hostPanel.undoManager?.canUndo ?? false)

        func eval(_ js: String) async -> String {
            (try? await wc2.evaluateLimitedScript(js)) ?? ""
        }

        // Helper for testing exact single-operation native UndoManager semantics on a web surface:
        // Cmd+A -> Cmd+C -> Cmd+X -> Cmd+Z (undo Cut -> seed) -> Shift+Cmd+Z (redo Cut -> "")
        // -> Cmd+V (paste -> pasted) -> Cmd+Z (undo Paste -> "") -> Shift+Cmd+Z (redo Paste -> pasted).
        // Note: In `NSApplication.run()`, `NSUndoManager` (`groupsByEvent == true`) coalesces back-to-back edits
        // (`Cut` + `Paste`) into one top-level group when no `NSEvent` loop boundary closes the group between them;
        // testing `Cut -> Undo -> Redo` (`Redo` synchronously closes `[Cut]` on the undo stack) followed by
        // `Paste -> Undo -> Redo` verifies both single-step native Undo/Redo operations with exact string equality.
        func runWebEditableSurfaceE2E(
            surfaceName: String,
            seed: String,
            pasted: String,
            focusScript: String,
            selectionMatchesSeedScript: String,
            readValueScript: String,
            trimWhitespace: Bool = false
        ) async -> EditingSurfaceE2EResult {
            func readCurrent() async -> String {
                let raw = await eval(readValueScript)
                return trimWhitespace ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
            }

            _ = await eval(focusScript)
            overwriteClipboardWithSynthetic("VEYPANE_PRE_\(surfaceName.uppercased())_COPY")
            _ = dispatchThroughProductionShortcutAndResponderPath(characters: "a", keyCode: 0x00, model: model, panel: hostPanel)
            let selAllOK = await waitForCondition {
                (await eval(selectionMatchesSeedScript)) == "true"
            }

            _ = dispatchThroughProductionShortcutAndResponderPath(characters: "c", keyCode: 0x08, model: model, panel: hostPanel)
            let copyOK = await waitForCondition {
                let clip = NSPasteboard.general.string(forType: .string) ?? ""
                return (trimWhitespace ? clip.trimmingCharacters(in: .whitespacesAndNewlines) : clip) == seed
            }

            overwriteClipboardWithSynthetic("VEYPANE_PRE_\(surfaceName.uppercased())_CUT")
            _ = dispatchThroughProductionShortcutAndResponderPath(characters: "x", keyCode: 0x07, model: model, panel: hostPanel)
            let afterCut = await waitForValue(expected: "", readValue: readCurrent)
            let cutClip = NSPasteboard.general.string(forType: .string) ?? ""
            let cutOK = afterCut.isEmpty
                && ((trimWhitespace ? cutClip.trimmingCharacters(in: .whitespacesAndNewlines) : cutClip) == seed)

            // Wait briefly for WebContent's async `registerEditCommandForUndo` IPC to register on `WKWebView.undoManager`
            _ = await waitForCondition {
                (hostPanel.firstResponder?.undoManager?.canUndo ?? false)
            }
            let responderClass = hostPanel.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
            let responderCanUndo = hostPanel.firstResponder?.undoManager?.canUndo ?? false

            _ = dispatchThroughProductionShortcutAndResponderPath(characters: "z", keyCode: 0x06, shift: false, model: model, panel: hostPanel)
            let afterUndoCut = await waitForValue(expected: seed, readValue: readCurrent)
            let undoCutOK = (afterUndoCut == seed)

            _ = dispatchThroughProductionShortcutAndResponderPath(characters: "z", keyCode: 0x06, shift: true, model: model, panel: hostPanel)
            let afterRedoCut = await waitForValue(expected: "", readValue: readCurrent)
            let redoCutOK = afterRedoCut.isEmpty

            overwriteClipboardWithSynthetic(pasted)
            _ = dispatchThroughProductionShortcutAndResponderPath(characters: "v", keyCode: 0x09, model: model, panel: hostPanel)
            let afterPaste = await waitForValue(expected: pasted, readValue: readCurrent)
            let pasteOK = (afterPaste == pasted)

            _ = await waitForCondition {
                (hostPanel.firstResponder?.undoManager?.canUndo ?? false)
            }

            _ = dispatchThroughProductionShortcutAndResponderPath(characters: "z", keyCode: 0x06, shift: false, model: model, panel: hostPanel)
            let afterUndoPaste = await waitForValue(expected: "", readValue: readCurrent)
            let undoPasteOK = afterUndoPaste.isEmpty

            _ = dispatchThroughProductionShortcutAndResponderPath(characters: "z", keyCode: 0x06, shift: true, model: model, panel: hostPanel)
            let afterRedoPaste = await waitForValue(expected: pasted, readValue: readCurrent)
            let redoPasteOK = (afterRedoPaste == pasted)

            return EditingSurfaceE2EResult(
                surface: surfaceName,
                firstResponderClass: responderClass,
                responderCanUndoBeforeUndo: responderCanUndo,
                seedValue: seed,
                valueAfterCut: afterCut,
                valueAfterUndoCut: afterUndoCut,
                valueAfterRedoCut: afterRedoCut,
                valueAfterPaste: afterPaste,
                valueAfterUndoPaste: afterUndoPaste,
                valueAfterRedoPaste: afterRedoPaste,
                copyVerified: copyOK,
                cutVerified: cutOK,
                pasteVerified: pasteOK,
                selectAllVerified: selAllOK,
                undoCutVerified: undoCutOK,
                redoCutVerified: redoCutOK,
                undoPasteVerified: undoPasteOK,
                redoPasteVerified: redoPasteOK,
                undoVerified: undoCutOK && undoPasteOK,
                redoVerified: redoCutOK && redoPasteOK
            )
        }

        // 5a. Web `<input id="inp">`
        let webInputResult = await runWebEditableSurfaceE2E(
            surfaceName: "webInput",
            seed: "synthetic-input-seed",
            pasted: "synthetic-input-pasted",
            focusScript: "(function(){ var i=document.getElementById('inp'); i.focus(); i.setSelectionRange(0,0); return ''; })()",
            selectionMatchesSeedScript: "(function(){ var i=document.getElementById('inp'); return String(i.selectionEnd - i.selectionStart === i.value.length && i.value.length > 0); })()",
            readValueScript: "document.getElementById('inp').value"
        )

        // 5b. Web `<textarea id="ta">`
        let webTextareaResult = await runWebEditableSurfaceE2E(
            surfaceName: "webTextarea",
            seed: "synthetic-textarea-seed",
            pasted: "synthetic-textarea-pasted",
            focusScript: "(function(){ var t=document.getElementById('ta'); t.focus(); t.setSelectionRange(0,0); return ''; })()",
            selectionMatchesSeedScript: "(function(){ var t=document.getElementById('ta'); return String(t.selectionEnd - t.selectionStart === t.value.length && t.value.length > 0); })()",
            readValueScript: "document.getElementById('ta').value"
        )

        // 5c. Web `<div id="ce" contenteditable="true">`
        let webContentEditableResult = await runWebEditableSurfaceE2E(
            surfaceName: "webContentEditable",
            seed: "synthetic-editable-seed",
            pasted: "synthetic-editable-pasted",
            focusScript: """
            (function() {
                var c = document.getElementById('ce');
                c.focus();
                var r = document.createRange();
                r.setStart(c.firstChild || c, 0);
                r.collapse(true);
                var sel = window.getSelection();
                sel.removeAllRanges();
                sel.addRange(r);
                return '';
            })()
            """,
            selectionMatchesSeedScript: "String(window.getSelection().toString().trim() === 'synthetic-editable-seed')",
            readValueScript: "document.getElementById('ce').textContent || ''",
            trimWhitespace: true
        )

        // 5d. Document body text selection (`<p id="doc">`): select paragraph range, send Cmd+C, plus Cmd+A
        _ = await eval("""
        (function() {
            if (document.activeElement) document.activeElement.blur();
            var p = document.getElementById('doc');
            var range = document.createRange();
            range.selectNodeContents(p);
            var sel = window.getSelection();
            sel.removeAllRanges();
            sel.addRange(range);
            return sel.toString();
        })()
        """)
        overwriteClipboardWithSynthetic("VEYPANE_PRE_DOC_COPY")
        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "c", keyCode: 0x08, model: model, panel: hostPanel)
        let docCopyOK = await waitForCondition {
            (NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) == "synthetic-document-selection-text")
        }

        _ = await eval("(function(){ window.getSelection().removeAllRanges(); return ''; })()")
        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "a", keyCode: 0x00, model: model, panel: hostPanel)
        let docSelAllOK = await waitForCondition {
            (await eval("window.getSelection().toString()")).contains("synthetic-document-selection-text")
        }
        let docSelectionOK = docCopyOK && docSelAllOK

        // 6. Native / transient URL field E2E (`Cmd+L` reveal -> preserve focus -> Cmd+A/C/X/Z/Shift+Z/V/Z/Shift+Z -> Esc cancel -> restore web focus)
        let nativeSeed = "https://synthetic.local/address-seed"
        let nativePasted = "https://synthetic.local/pasted-url"
        model.addressBarState.revealForCurrentPad(padID: pad2.id, currentURL: pad2.url)
        nativeURLField.isHidden = false
        _ = hostPanel.makeFirstResponder(nativeURLField)
        if let editor = nativeURLField.currentEditor() {
            editor.selectedRange = NSRange(location: 0, length: 0)
        }
        let nativeFocusPreserved = !model.restoreWebViewFocusIfAppropriate(in: hostPanel)
            && AppModel.isNativeTextResponder(hostPanel.firstResponder)

        func currentNativeEditorText() -> String {
            nativeURLField.currentEditor()?.string ?? nativeURLField.stringValue
        }

        overwriteClipboardWithSynthetic("VEYPANE_PRE_URL_COPY")
        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "a", keyCode: 0x00, model: model, panel: hostPanel)
        let nativeSelAllOK = (nativeURLField.currentEditor()?.selectedRange.length == nativeSeed.utf16.count)

        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "c", keyCode: 0x08, model: model, panel: hostPanel)
        let nativeCopyOK = (NSPasteboard.general.string(forType: .string) == nativeSeed)

        overwriteClipboardWithSynthetic("VEYPANE_PRE_URL_CUT")
        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "x", keyCode: 0x07, model: model, panel: hostPanel)
        let nativeAfterCut = currentNativeEditorText()
        let nativeCutOK = nativeAfterCut.isEmpty
            && (NSPasteboard.general.string(forType: .string) == nativeSeed)

        let nativeResponderClass = hostPanel.firstResponder.map { NSStringFromClass(type(of: $0)) } ?? "nil"
        let nativeCanUndo = (hostPanel.firstResponder?.undoManager ?? hostPanel.undoManager)?.canUndo ?? false

        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "z", keyCode: 0x06, shift: false, model: model, panel: hostPanel)
        let nativeAfterUndoCut = currentNativeEditorText()
        let nativeUndoCutOK = (nativeAfterUndoCut == nativeSeed)

        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "z", keyCode: 0x06, shift: true, model: model, panel: hostPanel)
        let nativeAfterRedoCut = currentNativeEditorText()
        let nativeRedoCutOK = nativeAfterRedoCut.isEmpty

        overwriteClipboardWithSynthetic(nativePasted)
        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "v", keyCode: 0x09, model: model, panel: hostPanel)
        let nativeAfterPaste = currentNativeEditorText()
        let nativePasteOK = (nativeAfterPaste == nativePasted)

        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "z", keyCode: 0x06, shift: false, model: model, panel: hostPanel)
        let nativeAfterUndoPaste = currentNativeEditorText()
        let nativeUndoPasteOK = nativeAfterUndoPaste.isEmpty

        _ = dispatchThroughProductionShortcutAndResponderPath(characters: "z", keyCode: 0x06, shift: true, model: model, panel: hostPanel)
        let nativeAfterRedoPaste = currentNativeEditorText()
        let nativeRedoPasteOK = (nativeAfterRedoPaste == nativePasted)

        let nativeResult = EditingSurfaceE2EResult(
            surface: "nativeTransientAddressField",
            firstResponderClass: nativeResponderClass,
            responderCanUndoBeforeUndo: nativeCanUndo,
            seedValue: nativeSeed,
            valueAfterCut: nativeAfterCut,
            valueAfterUndoCut: nativeAfterUndoCut,
            valueAfterRedoCut: nativeAfterRedoCut,
            valueAfterPaste: nativeAfterPaste,
            valueAfterUndoPaste: nativeAfterUndoPaste,
            valueAfterRedoPaste: nativeAfterRedoPaste,
            copyVerified: nativeCopyOK,
            cutVerified: nativeCutOK,
            pasteVerified: nativePasteOK,
            selectAllVerified: nativeSelAllOK,
            undoCutVerified: nativeUndoCutOK,
            redoCutVerified: nativeRedoCutOK,
            undoPasteVerified: nativeUndoPasteOK,
            redoPasteVerified: nativeRedoPasteOK,
            undoVerified: nativeUndoCutOK && nativeUndoPasteOK,
            redoVerified: nativeRedoCutOK && nativeRedoPasteOK
        )

        // Cancel Cmd+L -> focus restores back to Pad 2's WKWebView
        model.addressBarState.cancel()
        nativeURLField.isHidden = true
        _ = hostPanel.makeFirstResponder(nil)
        let restoredAfterCancel = model.restoreWebViewFocusIfAppropriate(in: hostPanel)
            && ((hostPanel.firstResponder as? NSView).map { $0 === wc2.webView || $0.isDescendant(of: wc2.webView) } ?? false)

        wc1.webView.removeFromSuperview()
        wc2.webView.removeFromSuperview()

        // Leave final synthetic marker right before generating report (and reinforced in `defer`)
        overwriteClipboardWithSynthetic(finalSyntheticMarker)

        let allPassed = menuOK
            && localBypassOK
            && extBypassOK
            && spyMatched
            && focusShowSwitchOK
            && windowUndoCleanBeforeWeb
            && nativeFocusPreserved
            && restoredAfterCancel
            && nativeResult.allPassed
            && webInputResult.allPassed
            && webTextareaResult.allPassed
            && webContentEditableResult.allPassed
            && docSelectionOK

        let report = EditingShortcutProbeReport(
            generatedAt: Date(),
            isolatedTemporaryStore: true,
            nonPersistentWebDataStore: true,
            previousClipboardReadOrBackedUp: false,
            initialClipboardUnconditionallyOverwrittenWithSyntheticSeed: true,
            finalSyntheticMarkerWritten: finalSyntheticMarker,
            keyEventInjectionLevel: "NSEvent.keyEvent -> AppModel.processPanelKeyDownEvent -> SlideOverPanel.performKeyEquivalent -> WKWebView/NSTextField -> NSApp.mainMenu (MainMenuBuilder nil-target Edit items)",
            mainMenuNilTargetSelectorsVerified: menuOK,
            localShortcutMonitorBypassVerified: localBypassOK,
            extensionShortcutBypassVerified: extBypassOK,
            responderSpyRoutedSelectors: spyView.receivedSelectors,
            responderSpyAllSixMatched: spyMatched,
            focusRestoredOnShowAndPadSwitch: focusShowSwitchOK,
            windowUndoEmptyBeforeWebTests: windowUndoCleanBeforeWeb,
            nativeFieldFocusPreservedDuringAddressEdit: nativeFocusPreserved,
            focusRestoredAfterAddressCancel: restoredAfterCancel,
            nativeAddressFieldE2E: nativeResult,
            webInputE2E: webInputResult,
            webTextareaE2E: webTextareaResult,
            webContentEditableE2E: webContentEditableResult,
            webDocumentSelectionCopyAndSelectAllVerified: docSelectionOK,
            passedAllChecks: allPassed
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let outFile = outputDir.appendingPathComponent("editing-shortcut-probe.json")
        try data.write(to: outFile, options: .atomic)
        print(outFile.path)
        if !allPassed {
            throw NSError(
                domain: "VeypaneEditingShortcutProbe",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "One or more editing/clipboard E2E checks failed; inspect editing-shortcut-probe.json"]
            )
        }
    }
}
