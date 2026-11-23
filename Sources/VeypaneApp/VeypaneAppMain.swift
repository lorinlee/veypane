import AppKit
import Darwin
import SwiftUI
import VeypaneCore

@MainActor
public enum SingleInstanceGuard {
    private static var lockFileDescriptor: Int32 = -1

    /// Prevents legacy (`SlideCraft.app` / `Sidelark.app` / backups) and current (`Veypane.app`) bundles sharing
    /// `com.slidecraft.app` from running simultaneously.
    public static func ensureSingleRunningInstance(lockDirectoryURL: URL) -> Bool {
        let selfPID = ProcessInfo.processInfo.processIdentifier

        // 1. Check LaunchServices / NSRunningApplication by shared bundle identifier
        let matches = NSRunningApplication.runningApplications(
            withBundleIdentifier: AppBrandIdentity.bundleIdentifier
        ).filter { app in
            app.processIdentifier != selfPID && !app.isTerminated
        }

        if let existing = matches.first {
            let existingPath = existing.bundleURL?.path ?? existing.executableURL?.path ?? "unknown path"
            let warning = "\(AppBrandIdentity.productName): another instance (PID \(existing.processIdentifier)) at '\(existingPath)' is already running; forwarding show command and exiting to prevent duplicate process.\n"
            FileHandle.standardError.write(Data(warning.utf8))
            NSLog("%@", warning)
            try? DistributedNotificationIPCSender().send(.showPanel)
            return false
        }

        // 2. Advisory non-blocking POSIX flock on Application Support/SlideCraft/instance.lock
        try? FileManager.default.createDirectory(at: lockDirectoryURL, withIntermediateDirectories: true)
        let lockPath = lockDirectoryURL.appendingPathComponent("instance.lock", isDirectory: false).path
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        if fd >= 0 {
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                Darwin.close(fd)
                let warning = "\(AppBrandIdentity.productName): instance lock at '\(lockPath)' is held by another running process; forwarding show command and exiting.\n"
                FileHandle.standardError.write(Data(warning.utf8))
                NSLog("%@", warning)
                try? DistributedNotificationIPCSender().send(.showPanel)
                return false
            }
            lockFileDescriptor = fd
        }

        return true
    }
}

@MainActor
public enum StatusMenuBuilder {
    public static func buildMenu(
        model: AppModel,
        target: AnyObject?,
        toggleAction: Selector? = nil,
        selectPadAction: Selector? = nil,
        newPadAction: Selector? = nil,
        extensionsAction: Selector? = nil,
        settingsAction: Selector? = nil,
        welcomeAction: Selector? = nil,
        quitAction: Selector? = nil
    ) -> NSMenu {
        let menu = NSMenu(title: AppBrandIdentity.productName)
        menu.autoenablesItems = false

        let toggleBase = model.isPanelVisible ? L10n.string("menu.hide_panel") : L10n.string("menu.show_panel")
        let toggleItem = NSMenuItem(
            title: "\(toggleBase) (\(model.state.settings.toggleHotkey.displayString))",
            action: toggleAction,
            keyEquivalent: ""
        )
        toggleItem.target = target
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        for pad in model.state.pads {
            let badgeSuffix = pad.formattedBadge.map { " (\($0))" } ?? ""
            let item = NSMenuItem(
                title: "\(pad.title)\(badgeSuffix)",
                action: selectPadAction,
                keyEquivalent: ""
            )
            item.target = target
            item.representedObject = pad.id
            item.state = (pad.id == model.state.selectedPadID) ? .on : .off
            menu.addItem(item)
        }

        let newPadItem = NSMenuItem(
            title: L10n.string("menu.new_pad"),
            action: newPadAction,
            keyEquivalent: "n"
        )
        newPadItem.target = target
        menu.addItem(newPadItem)

        menu.addItem(.separator())

        let extensionsItem = NSMenuItem(
            title: L10n.string("menu.extensions"),
            action: extensionsAction,
            keyEquivalent: ""
        )
        extensionsItem.target = target
        menu.addItem(extensionsItem)

        let settingsItem = NSMenuItem(
            title: L10n.string("menu.settings"),
            action: settingsAction,
            keyEquivalent: ","
        )
        settingsItem.target = target
        menu.addItem(settingsItem)

        let welcomeItem = NSMenuItem(
            title: L10n.string("menu.welcome_guide"),
            action: welcomeAction,
            keyEquivalent: ""
        )
        welcomeItem.target = target
        menu.addItem(welcomeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: L10n.string("menu.quit"),
            action: quitAction,
            keyEquivalent: "q"
        )
        quitItem.target = target
        menu.addItem(quitItem)

        return menu
    }
}

