# Veypane

Veypane (formerly developed under the working names `Sidelark` and `SlideCraft`) is a native macOS slide-over browser built with Swift 6.2, AppKit, SwiftUI, and WebKit (`WKWebView`) for macOS 14+. It presents a floating rounded vibrancy card (`66% × 76%` of the visible screen by default, inset `14 pt` from the screen edge, menu bar, and Dock) that slides smoothly in on demand (`~0.22 s`, or instant when animations are disabled / cross-fade under Reduce Motion) and slides away after the pointer leaves for `>0.4 s` unless pinned.

Licensed under the [MIT License](LICENSE) (`Copyright (c) 2026 Lorin Lee`). Apple system frameworks, WebKit, and Apple SF Symbols are not included in this repository and are not relicensed under MIT — see [NOTICE.md](NOTICE.md).

## Architecture & Project Structure

- **`VeypaneCore`** (`Sources/VeypaneCore`): Pure non-UI SwiftPM library containing `AppBrandIdentity`, workspace models (`Pad`, `BrowserProfile`, `FavoriteItem`, `RecentHistoryEntry`, `InstalledExtension`, `AppSettings` including customizable sidebar width/icon size and page retention policy, `UIStateSnapshot`, `RuntimeDiagnosticsCounters`), schema-versioned atomic JSON persistence (`VeypaneStore`, `v1`→`v6` non-destructive migration), `AddressBarStateMachine`, `FaviconCandidateSelector`, `PanelTransitionController`, `PadSessionPool`, `SiteCompatibilityInspector` & `SiteDiagnosticsReport`, `ExtensionPackageInstaller` (unpacked folders, `.zip`, CRX2/CRX3, and Safari `.app`/`.appex` discovery), English (`en`) and Simplified Chinese (`zh-Hans`) `Localizable.strings` + `L10n` resolver, `VeypaneURLCommand` (`veypane://`, plus preserved `sidelark://` and `slidecraft://`), `VeypaneCLIRunner`, and an opt-in `127.0.0.1` HTTP + MCP JSON-RPC 2.0 server (`LocalAutomationServer`).
- **`VeypaneApp`** (`Sources/VeypaneApp`): Menu bar + `LSUIElement` native macOS app (`Veypane.app`) featuring `SingleInstanceGuard`, borderless seamless top-edge `SlideOverPanel`, `EdgeMonitorController`, persistent `PadDeckContainerNSView`, `FaviconCacheManager`, URL-free compact header with `⌘L` transient address editor, `ExtensionManager` (`WKWebExtensionController` on macOS 15.4+), calm `SiteCompatibilityBanner` + origin-only `SiteDiagnosticsSheetView`, native `SettingsView`, `WelcomeView`, Apple Shortcuts `AppIntents`, and isolated CLI verification probes.
- **`veypanectl`** (`Sources/veypanectl`, plus preserved compatibility shims **`sidelarkctl`** and **`slidecraftctl`** in `Sources/sidelarkctl` and `Sources/slidecraftctl`): Command-line controllers for showing/hiding/toggling the panel, managing pads and browser extensions, exporting/importing settings, inspecting `ui state` and `ui diagnostics`, and opening Settings panes or the Welcome guide.
- **`VeypaneCoreTests`** (`Tests/VeypaneCoreTests`): Swift Testing unit and regression suite covering persistence migration, sidebar customization, page retention, memory pressure & WebKit crash recovery, popup/navigation contracts, URL/CLI/HTTP compatibility aliases, and branding/version sync.
- **`scripts/bundle.sh`, `scripts/generate-icon.swift` & `scripts/install-upgrade.sh`**: Generates the CoreGraphics vector app icon (`Assets/AppIcon/Veypane.icns`, `Assets/AppIcon/Veypane-1024.png`, and `Sources/VeypaneCore/Resources/Veypane.icns`), builds release binaries, packages `Veypane.app` + `Veypane.zip`, and provides a non-destructive upgrade helper.

