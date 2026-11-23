import Foundation

public enum VeypaneAutomationAction: Codable, Equatable, Sendable {
    case togglePanel
    case showPanel
    case hidePanel
    case openURL(url: URL, padQuery: String?, inNewPad: Bool)
    case addPad(url: URL, title: String?, profileName: String?)
    case removePad(padQuery: String)
    case selectPad(padQuery: String)
    case reloadStore
    case openSettings(pane: String?)
    case showWelcome
    case syncExtensionsFromStore
    case performExtensionCommand(extensionQuery: String, commandID: String, padQuery: String?)
}

public enum VeypaneIPC {
    /// Preserved distributed notification identifier (Bucket A) so existing IPC callers remain compatible.
    public static let distributedNotificationName = Notification.Name("com.slidecraft.ipc.command")
    public static let payloadUserInfoKey = "payload"

    public static func encode(_ action: VeypaneAutomationAction) throws -> String {
        let data = try JSONEncoder().encode(action)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ payload: String) throws -> VeypaneAutomationAction {
        guard let data = payload.data(using: .utf8) else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try JSONDecoder().decode(VeypaneAutomationAction.self, from: data)
    }

    public static func extractAction(from notification: Notification) -> VeypaneAutomationAction? {
        if let raw = notification.userInfo?[payloadUserInfoKey] as? String,
           let decoded = try? decode(raw) {
            return decoded
        }
        if let raw = notification.object as? String,
           let decoded = try? decode(raw) {
            return decoded
        }
        return nil
    }
}

public enum VeypaneURLCommand {
    public static let scheme = AppBrandIdentity.primaryURLScheme
    public static let primaryScheme = AppBrandIdentity.primaryURLScheme

    /// Parses URLs under `veypane://...` and preserved legacy `sidelark://...` / `slidecraft://...`.
    public static func parse(_ url: URL) -> VeypaneAutomationAction? {
        guard AppBrandIdentity.isSupportedURLScheme(url.scheme) else { return nil }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let command = (url.host ?? components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? "")
            .lowercased()

        let params: [String: String] = Dictionary(
            (components?.queryItems ?? []).compactMap { item in
                guard let value = item.value else { return nil }
                return (item.name.lowercased(), value)
            },
            uniquingKeysWith: { _, last in last }
        )

        switch command {
        case "toggle", "":
            return .togglePanel
        case "show":
            return .showPanel
        case "hide":
            return .hidePanel
        case "reload":
            return .reloadStore
        case "settings":
            return .openSettings(pane: params["pane"])
        case "welcome":
            return .showWelcome
        case "open":
            guard let rawURL = params["url"],
                  let target = resolveTargetURL(rawURL) else {
                return nil
            }
            let padQuery = params["pad"]
            let inNew = (params["new"] == "1" || params["new"]?.lowercased() == "true")
            return .openURL(url: target, padQuery: padQuery, inNewPad: inNew)
        case "add":
            guard let rawURL = params["url"],
                  let target = resolveTargetURL(rawURL) else {
                return nil
            }
            return .addPad(url: target, title: params["title"], profileName: params["profile"])
        case "remove", "delete":
            guard let padQuery = params["pad"] ?? params["id"], !padQuery.isEmpty else {
                return nil
            }
            return .removePad(padQuery: padQuery)
        case "select", "focus":
            guard let padQuery = params["pad"] ?? params["id"], !padQuery.isEmpty else {
                return nil
            }
            return .selectPad(padQuery: padQuery)
        case "extensions-sync":
            return .syncExtensionsFromStore
        case "extension-command":
            guard let ext = params["extension"] ?? params["id"], !ext.isEmpty,
                  let cmd = params["command"], !cmd.isEmpty else {
                return nil
            }
            return .performExtensionCommand(extensionQuery: ext, commandID: cmd, padQuery: params["pad"])
        default:
            return nil
        }
    }

    public static func makeURL(
        for action: VeypaneAutomationAction,
        scheme customScheme: String = scheme
    ) -> URL? {
        var components = URLComponents()
        components.scheme = customScheme

        switch action {
        case .togglePanel:
            components.host = "toggle"
        case .showPanel:
            components.host = "show"
        case .hidePanel:
            components.host = "hide"
        case .reloadStore:
            components.host = "reload"
        case .openSettings(let pane):
            components.host = "settings"
            if let pane, !pane.isEmpty {
                components.queryItems = [URLQueryItem(name: "pane", value: pane)]
            }
        case .showWelcome:
            components.host = "welcome"
        case .openURL(let url, let padQuery, let inNewPad):
            components.host = "open"
            var items = [URLQueryItem(name: "url", value: url.absoluteString)]
            if let padQuery, !padQuery.isEmpty {
                items.append(URLQueryItem(name: "pad", value: padQuery))
            }
            if inNewPad {
                items.append(URLQueryItem(name: "new", value: "1"))
            }
            components.queryItems = items
        case .addPad(let url, let title, let profileName):
            components.host = "add"
            var items = [URLQueryItem(name: "url", value: url.absoluteString)]
            if let title, !title.isEmpty {
                items.append(URLQueryItem(name: "title", value: title))
            }
            if let profileName, !profileName.isEmpty {
                items.append(URLQueryItem(name: "profile", value: profileName))
            }
            components.queryItems = items
        case .removePad(let padQuery):
            components.host = "remove"
            components.queryItems = [URLQueryItem(name: "pad", value: padQuery)]
        case .selectPad(let padQuery):
            components.host = "select"
            components.queryItems = [URLQueryItem(name: "pad", value: padQuery)]
        case .syncExtensionsFromStore:
            components.host = "extensions-sync"
        case .performExtensionCommand(let extensionQuery, let commandID, let padQuery):
            components.host = "extension-command"
            var items = [
                URLQueryItem(name: "extension", value: extensionQuery),
                URLQueryItem(name: "command", value: commandID)
            ]
            if let padQuery, !padQuery.isEmpty {
                items.append(URLQueryItem(name: "pad", value: padQuery))
            }
            components.queryItems = items
        }

        return components.url
    }

    private static func resolveTargetURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed), direct.scheme != nil {
            return direct
        }
        return OmniboxParser.resolve(input: trimmed).url
    }
}
