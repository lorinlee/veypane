import AppKit
import Darwin
import Foundation
import SwiftUI
import WebKit
import VeypaneCore

public struct PanelChromeSubviewSnapshot: Codable, Sendable {
    public var className: String
    public var frameInWindow: String
    public var isHidden: Bool
    public var alphaValue: Double
}

public struct PanelChromeTopRowSample: Codable, Sendable {
    public var ptFromTop: Int
    public var midXAlpha: Int
    public var midXRGB: String
    public var corner12Alpha: Int
    public var corner12RGB: String
    public var corner4Alpha: Int
}

public struct PanelChromeThemeMetrics: Codable, Sendable {
    public var theme: String
    public var styleMaskRawValue: UInt
    public var isTitled: Bool
    public var isBorderless: Bool
    public var isFullSizeContentView: Bool
    public var isResizable: Bool
    public var isNonActivatingPanel: Bool
    public var isOpaque: Bool
    public var hasShadow: Bool
    public var backgroundColorAlpha: Double
    public var windowFrame: String
    public var contentLayoutRect: String
    public var contentViewFrame: String
    public var contentViewSafeAreaTop: Double
    public var contentViewSafeAreaBottom: Double
    public var contentViewSafeAreaLeft: Double
    public var contentViewSafeAreaRight: Double
    public var frameViewClassName: String
    public var frameViewSubviews: [PanelChromeSubviewSnapshot]
    public var titlebarSubviewCount: Int
    public var firstHighAlphaRowAtMidXFromTop: Int?
    public var topBorderGapPtsAtMidX: Int?
    public var topRowsSample: [PanelChromeTopRowSample]
    public var fullImagePath: String
    public var topEdgeZoomImagePath: String
}

public struct PanelChromeSnapshotReport: Codable, Sendable {
    public var generatedAt: Date
    public var macOSVersion: String
    public var isolatedTemporaryStore: Bool
    public var nonPersistentWebDataStore: Bool
    public var themes: [PanelChromeThemeMetrics]
}

/// Process-local production `SlideOverPanel` chrome & top-edge snapshot runner (`t347`).
/// Renders the actual production `SlideOverPanel` + `PanelRootView.makeHostingView(model:)`
/// (including `frameView` / `NSThemeFrame` / titlebar / `safeAreaInsets` / perimeter overlay)
/// in both Light (`aqua`) and Dark (`darkAqua`) themes using an isolated temporary store and
/// `WKWebsiteDataStore.nonPersistent()`, with zero screen-capture APIs and zero external network traffic.
@MainActor
public enum PanelChromeSnapshotRunner {
    public static func runAndExit(outputDirectoryPath: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        DispatchQueue.global().asyncAfter(deadline: .now() + 45.0) {
            FileHandle.standardError.write(Data("Panel chrome snapshot timed out after 45s\n".utf8))
            Darwin.exit(2)
        }

        Task { @MainActor in
            do {
                let outDir = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
                _ = try await generate(into: outDir)
                Darwin.exit(0)
            } catch {
                FileHandle.standardError.write(Data("Panel chrome snapshot failed: \(error.localizedDescription)\n".utf8))
                Darwin.exit(1)
            }
        }
        app.run()
    }

