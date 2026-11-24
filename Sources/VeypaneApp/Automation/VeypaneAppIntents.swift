import AppIntents
import Foundation
import VeypaneCore

public struct ToggleVeypaneIntent: AppIntent {
    public static let title: LocalizedStringResource = "Toggle Veypane Panel"
    public static let description = IntentDescription("Slides the Veypane browser panel in or out.")
    public static let openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AppModel.shared.togglePanel(activateFocus: true)
        return .result()
    }
}

public struct OpenVeypanePadIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open URL in Veypane Pad"
    public static let description = IntentDescription("Opens a URL inside a matching or active Veypane pad.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "URL")
    public var url: URL

    @Parameter(title: "Pad Name (Optional)")
    public var padName: String?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AppModel.shared.handleAutomationAction(
            .openURL(url: url, padQuery: padName, inNewPad: false)
        )
        return .result()
    }
}

public struct AddVeypanePadIntent: AppIntent {
    public static let title: LocalizedStringResource = "Add Veypane Pad"
    public static let description = IntentDescription("Creates a new website pad in Veypane.")
    public static let openAppWhenRun: Bool = true

    @Parameter(title: "URL")
    public var url: URL

    @Parameter(title: "Title")
    public var title: String?

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        AppModel.shared.handleAutomationAction(
            .addPad(url: url, title: title, profileName: nil)
        )
        return .result()
    }
}

public struct VeypaneShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleVeypaneIntent(),
            phrases: [
                "Toggle \(.applicationName)",
                "Show \(.applicationName) panel"
            ],
            shortTitle: "Toggle Panel",
            systemImageName: "sidebar.right"
        )
        AppShortcut(
            intent: AddVeypanePadIntent(),
            phrases: [
                "Add pad in \(.applicationName)"
            ],
            shortTitle: "Add Pad",
            systemImageName: "plus.rectangle.on.rectangle"
        )
    }
}