## Building, Testing & Packaging

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift build -c release && swift test
```

To package `Veypane.app` and `Veypane.zip` without launching the app:

```bash
./scripts/bundle.sh
```

## Preserved Historical Compatibility Identifiers (Bucket A)

To ensure seamless upgrades from earlier `SlideCraft` / `Sidelark` builds without losing user workspaces, logins, cookies, macOS Accessibility permissions, iCloud/folder sync files, Shortcuts, or automation scripts, the following technical identifiers are intentionally preserved alongside the new `Veypane` primary interfaces:

| Compatibility Identifier | Preserved Value | Why Preserved | Veypane Primary / Alias |
| :--- | :--- | :--- | :--- |
| `CFBundleIdentifier` | `com.slidecraft.app` | Keeps macOS Accessibility (TCC), LaunchServices, single-instance guard, and WebKit data stores bound | Display name `Veypane`, bundle `Veypane.app` |
| `CFBundleExecutable` | `SlideCraftApp` | Keeps existing upgrade/process checks and macOS bundle metadata continuous while building from SwiftPM target `VeypaneApp` | SwiftPM executable target `VeypaneApp` |
| Application Support directory | `~/Library/Application Support/SlideCraft` | Preserves `workspace.json`, `Extensions/`, `Favicons/`, `ui-state.json`, `instance.lock` | Managed by `VeypaneStore` |
| Default iCloud sync folder & filename | `~/Library/Mobile Documents/com~apple~CloudDocs/SlideCraft` & `slidecraft-sync.json` | Preserves existing synced folders across devices | `VeypaneStore` also reads `veypane-sync.json` if newer |
| Window autosave & WebKit rule store keys | `SlideCraftSettingsWindow`, `SlideCraftContentRules` | Preserves saved Settings window frame and compiled WebKit content rules | Internal macOS persistence keys |
| Distributed IPC notification | `com.slidecraft.ipc.command` | Keeps CLI & running-app IPC compatible across versions | `VeypaneIPC.distributedNotificationName` |
| URL schemes (`CFBundleURLName: com.slidecraft.urlscheme`) | `sidelark://`, `slidecraft://` | Keeps existing bookmarks, LaunchBar/Raycast/Alfred scripts, and workflows working | Primary: `veypane://` |
| CLI entrypoints | `sidelarkctl`, `slidecraftctl` | Keeps existing shell scripts and aliases working | Primary: `veypanectl` |
| Local HTTP automation token headers | `X-Sidelark-Token`, `X-SlideCraft-Token` | Keeps existing local scripts/MCP clients authenticating | Primary: `Authorization: Bearer` & `X-Veypane-Token` |
| Apple Shortcuts `AppIntent` struct names | `ToggleSlideCraftIntent`, `OpenSlideCraftPadIntent`, `AddSlideCraftPadIntent` | Prevents breaking user-created Apple Shortcuts bound by intent identifier | User-visible titles all use `Veypane` |
| WebKit JS bridge & error domains | `slidecraftNotify`, `__slidecraftNotificationsInstalled`, `slidecraft-`, `slidecraft-css-`, `__slidecraftMuted`, `com.slidecraft.extensions`, `com.slidecraft.nativeMessaging` | Internal runtime hooks & error domain stability | Internal non-user-facing keys |
| Upgrade backup directory | `~/SlideCraft-App-Backups` | Keeps previous app backups grouped in one location (`scripts/install-upgrade.sh`) | Override via `BACKUP_ROOT` |

## CLI (`veypanectl`), Verification Hooks & URL Schemes

```bash
veypanectl show | hide | toggle
veypanectl list
veypanectl add https://docs.swift.org --title "Swift Docs" --profile Work
veypanectl open https://webkit.org --pad "Swift Docs"
veypanectl select "Swift Docs"
veypanectl remove "Swift Docs"

# Live UI state & diagnostics counters
veypanectl ui state
veypanectl ui diagnostics
veypanectl ui open-settings extensions
veypanectl ui show-welcome

# Browser extensions (macOS 15.4+: Safari .app/.appex, folder, .zip, or .crx)
veypanectl extensions list | add <path> | refresh | enable <id> | disable <id> | command <id> <cmd> | remove <id>
```

