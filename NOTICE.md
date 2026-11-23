# Project Notice

## License

Veypane source code, build scripts, and CoreGraphics icon generator in this repository are licensed under the MIT License — see [LICENSE](LICENSE) (`Copyright (c) 2026 Lorin Lee`).

## Apple Platform SDKs, WebKit & SF Symbols (Not Relicensed Under MIT)

Veypane is a native macOS application written in Swift 6.2 that links against Apple's public macOS system SDKs (`Foundation`, `CoreGraphics`, `ImageIO`, `Darwin`, `Observation`, `AppKit`, `SwiftUI`, `WebKit`, `Carbon`, `UserNotifications`, `ServiceManagement`, `AppIntents`, `UniformTypeIdentifiers`, and `ApplicationServices`) and references standard Apple SF Symbols solely via runtime system APIs (`Image(systemName:)` / `NSImage(systemSymbolName:accessibilityDescription:)`).

- Apple system frameworks, WebKit, macOS system fonts, and Apple SF Symbols are **not** included in this repository and are **not** relicensed under the MIT License. They remain the intellectual property of Apple Inc. and are governed by Apple's Xcode and Apple SDKs Agreement and Apple's SF Symbols license terms.
- The application icon (`Assets/AppIcon/Veypane-1024.png`, `Assets/AppIcon/Veypane.icns`, and `Sources/VeypaneCore/Resources/Veypane.icns`) is generated procedurally with CoreGraphics by `scripts/generate-icon.swift` and does not embed any SF Symbols glyphs or third-party artwork.

## Third-Party Packages & Extensions

- `Package.swift` declares zero external Swift Package Manager dependencies (`dependencies: []`).
- No third-party browser extensions are bundled, vendored, or redistributed in this repository. Users who load browser extensions on macOS 15.4+ do so from their own local packages or already-installed Safari Web Extension applications, subject to each extension's own license and terms.
- All third-party product names, browser names, search engine presets, and trademarks referenced for interoperability belong to their respective owners. Veypane is not affiliated with, endorsed by, or sponsored by any third party.
