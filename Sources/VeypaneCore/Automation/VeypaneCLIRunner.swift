import Foundation

public struct CLIOutput: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol IPCSender: Sendable {
    func send(_ action: VeypaneAutomationAction) throws
}

public struct DistributedNotificationIPCSender: IPCSender {
    public init() {}

    public func send(_ action: VeypaneAutomationAction) throws {
        let payload = try VeypaneIPC.encode(action)
        DistributedNotificationCenter.default().postNotificationName(
            VeypaneIPC.distributedNotificationName,
            object: nil,
            userInfo: [VeypaneIPC.payloadUserInfoKey: payload],
            deliverImmediately: true
        )
    }
}

public enum VeypaneCLIRunner {
    public static func makeUsageText(cliName: String = AppBrandIdentity.primaryCLIName) -> String {
        """
        \(cliName) — \(AppBrandIdentity.productName) command-line controller

        Usage:
          \(cliName) [--store <dir>] [--json] list
          \(cliName) [--store <dir>] add <url> [--title <title>] [--profile <name>]
          \(cliName) [--store <dir>] remove <pad-id-or-title>
          \(cliName) [--store <dir>] open <url> [--pad <pad-id-or-title>] [--new]
          \(cliName) [--store <dir>] select <pad-id-or-title>
          \(cliName) toggle | show | hide
          \(cliName) [--store <dir>] ui state | diagnostics
          \(cliName) ui open-settings [pane]
          \(cliName) ui show-welcome
          \(cliName) [--store <dir>] export <file.json>
          \(cliName) [--store <dir>] import <file.json> [--merge]
          \(cliName) [--store <dir>] [--json] extensions list | add <path> | refresh | remove <id> | enable <id> | disable <id> | command <id> <commandId>
          \(cliName) [--store <dir>] url <action>
        """
    }

    public static let usageText = makeUsageText()