Legacy aliases `sidelarkctl` and `slidecraftctl` are also bundled in `Veypane.app/Contents/MacOS/`.

Supported URL schemes (`veypane://` primary; `sidelark://` and `slidecraft://` preserved):
- `veypane://toggle`, `veypane://show`, `veypane://hide`
- `veypane://open?url=https%3A%2F%2Fswift.org&pad=Search`
- `veypane://add?url=https%3A%2F%2Fexample.com&title=Example`
- `veypane://select?pad=Search`, `veypane://remove?pad=Example`
- `veypane://settings?pane=extensions`, `veypane://welcome`

Isolated verification modes (all use temporary directories and `WKWebsiteDataStore.nonPersistent()` and never touch user data):
- `Veypane.app/Contents/MacOS/SlideCraftApp --render-ui-snapshots <dir>` (supports optional `VEYPANE_SNAPSHOT_EXTENSION=<folder>` / legacy `SLIDECRAFT_SNAPSHOT_EXTENSION=<folder>`)
- `Veypane.app/Contents/MacOS/SlideCraftApp --interaction-probe <dir>`
- `Veypane.app/Contents/MacOS/SlideCraftApp --panel-animation-probe <dir>`
- `Veypane.app/Contents/MacOS/SlideCraftApp --banner-layout-probe <dir>`
- `Veypane.app/Contents/MacOS/SlideCraftApp --editing-shortcut-probe <dir>`
- `Veypane.app/Contents/MacOS/SlideCraftApp --popup-acceptance-probe <dir>`
- `Veypane.app/Contents/MacOS/SlideCraftApp --outside-click-probe <dir>`
- `Veypane.app/Contents/MacOS/SlideCraftApp --native-os-outside-click-probe <dir>` (`VEYPANE_RUN_OS_MOUSE_TESTS=1` or `SIDELARK_RUN_OS_MOUSE_TESTS=1`)
- `Veypane.app/Contents/MacOS/SlideCraftApp --native-os-window-resize-probe <dir>` (`VEYPANE_RUN_OS_RESIZE_TESTS=1` or `SIDELARK_RUN_OS_RESIZE_TESTS=1`)
- `Veypane.app/Contents/MacOS/SlideCraftApp --native-os-sidebar-drag-probe <dir>`
- `Veypane.app/Contents/MacOS/SlideCraftApp --panel-chrome-snapshot <dir>`
- `Veypane.app/Contents/MacOS/SlideCraftApp --google-compat-probe <dir>` (alias `--compatibility-probe <dir>`)

## Safe Future Local Checkout Directory Rename Plan

If your local working directory is still named `SlideCraft` (for example `~/Projects/SlideCraft`), do **not** rename it while active tooling or build processes hold open paths to it. When ready to switch to `Veypane` (or `veypane`) cleanly:

1. Finish and commit any local changes, then close active IDE/terminal/agent sessions rooted in the old path.
2. Rename the folder cleanly outside the checkout: `mv ~/Projects/SlideCraft ~/Projects/veypane` (or create a fresh clone at `~/Projects/veypane`).
3. Clean stale SwiftPM absolute path caches if needed (`rm -rf ~/Projects/veypane/.build`) and re-run `swift build -c release && swift test`.
4. User data in `~/Library/Application Support/SlideCraft` is independent of the repository checkout path and remains untouched.

## Known Platform Limitations

1. **CloudKit Entitlement Sync**: Private CloudKit container sync requires a paid Apple Developer provisioning profile and signed iCloud container entitlements; Veypane provides folder / iCloud Drive JSON workspace sync under **Settings → Pads & Profiles**.
2. **Unsupported WebExtension APIs**: `nativeMessaging`, `sidePanel`, and `offscreen` documents are not provided by system WebKit.
3. **Always Keep Page Retention**: Setting background page retention to "Always Keep" prevents Veypane from auto-sleeping inactive pads on a timer, but macOS critical memory pressure, WebKit process termination, or site-initiated refreshes can still cause a page to reload.