@MainActor
public enum MainMenuBuilder {
    /// Builds the standard macOS main menu bar (Application + nil-targeted Edit menu) required so `LSUIElement`
    /// windows (`SlideOverPanel`, Settings, Welcome, popovers, `WKWebView`, and `NSTextField` field editors)
    /// route `⌘Z`, `⇧⌘Z`, `⌘X`, `⌘C`, `⌘V`, and `⌘A` natively through the active `firstResponder` chain.
    public static func buildMainMenu(
        appTarget: AnyObject? = nil,
        settingsAction: Selector? = nil,
        quitAction: Selector? = nil
    ) -> NSMenu {
        let mainMenu = NSMenu(title: "MainMenu")

        // 1. Application Menu
        let appMenuItem = NSMenuItem(title: AppBrandIdentity.productName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: AppBrandIdentity.productName)
        if let settingsAction {
            let prefsItem = NSMenuItem(
                title: L10n.string("menu.settings"),
                action: settingsAction,
                keyEquivalent: ","
            )
            prefsItem.keyEquivalentModifierMask = [.command]
            prefsItem.target = appTarget
            appMenu.addItem(prefsItem)
            appMenu.addItem(.separator())
        }
        let quitItem = NSMenuItem(
            title: L10n.string("menu.quit"),
            action: quitAction ?? #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = quitAction != nil ? appTarget : nil
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // 2. Standard Nil-Target Edit Menu (dispatches to current window's firstResponder chain)
        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.autoenablesItems = true

        let undoItem = NSMenuItem(title: "Undo", action: #selector(VeypaneAppDelegate.undo(_:)), keyEquivalent: "z")
        undoItem.keyEquivalentModifierMask = [.command]
        undoItem.target = nil
        editMenu.addItem(undoItem)

        let redoItem = NSMenuItem(title: "Redo", action: #selector(VeypaneAppDelegate.redo(_:)), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        redoItem.target = nil
        editMenu.addItem(redoItem)

        editMenu.addItem(.separator())

        let cutItem = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        cutItem.keyEquivalentModifierMask = [.command]
        cutItem.target = nil
        editMenu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        copyItem.keyEquivalentModifierMask = [.command]
        copyItem.target = nil
        editMenu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        pasteItem.keyEquivalentModifierMask = [.command]
        pasteItem.target = nil
        editMenu.addItem(pasteItem)

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        selectAllItem.keyEquivalentModifierMask = [.command]
        selectAllItem.target = nil
        editMenu.addItem(selectAllItem)

        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        return mainMenu
    }

    public static func editMenuItem(for command: StandardEditCommand, in mainMenu: NSMenu?) -> NSMenuItem? {
        guard let mainMenu else { return nil }
        let targetSel = Selector((command.selectorName))
        for topItem in mainMenu.items {
            guard let sub = topItem.submenu else { continue }
            for item in sub.items where item.action == targetSel && item.target == nil {
                return item
            }
        }
        return nil
    }
}

@MainActor
public final class VeypaneAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private let model = AppModel.shared
    private var statusItem: NSStatusItem?

    /// When Veypane's `.nonactivatingPanel` is open over another active app (`NSApp.isActive == false`),
    /// `NSApp.keyWindow` can be `nil` when WebKit's async `doneWithKeyEvent` invokes `NSApp.mainMenu.performKeyEquivalent`.
    /// AppKit's nil-target responder chain then reaches `NSApp.delegate`; forwarding strictly to the visible panel's
    /// real `firstResponder` chain keeps native `⌘C`/`⌘V`/`⌘X`/`⌘A`/`⌘Z`/`⇧⌘Z` working in both `WKWebView` and `NSTextField`.
    private var fallbackActivePanel: SlideOverPanel? {
        guard NSApp.keyWindow == nil,
              let panel = model.panel,
              panel.isVisible else {
            return nil
        }
        return panel
    }

    public func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action,
           let panel = fallbackActivePanel,
           Self.standardEditCommand(for: action) != nil {
            return panel.canDispatchSelectorInResponderChain(action, menuItem: menuItem)
        }
        return responds(to: menuItem.action)
    }

    private static func standardEditCommand(for selector: Selector) -> StandardEditCommand? {
        switch NSStringFromSelector(selector) {
        case "undo:": .undo
        case "redo:": .redo
        case "cut:": .cut
        case "copy:": .copy
        case "paste:": .paste
        case "selectAll:": .selectAll
        default: nil
        }
    }

    @objc public func undo(_ sender: Any?) {
        _ = fallbackActivePanel?.dispatchStandardEditCommandToResponderChain(.undo)
    }

    @objc public func redo(_ sender: Any?) {
        _ = fallbackActivePanel?.dispatchStandardEditCommandToResponderChain(.redo)
    }

    @objc public func cut(_ sender: Any?) {
        _ = fallbackActivePanel?.dispatchStandardEditCommandToResponderChain(.cut)
    }

    @objc public func copy(_ sender: Any?) {
        _ = fallbackActivePanel?.dispatchStandardEditCommandToResponderChain(.copy)
    }

    @objc public func paste(_ sender: Any?) {
        _ = fallbackActivePanel?.dispatchStandardEditCommandToResponderChain(.paste)
    }

    @objc public func selectAll(_ sender: Any?) {
        _ = fallbackActivePanel?.dispatchStandardEditCommandToResponderChain(.selectAll)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = MainMenuBuilder.buildMainMenu(
            appTarget: self,
            settingsAction: #selector(openSettingsFromMenu),
            quitAction: #selector(quitFromMenu)
        )
        if let iconURL = L10n.iconFileURL, let customIcon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = customIcon
        }
        model.startRuntimeServices {
            PanelRootView.makeHostingView(model: self.model)
        }
        updateMenuBarStatusItem()
        NSLog("%@: launch finished", AppBrandIdentity.productName)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMenuBarVisibilityChange),
            name: .veypaneMenuBarVisibilityChanged,
            object: nil
        )
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        model.showPanel(activateFocus: true, openedFromEdge: false)
        return true
    }

    public func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let action = VeypaneURLCommand.parse(url) {
                model.handleAutomationAction(action)
            }
        }
    }

    @objc private func handleMenuBarVisibilityChange() {
        updateMenuBarStatusItem()
    }

    private func updateMenuBarStatusItem() {
        if model.state.settings.appearance.showMenuBarIcon {
            if statusItem == nil {
                let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
                item.isVisible = true
                if let button = item.button {
                    button.image = NSImage(
                        systemSymbolName: "sidebar.right",
                        accessibilityDescription: AppBrandIdentity.productName
                    )
                    button.image?.isTemplate = true
                    button.target = self
                    button.action = #selector(handleStatusButtonClick(_:))
                    button.sendAction(on: [.leftMouseUp, .rightMouseUp])
                }
                statusItem = item
            }
            model.hasStatusItem = true
            model.isStatusItemVisible = statusItem?.isVisible ?? true
        } else {
            if let existing = statusItem {
                NSStatusBar.system.removeStatusItem(existing)
                statusItem = nil
            }
            model.hasStatusItem = false
            model.isStatusItemVisible = false
        }
        model.writeLiveUIState()
    }

    @objc private func handleStatusButtonClick(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondaryClick = (event?.type == .rightMouseUp)
            || (event?.modifierFlags.contains(.control) == true)
            || (event?.modifierFlags.contains(.option) == true)

        if isSecondaryClick, let item = statusItem {
            let menu = StatusMenuBuilder.buildMenu(
                model: model,
                target: self,
                toggleAction: #selector(togglePanelFromMenu),
                selectPadAction: #selector(selectPadFromMenu(_:)),
                newPadAction: #selector(newPadFromMenu),
                extensionsAction: #selector(openExtensionsFromMenu),
                settingsAction: #selector(openSettingsFromMenu),
                welcomeAction: #selector(openWelcomeFromMenu),
                quitAction: #selector(quitFromMenu)
            )
            item.menu = menu
            sender.performClick(nil)
            item.menu = nil
        } else {
            model.togglePanel(activateFocus: true)
        }
    }

    @objc private func togglePanelFromMenu() {
        model.togglePanel(activateFocus: true)
    }

    @objc private func selectPadFromMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        model.selectPad(id)
        model.showPanel(activateFocus: true, openedFromEdge: false)
    }

    @objc private func newPadFromMenu() {
        model.presentNewPadFlow()
    }

    @objc private func openExtensionsFromMenu() {
        model.openSettingsWindow(pane: .extensions)
    }

    @objc private func openSettingsFromMenu() {
        model.openSettingsWindow()
    }

    @objc private func openWelcomeFromMenu() {
        model.openWelcomeWindow()
    }

    @objc private func quitFromMenu() {
        NSApplication.shared.terminate(nil)
    }
}