    public static func run(
        arguments: [String],
        defaultStoreDirectory: URL? = nil,
        ipcSender: any IPCSender = DistributedNotificationIPCSender()
    ) -> CLIOutput {
        let cliName = AppBrandIdentity.resolvedCLIInvocationName(from: arguments)
        let dynamicUsage = makeUsageText(cliName: cliName)
        let args = Array(arguments.dropFirst()) // drop executable path
        var storeDir = defaultStoreDirectory
        var outputJSON = false

        // Extract global flags (`--store <dir>`, `--json`, `-h`, `--help`)
        var remaining: [String] = []
        var i = 0
        while i < args.count {
            let token = args[i]
            switch token {
            case "-h", "--help", "help":
                return CLIOutput(exitCode: 0, stdout: dynamicUsage + "\n")
            case "--json":
                outputJSON = true
                i += 1
            case "--store":
                guard i + 1 < args.count else {
                    return CLIOutput(exitCode: 2, stderr: "Error: --store requires a directory path.\n")
                }
                storeDir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
                i += 2
            default:
                remaining.append(token)
                i += 1
            }
        }

        guard let subcommand = remaining.first?.lowercased() else {
            return CLIOutput(exitCode: 0, stdout: dynamicUsage + "\n")
        }
        let subArgs = Array(remaining.dropFirst())
        let store = VeypaneStore(directoryURL: storeDir)

        do {
            switch subcommand {
            case "list", "ls":
                let loaded = store.load().state
                if outputJSON {
                    let summaries = loaded.pads.map { pad in
                        AutomationPadSummary(
                            id: pad.id.uuidString,
                            title: pad.title,
                            url: pad.url.absoluteString,
                            isSelected: pad.id == loaded.selectedPadID,
                            isHibernated: pad.isHibernated,
                            isMuted: pad.isMuted,
                            badge: pad.formattedBadge
                        )
                    }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    let data = try encoder.encode(summaries)
                    return CLIOutput(exitCode: 0, stdout: String(decoding: data, as: UTF8.self) + "\n")
                } else {
                    var lines: [String] = []
                    for (idx, pad) in loaded.pads.enumerated() {
                        let marker = (pad.id == loaded.selectedPadID) ? "*" : " "
                        let badge = pad.formattedBadge.map { " [\($0)]" } ?? ""
                        let stateTag = pad.isHibernated ? " (hibernated)" : ""
                        lines.append("\(marker) \(idx + 1). \(pad.title)\(badge)\(stateTag) — \(pad.url.absoluteString) [\(pad.id.uuidString)]")
                    }
                    return CLIOutput(exitCode: 0, stdout: lines.joined(separator: "\n") + (lines.isEmpty ? "" : "\n"))
                }

            case "add":
                guard let rawURL = subArgs.first else {
                    return CLIOutput(exitCode: 2, stderr: "Error: 'add' requires a <url>.\n")
                }
                let targetURL = OmniboxParser.resolve(input: rawURL).url
                var title: String?
                var profileName: String?
                var idx = 1
                while idx < subArgs.count {
                    switch subArgs[idx] {
                    case "--title":
                        if idx + 1 < subArgs.count { title = subArgs[idx + 1]; idx += 2 } else { idx += 1 }
                    case "--profile":
                        if idx + 1 < subArgs.count { profileName = subArgs[idx + 1]; idx += 2 } else { idx += 1 }
                    default:
                        idx += 1
                    }
                }

                var state = store.load().state
                let profileID = profileName.flatMap { name in
                    state.profiles.first(where: { $0.name.lowercased() == name.lowercased() })?.id
                }
                let created = PadWorkspaceEngine.addPad(
                    to: &state,
                    url: targetURL,
                    title: title,
                    profileID: profileID,
                    select: true
                )
                try store.save(state)
                try? ipcSender.send(.reloadStore)
                return CLIOutput(exitCode: 0, stdout: "Added pad '\(created.title)' (\(created.id.uuidString)) -> \(created.url.absoluteString)\n")

            case "remove", "rm":
                guard let query = subArgs.first else {
                    return CLIOutput(exitCode: 2, stderr: "Error: 'remove' requires a pad ID or title.\n")
                }
                var state = store.load().state
                guard let match = PadWorkspaceEngine.findPad(matching: query, in: state.pads),
                      let removed = PadWorkspaceEngine.removePad(id: match.id, from: &state) else {
                    return CLIOutput(exitCode: 1, stderr: "Error: No pad matching '\(query)'.\n")
                }
                try store.save(state)
                try? ipcSender.send(.reloadStore)
                return CLIOutput(exitCode: 0, stdout: "Removed pad '\(removed.title)' (\(removed.id.uuidString))\n")

            case "open":
                guard let rawURL = subArgs.first else {
                    return CLIOutput(exitCode: 2, stderr: "Error: 'open' requires a <url>.\n")
                }
                var padQuery: String?
                var inNewPad = false
                var idx = 1
                while idx < subArgs.count {
                    switch subArgs[idx] {
                    case "--pad":
                        if idx + 1 < subArgs.count { padQuery = subArgs[idx + 1]; idx += 2 } else { idx += 1 }
                    case "--new":
                        inNewPad = true
                        idx += 1
                    default:
                        idx += 1
                    }
                }
                let resolvedURL = OmniboxParser.resolve(input: rawURL).url
                var state = store.load().state
                if inNewPad {
                    _ = PadWorkspaceEngine.addPad(to: &state, url: resolvedURL, select: true)
                } else if let padQuery,
                          let match = PadWorkspaceEngine.findPad(matching: padQuery, in: state.pads),
                          let matchIndex = state.pads.firstIndex(where: { $0.id == match.id }) {
                    state.pads[matchIndex].url = resolvedURL
                    state.pads[matchIndex].isHibernated = false
                    state.selectedPadID = match.id
                } else if let selectedID = state.selectedPadID,
                          let selectedIndex = state.pads.firstIndex(where: { $0.id == selectedID }) {
                    state.pads[selectedIndex].url = resolvedURL
                    state.pads[selectedIndex].isHibernated = false
                } else {
                    _ = PadWorkspaceEngine.addPad(to: &state, url: resolvedURL, select: true)
                }
                try store.save(state)
                try? ipcSender.send(.openURL(url: resolvedURL, padQuery: padQuery, inNewPad: inNewPad))
                return CLIOutput(exitCode: 0, stdout: "Opened \(resolvedURL.absoluteString)\n")

            case "select":
                guard let query = subArgs.first else {
                    return CLIOutput(exitCode: 2, stderr: "Error: 'select' requires a pad ID or title.\n")
                }
                var state = store.load().state
                guard let match = PadWorkspaceEngine.findPad(matching: query, in: state.pads) else {
                    return CLIOutput(exitCode: 1, stderr: "Error: No pad matching '\(query)'.\n")
                }
                PadWorkspaceEngine.selectPad(id: match.id, in: &state)
                try store.save(state)
                try? ipcSender.send(.selectPad(padQuery: match.id.uuidString))
                return CLIOutput(exitCode: 0, stdout: "Selected pad '\(match.title)'\n")

            case "toggle":
                try ipcSender.send(.togglePanel)
                return CLIOutput(exitCode: 0, stdout: "Sent toggle command to \(AppBrandIdentity.productName).\n")

            case "show":
                try ipcSender.send(.showPanel)
                return CLIOutput(exitCode: 0, stdout: "Sent show command to \(AppBrandIdentity.productName).\n")

            case "hide":
                try ipcSender.send(.hidePanel)
                return CLIOutput(exitCode: 0, stdout: "Sent hide command to \(AppBrandIdentity.productName).\n")

            case "ui":
                guard let uiSub = subArgs.first?.lowercased() else {
                    return CLIOutput(exitCode: 2, stderr: "Usage: \(cliName) ui <state | diagnostics | open-settings [pane] | show-welcome>\n")
                }
                switch uiSub {
                case "state":
                    let data = try store.readUIStateData()
                    let text = String(decoding: data, as: UTF8.self)
                    return CLIOutput(exitCode: 0, stdout: text.hasSuffix("\n") ? text : (text + "\n"))
                case "diagnostics", "diag":
                    let snap = try store.readUIState()
                    let payload = UIDiagnosticsDump(
                        appName: snap.appName,
                        bundleIdentifier: snap.bundleIdentifier,
                        pid: snap.pid,
                        panelVisible: snap.panelVisible,
                        selectedPad: snap.selectedPad,
                        diagnostics: snap.diagnostics,
                        updatedAt: snap.updatedAt
                    )
                    let data = try VeypaneStore.makeEncoder().encode(payload)
                    let text = String(decoding: data, as: UTF8.self)
                    return CLIOutput(exitCode: 0, stdout: text.hasSuffix("\n") ? text : (text + "\n"))
                case "open-settings":
                    let pane = subArgs.count > 1 ? subArgs[1] : nil
                    try ipcSender.send(.openSettings(pane: pane))
                    return CLIOutput(exitCode: 0, stdout: "Sent open-settings command.\n")
                case "show-welcome":
                    try ipcSender.send(.showWelcome)
                    return CLIOutput(exitCode: 0, stdout: "Sent show-welcome command.\n")
                default:
                    return CLIOutput(exitCode: 2, stderr: "Unknown ui subcommand '\(uiSub)'.\n")
                }

            case "export":
                guard let path = subArgs.first else {
                    return CLIOutput(exitCode: 2, stderr: "Error: 'export' requires a destination path.\n")
                }
                let state = store.load().state
                let data = try store.exportData(from: state)
                let fileURL = URL(fileURLWithPath: path)
                try data.write(to: fileURL, options: .atomic)
                return CLIOutput(exitCode: 0, stdout: "Exported settings to \(fileURL.path)\n")

            case "import":
                guard let path = subArgs.first else {
                    return CLIOutput(exitCode: 2, stderr: "Error: 'import' requires a source file path.\n")
                }
                let merge = subArgs.contains("--merge")
                let fileURL = URL(fileURLWithPath: path)
                let data = try Data(contentsOf: fileURL)
                let current = store.load().state
                let updated = try store.importData(data, into: current, merge: merge)
                try store.save(updated)
                try? ipcSender.send(.reloadStore)
                return CLIOutput(exitCode: 0, stdout: "Imported settings from \(fileURL.path)\n")

            case "url":
                let actionName = subArgs.first?.lowercased() ?? "toggle"
                let action: VeypaneAutomationAction = switch actionName {
                case "show": .showPanel
                case "hide": .hidePanel
                default: .togglePanel
                }
                let preferredScheme = AppBrandIdentity.preferredURLScheme(forCLIInvocationName: cliName)
                let schemeURL = VeypaneURLCommand.makeURL(for: action, scheme: preferredScheme)?.absoluteString
                    ?? "\(preferredScheme)://toggle"
                return CLIOutput(exitCode: 0, stdout: schemeURL + "\n")

            case "extensions", "ext":
                return try runExtensionsSubcommand(
                    cliName: cliName,
                    subArgs: subArgs,
                    store: store,
                    outputJSON: outputJSON,
                    ipcSender: ipcSender
                )

        default:
            return CLIOutput(
                exitCode: 2,
                stderr: "Unknown command '\(subcommand)'. Run '\(cliName) --help'.\n"
            )
        }
        } catch {
            return CLIOutput(exitCode: 1, stderr: "Error: \(error.localizedDescription)\n")
        }
    }

