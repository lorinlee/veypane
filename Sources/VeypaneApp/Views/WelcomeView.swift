import AppKit
import SwiftUI
import ApplicationServices
import VeypaneCore

public struct WelcomeView: View {
    @Bindable var model: AppModel
    public var onTryNow: () -> Void

    @State private var isAccessibilityGranted: Bool = AXIsProcessTrusted()
    @State private var pollTimer: Timer? = nil

    public init(model: AppModel, onTryNow: @escaping () -> Void) {
        self.model = model
        self.onTryNow = onTryNow
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Header
            VStack(spacing: 6) {
                if let iconURL = L10n.iconFileURL, let appIcon = NSImage(contentsOf: iconURL) {
                    Image(nsImage: appIcon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 52, height: 52)
                } else {
                    Image(systemName: "rectangle.righthalf.inset.filled")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor)
                }

                Text(L10n.string("welcome.heading"))
                    .font(.system(size: 20, weight: .bold))

                Text(L10n.string("welcome.subheading"))
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 18)

            // Step 1: Choose edge/corner + hotkey
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L10n.string("welcome.step1.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text(model.state.settings.toggleHotkey.displayString)
                        .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }

                Text(L10n.format("welcome.step1.caption", model.state.settings.toggleHotkey.displayString))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    ScreenAnchorDiagramView(
                        selectedAnchor: Binding(
                            get: { model.state.settings.anchor },
                            set: { newAnchor in
                                model.state.settings.anchor = newAnchor
                                model.refreshPanelGeometryAndAppearance()
                                model.persistState()
                            }
                        ),
                        widthPercent: model.state.settings.widthPercent,
                        heightPercent: model.state.settings.heightPercent,
                        compact: true
                    )
                    Spacer()
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )

            // Step 2: Grant Accessibility
            HStack(spacing: 12) {
                Image(systemName: isAccessibilityGranted ? "checkmark.shield.fill" : "hand.raised.circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isAccessibilityGranted ? Color.green : Color.orange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("welcome.step2.title"))
                        .font(.system(size: 13, weight: .semibold))
                    Text(isAccessibilityGranted ? L10n.string("welcome.ax.granted") : L10n.string("welcome.step2.caption"))
                        .font(.system(size: 11.5))
                        .foregroundStyle(isAccessibilityGranted ? Color.green : Color.secondary)
                        .lineLimit(2)
                }

                Spacer()

                if !isAccessibilityGranted {
                    Button(L10n.string("welcome.ax.grant_button")) {
                        promptAccessibilityPermission()
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )

            Spacer(minLength: 0)

            // Step 3: "Try It Now" button
            HStack {
                Spacer()
                Button {
                    onTryNow()
                } label: {
                    HStack(spacing: 6) {
                        Text(L10n.string("welcome.try_now"))
                            .font(.system(size: 13.5, weight: .semibold))
                        Image(systemName: "arrow.right.circle.fill")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                Spacer()
            }
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 24)
        .frame(width: 520, height: 440)
        .onAppear {
            isAccessibilityGranted = AXIsProcessTrusted()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
                Task { @MainActor in
                    isAccessibilityGranted = AXIsProcessTrusted()
                }
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }

    private func promptAccessibilityPermission() {
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options)
        if let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(settingsURL)
        }
        isAccessibilityGranted = AXIsProcessTrusted()
    }
}