    public static func generate(into outputDir: URL) async throws -> PanelChromeSnapshotReport {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let tempStoreRoot = fm.temporaryDirectory.appendingPathComponent(
            "VeypaneChromeSnap-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fm.removeItem(at: tempStoreRoot) }

        let store = VeypaneStore(directoryURL: tempStoreRoot)
        var initialState = WorkspaceState(pads: [
            Pad(title: "Veypane Workspace", url: URL(string: "about:blank")!, symbolName: "globe"),
            Pad(title: "Documentation", url: URL(string: "about:blank")!, symbolName: "book"),
            Pad(title: "Notes", url: URL(string: "about:blank")!, symbolName: "note.text")
        ])
        initialState.settings.hasCompletedOnboarding = true
        initialState.settings.isPinnedOpen = true
        initialState.settings.anchor = .right
        initialState.settings.appearance.cornerRadius = 12
        initialState.settings.appearance.hasShadow = true
        try store.save(initialState)

        let model = AppModel(store: store, allowExtensionPrompts: false, useNonPersistentWebsiteDataStore: true)
        model.startRuntimeServices {
            PanelRootView.makeHostingView(model: model)
        }
        defer { model.stopRuntimeServices() }

        guard let panel = model.panel else {
            throw NSError(domain: "PanelChromeSnapshot", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing SlideOverPanel"])
        }
        panel.reduceMotionOverride = true
        panel.simulatedKeyWindowOverride = true

        // Place panel offscreen at realistic size so frameView/NSHostingView lay out identically to live runtime
        // without flashing a GUI window on screen.
        let panelSize = NSSize(width: 900, height: 600)
        panel.setFrame(NSRect(x: -16000, y: -16000, width: panelSize.width, height: panelSize.height), display: false)
        panel.syncPerimeterCursorOverlayFrame()

        // Inject synthetic local HTML content into active nonPersistent WKWebView so content area is clearly visible
        if let pad = model.selectedPad, let wc = model.existingWebController(for: pad.id) {
            let html = """
            <!doctype html><html><head><meta charset="utf-8"><style>
            :root { color-scheme: light dark; }
            body { margin: 28px; font-family: -apple-system, sans-serif; background: Canvas; color: CanvasText; }
            .card { padding: 18px; border-radius: 12px; border: 1px solid rgba(128,128,128,0.22); }
            h1 { margin: 0 0 8px; font-size: 20px; }
            p { margin: 0; opacity: 0.78; font-size: 13px; }
            </style></head><body><div class="card"><h1>Veypane Top-Edge Chrome Check</h1><p>Isolated synthetic local document (nonPersistent store).</p></div></body></html>
            """
            wc.webView.loadHTMLString(html, baseURL: nil)
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        var themeResults: [PanelChromeThemeMetrics] = []
        let themes: [(name: String, themeSetting: AppThemePreference, appearance: NSAppearance.Name, backdropTop: NSColor, backdropBottom: NSColor)] = [
            (
                "light",
                .light,
                .aqua,
                NSColor(calibratedRed: 0.86, green: 0.90, blue: 0.96, alpha: 1.0),
                NSColor(calibratedRed: 0.76, green: 0.82, blue: 0.91, alpha: 1.0)
            ),
            (
                "dark",
                .dark,
                .darkAqua,
                NSColor(calibratedRed: 0.12, green: 0.14, blue: 0.20, alpha: 1.0),
                NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.12, alpha: 1.0)
            )
        ]

        for entry in themes {
            model.state.settings.appearance.theme = entry.themeSetting
            panel.applyAppearance(model.state.settings.appearance, isAlwaysOnTop: false)
            panel.appearance = NSAppearance(named: entry.appearance)
            panel.layoutIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.syncPerimeterCursorOverlayFrame()
            try await Task.sleep(nanoseconds: 180_000_000)
            panel.layoutIfNeeded()
            panel.contentView?.layoutSubtreeIfNeeded()
            panel.displayIfNeeded()

            guard let cv = panel.contentView, let frameView = cv.superview else {
                throw NSError(domain: "PanelChromeSnapshot", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing contentView/frameView"])
            }

            let fb = frameView.bounds
            guard let capturedRep = frameView.bitmapImageRepForCachingDisplay(in: fb) else {
                throw NSError(domain: "PanelChromeSnapshot", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmapImageRep"])
            }
            frameView.cacheDisplay(in: fb, to: capturedRep)

            // Measure alpha/RGB rows from top of the real captured frameView bitmap
            let pxW = capturedRep.pixelsWide
            let pxH = capturedRep.pixelsHigh
            let scaleX = Double(pxW) / max(1.0, Double(fb.width))
            let scaleY = Double(pxH) / max(1.0, Double(fb.height))

            func samplePixel(ptX: Double, ptFromTop: Int) -> (a: Int, rgb: String) {
                let ix = min(max(0, Int((ptX * scaleX).rounded())), pxW - 1)
                let iy = min(max(0, Int((Double(ptFromTop) * scaleY).rounded())), pxH - 1)
                guard let c = capturedRep.colorAt(x: ix, y: iy)?.usingColorSpace(.deviceRGB) else {
                    return (0, "#000000")
                }
                let r = Int((c.redComponent * 255.0).rounded())
                let g = Int((c.greenComponent * 255.0).rounded())
                let b = Int((c.blueComponent * 255.0).rounded())
                let a = Int((c.alphaComponent * 255.0).rounded())
                return (a, String(format: "#%02x%02x%02x", r, g, b))
            }

            var topRows: [PanelChromeTopRowSample] = []
            var firstHighAlpha: Int? = nil
            for dy in 0...44 {
                let mid = samplePixel(ptX: Double(fb.width) * 0.5, ptFromTop: dy)
                let c12 = samplePixel(ptX: 12.0, ptFromTop: dy)
                let c4 = samplePixel(ptX: 4.0, ptFromTop: dy)
                if firstHighAlpha == nil && mid.a >= 128 {
                    firstHighAlpha = dy
                }
                topRows.append(PanelChromeTopRowSample(
                    ptFromTop: dy,
                    midXAlpha: mid.a,
                    midXRGB: mid.rgb,
                    corner12Alpha: c12.a,
                    corner12RGB: c12.rgb,
                    corner4Alpha: c4.a
                ))
            }

            // Composite captured frameView onto a clean contrasting backdrop with accurate outer shadow contour
            let pad: CGFloat = 32
            let canvasSize = NSSize(width: fb.width + pad * 2, height: fb.height + pad * 2)
            let fullFile = outputDir.appendingPathComponent("panel-\(entry.name).png")
            try writeCompositedPNG(
                capturedRep: capturedRep,
                windowSize: fb.size,
                canvasSize: canvasSize,
                pad: pad,
                backdropTop: entry.backdropTop,
                backdropBottom: entry.backdropBottom,
                drawShadow: panel.hasShadow,
                to: fullFile
            )

            // Write 2x zoomed top-edge & top-left corner strip (top 96pt of window + 24pt backdrop above)
            let zoomFile = outputDir.appendingPathComponent("panel-\(entry.name)-top-zoom.png")
            try writeTopEdgeZoomPNG(
                fullImageURL: fullFile,
                canvasSize: canvasSize,
                pad: pad,
                cropHeightPts: 112,
                to: zoomFile
            )

            let subviews = frameView.subviews.map { sv in
                PanelChromeSubviewSnapshot(
                    className: NSStringFromClass(type(of: sv)),
                    frameInWindow: NSStringFromRect(sv.frame),
                    isHidden: sv.isHidden,
                    alphaValue: Double(sv.alphaValue)
                )
            }
            let titlebarCount = subviews.filter { $0.className.contains("Titlebar") }.count
            let bgAlpha = Double(panel.backgroundColor.usingColorSpace(.deviceRGB)?.alphaComponent ?? panel.backgroundColor.alphaComponent)
            let safe = cv.safeAreaInsets

            themeResults.append(PanelChromeThemeMetrics(
                theme: entry.name,
                styleMaskRawValue: panel.styleMask.rawValue,
                isTitled: panel.styleMask.contains(.titled),
                isBorderless: !panel.styleMask.contains(.titled),
                isFullSizeContentView: panel.styleMask.contains(.fullSizeContentView),
                isResizable: panel.styleMask.contains(.resizable),
                isNonActivatingPanel: panel.styleMask.contains(.nonactivatingPanel),
                isOpaque: panel.isOpaque,
                hasShadow: panel.hasShadow,
                backgroundColorAlpha: bgAlpha,
                windowFrame: NSStringFromRect(panel.frame),
                contentLayoutRect: NSStringFromRect(panel.contentLayoutRect),
                contentViewFrame: NSStringFromRect(cv.frame),
                contentViewSafeAreaTop: Double(safe.top),
                contentViewSafeAreaBottom: Double(safe.bottom),
                contentViewSafeAreaLeft: Double(safe.left),
                contentViewSafeAreaRight: Double(safe.right),
                frameViewClassName: NSStringFromClass(type(of: frameView)),
                frameViewSubviews: subviews,
                titlebarSubviewCount: titlebarCount,
                firstHighAlphaRowAtMidXFromTop: firstHighAlpha,
                topBorderGapPtsAtMidX: firstHighAlpha,
                topRowsSample: topRows,
                fullImagePath: fullFile.path,
                topEdgeZoomImagePath: zoomFile.path
            ))
        }

        let report = PanelChromeSnapshotReport(
            generatedAt: Date(),
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            isolatedTemporaryStore: true,
            nonPersistentWebDataStore: true,
            themes: themeResults
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(report)
        let jsonFile = outputDir.appendingPathComponent("panel-chrome-metrics.json")
        try jsonData.write(to: jsonFile, options: .atomic)
        print(jsonFile.path)
        return report
    }

    private static func writeCompositedPNG(
        capturedRep: NSBitmapImageRep,
        windowSize: NSSize,
        canvasSize: NSSize,
        pad: CGFloat,
        backdropTop: NSColor,
        backdropBottom: NSColor,
        drawShadow: Bool,
        to fileURL: URL
    ) throws {
        let scale = 2
        let pixW = Int(canvasSize.width) * scale
        let pixH = Int(canvasSize.height) * scale
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixW,
            pixelsHigh: pixH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: pixW * 4,
            bitsPerPixel: 32
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw NSError(domain: "PanelChromeSnapshot", code: 4, userInfo: [NSLocalizedDescriptionKey: "Failed to create composite bitmap"])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        // Contrasting desktop gradient backdrop
        let grad = NSGradient(starting: backdropBottom, ending: backdropTop)
        grad?.draw(in: NSRect(origin: .zero, size: canvasSize), angle: 90)

        let dstRect = NSRect(x: pad, y: pad, width: windowSize.width, height: windowSize.height)
        let capturedImg = NSImage(size: windowSize)
        capturedImg.addRepresentation(capturedRep)

        if drawShadow {
            ctx.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = 18
            shadow.shadowOffset = NSSize(width: 0, height: -6)
            shadow.set()
            capturedImg.draw(in: dstRect, from: .zero, operation: .sourceOver, fraction: 1.0)
            ctx.restoreGraphicsState()
        } else {
            capturedImg.draw(in: dstRect, from: .zero, operation: .sourceOver, fraction: 1.0)
        }

        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PanelChromeSnapshot", code: 5, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        try png.write(to: fileURL, options: .atomic)
    }

    private static func writeTopEdgeZoomPNG(
        fullImageURL: URL,
        canvasSize: NSSize,
        pad: CGFloat,
        cropHeightPts: CGFloat,
        to fileURL: URL
    ) throws {
        guard let srcImg = NSImage(contentsOf: fullImageURL) else { return }
        let zoomFactor: CGFloat = 2.0
        let cropWidthPts = min(canvasSize.width, 520)
        let outW = Int((cropWidthPts * zoomFactor).rounded())
        let outH = Int((cropHeightPts * zoomFactor).rounded())
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: outW,
            pixelsHigh: outH,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: outW * 4,
            bitsPerPixel: 32
        ), let ctx = NSGraphicsContext(bitmapImageRep: rep) else {
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .none
        let imgScaleX = srcImg.size.width / max(1.0, canvasSize.width)
        let imgScaleY = srcImg.size.height / max(1.0, canvasSize.height)
        let srcRect = NSRect(
            x: max(0, pad - 16) * imgScaleX,
            y: (canvasSize.height - cropHeightPts) * imgScaleY,
            width: cropWidthPts * imgScaleX,
            height: cropHeightPts * imgScaleY
        )
        srcImg.draw(
            in: NSRect(x: 0, y: 0, width: CGFloat(outW), height: CGFloat(outH)),
            from: srcRect,
            operation: .copy,
            fraction: 1.0
        )
        ctx.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        if let png = rep.representation(using: .png, properties: [:]) {
            try png.write(to: fileURL, options: .atomic)
        }
    }
}