    private struct UIDiagnosticsDump: Codable, Sendable {
        var appName: String
        var bundleIdentifier: String
        var pid: Int32
        var panelVisible: Bool
        var selectedPad: String
        var diagnostics: RuntimeDiagnosticsCounters
        var updatedAt: Date
    }

    private static func runExtensionsSubcommand(
        cliName: String,
        subArgs: [String],
        store: VeypaneStore,
        outputJSON: Bool,
        ipcSender: any IPCSender
    ) throws -> CLIOutput {
        let action = subArgs.first?.lowercased() ?? "list"
        switch action {
        case "list", "ls":
            let state = store.load().state
            if outputJSON {
                let summaries = state.installedExtensions.map { ext in
                    AutomationExtensionSummary(
                        id: ext.id,
                        name: ext.displayName,
                        version: ext.version,
                        enabled: ext.enabled,
                        loaded: false,
                        errors: [],
                        commands: []
                    )
                }
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(summaries)
                return CLIOutput(exitCode: 0, stdout: String(decoding: data, as: UTF8.self) + "\n")
            } else {
                if state.installedExtensions.isEmpty {
                    return CLIOutput(exitCode: 0, stdout: "No extensions installed.\n")
                }
                let lines = state.installedExtensions.enumerated().map { idx, ext in
                    let status = ext.enabled ? "enabled" : "disabled"
                    return "  \(idx + 1). \(ext.displayName) v\(ext.version) (\(status)) [\(ext.id)]"
                }
                return CLIOutput(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n")
            }

        case "add", "install":
            guard subArgs.count >= 2 else {
                return CLIOutput(exitCode: 2, stderr: "Error: 'extensions add' requires a folder, .zip, .crx, or Safari .app/.appex path.\n")
            }
            let rawPath = (subArgs[1] as NSString).expandingTildeInPath
            let sourceURL = URL(fileURLWithPath: rawPath)
            var state = store.load().state
            if ExtensionPackageInstaller.isSafariAppOrAppexSource(sourceURL) {
                let registered = try ExtensionPackageInstaller.registerSafariAppExtensions(
                    from: sourceURL,
                    existingExtensions: state.installedExtensions
                )
                for ext in registered {
                    if let existingIndex = state.installedExtensions.firstIndex(where: { $0.id == ext.id }) {
                        state.installedExtensions[existingIndex] = ext
                    } else {
                        state.installedExtensions.append(ext)
                    }
                }
                try store.save(state)
                try? ipcSender.send(.syncExtensionsFromStore)
                let lines = registered.map { ext in
                    "Linked Safari extension '\(ext.displayName)' v\(ext.version) [\(ext.id)]"
                }
                return CLIOutput(exitCode: 0, stdout: lines.joined(separator: "\n") + "\n")
            }

            let installed = try ExtensionPackageInstaller.installExtensionPackage(
                from: sourceURL,
                extensionsRootDirectory: store.extensionsDirectoryURL,
                existingExtensions: state.installedExtensions
            )
            if let existingIndex = state.installedExtensions.firstIndex(where: { $0.id == installed.id }) {
                state.installedExtensions[existingIndex] = installed
            } else {
                state.installedExtensions.append(installed)
            }
            try store.save(state)
            try? ipcSender.send(.syncExtensionsFromStore)
            return CLIOutput(
                exitCode: 0,
                stdout: "Installed extension '\(installed.displayName)' v\(installed.version) [\(installed.id)]\n"
            )

        case "refresh", "update":
            var state = store.load().state
            var updatedCount = 0
            var lines: [String] = []
            for idx in state.installedExtensions.indices {
                let ext = state.installedExtensions[idx]
                guard ext.sourceKind == .safariAppExtension else { continue }
                let check = ExtensionPackageInstaller.checkSafariExtensionForUpdate(ext)
                switch check.status {
                case .updated(let oldV, let newV, _, _):
                    if let updatedRecord = check.updatedRecord {
                        state.installedExtensions[idx] = updatedRecord
                        updatedCount += 1
                        lines.append("Updated Safari extension '\(updatedRecord.displayName)' \(oldV) -> \(newV) [\(updatedRecord.id)]")
                    }
                case .upToDate:
                    lines.append("Up to date: '\(ext.displayName)' v\(ext.version) [\(ext.id)]")
                case .sourceMissing(let path):
                    lines.append("Missing source app for '\(ext.displayName)' at \(path) [\(ext.id)]")
                case .notApplicable:
                    break
                }
            }
            if updatedCount > 0 {
                try store.save(state)
                try? ipcSender.send(.syncExtensionsFromStore)
            }
            let out = lines.isEmpty ? "No linked Safari app extensions.\n" : lines.joined(separator: "\n") + "\n"
            return CLIOutput(exitCode: 0, stdout: out)

        case "remove", "rm", "uninstall":
            guard subArgs.count >= 2 else {
                return CLIOutput(exitCode: 2, stderr: "Error: 'extensions remove' requires an extension ID or name.\n")
            }
            let query = subArgs[1]
            var state = store.load().state
            guard let index = findExtensionIndex(matching: query, in: state.installedExtensions) else {
                return CLIOutput(exitCode: 1, stderr: "Error: No extension matching '\(query)'.\n")
            }
            let removed = state.installedExtensions.remove(at: index)
            if removed.sourceKind == .copiedPackage, !removed.folderName.isEmpty {
                let extFolder = store.extensionsDirectoryURL.appendingPathComponent(removed.folderName, isDirectory: true)
                try? FileManager.default.removeItem(at: extFolder)
            }
            try store.save(state)
            try? ipcSender.send(.syncExtensionsFromStore)
            return CLIOutput(
                exitCode: 0,
                stdout: "Removed extension '\(removed.displayName)' [\(removed.id)]\n"
            )

        case "enable", "disable":
            guard subArgs.count >= 2 else {
                return CLIOutput(exitCode: 2, stderr: "Error: 'extensions \(action)' requires an extension ID or name.\n")
            }
            let query = subArgs[1]
            let shouldEnable = (action == "enable")
            var state = store.load().state
            guard let index = findExtensionIndex(matching: query, in: state.installedExtensions) else {
                return CLIOutput(exitCode: 1, stderr: "Error: No extension matching '\(query)'.\n")
            }
            state.installedExtensions[index].enabled = shouldEnable
            let target = state.installedExtensions[index]
            try store.save(state)
            try? ipcSender.send(.syncExtensionsFromStore)
            let verb = shouldEnable ? "Enabled" : "Disabled"
            return CLIOutput(
                exitCode: 0,
                stdout: "\(verb) extension '\(target.displayName)' [\(target.id)]\n"
            )

        case "command", "cmd":
            guard subArgs.count >= 3 else {
                return CLIOutput(exitCode: 2, stderr: "Error: 'extensions command' requires <id> <commandId>.\n")
            }
            let extQuery = subArgs[1]
            let cmdID = subArgs[2]
            var padQuery: String?
            var idx = 3
            while idx < subArgs.count {
                if subArgs[idx] == "--pad", idx + 1 < subArgs.count {
                    padQuery = subArgs[idx + 1]
                    idx += 2
                } else {
                    idx += 1
                }
            }
            try ipcSender.send(.performExtensionCommand(
                extensionQuery: extQuery,
                commandID: cmdID,
                padQuery: padQuery
            ))
            return CLIOutput(
                exitCode: 0,
                stdout: "Sent command '\(cmdID)' to extension '\(extQuery)'.\n"
            )

        default:
            return CLIOutput(
                exitCode: 2,
                stderr: "Usage: \(cliName) extensions <list | add <path> | remove <id> | enable <id> | disable <id> | command <id> <commandId>>\n"
            )
        }
    }

    private static func findExtensionIndex(matching query: String, in list: [InstalledExtension]) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()
        if let exact = list.firstIndex(where: { $0.id.lowercased() == lower || $0.folderName.lowercased() == lower }) {
            return exact
        }
        if let byName = list.firstIndex(where: { $0.displayName.lowercased() == lower }) {
            return byName
        }
        return list.firstIndex(where: { $0.displayName.lowercased().contains(lower) || $0.id.lowercased().contains(lower) })
    }
}