@main
enum VeypaneAppBootstrap {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--banner-layout-probe"), idx + 1 < args.count {
            BannerLayoutProbeRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--render-ui-snapshots"), idx + 1 < args.count {
            UISnapshotRenderer.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--interaction-probe"), idx + 1 < args.count {
            InteractionProbeRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--compatibility-probe") ?? args.firstIndex(of: "--google-compat-probe"),
           idx + 1 < args.count {
            CompatibilityProbeRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--panel-animation-probe"), idx + 1 < args.count {
            PanelAnimationProbeRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--editing-shortcut-probe"), idx + 1 < args.count {
            EditingShortcutProbeRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--popup-acceptance-probe"), idx + 1 < args.count {
            PopupAcceptanceProbeRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--outside-click-probe"), idx + 1 < args.count {
            OutsideClickProbeRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--native-os-outside-click-probe"), idx + 1 < args.count {
            NativeOSOutsideClickAcceptanceRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--native-os-window-resize-probe"), idx + 1 < args.count {
            NativeOSWindowResizeAcceptanceRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--native-os-sidebar-drag-probe"), idx + 1 < args.count {
            NativeOSSidebarDragAcceptanceRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }
        if let idx = args.firstIndex(of: "--panel-chrome-snapshot"), idx + 1 < args.count {
            PanelChromeSnapshotRunner.runAndExit(outputDirectoryPath: args[idx + 1])
            return
        }

        let defaultStore = VeypaneStore()
        guard SingleInstanceGuard.ensureSingleRunningInstance(lockDirectoryURL: defaultStore.directoryURL) else {
            Darwin.exit(0)
        }

        let app = NSApplication.shared
        let delegate = VeypaneAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
