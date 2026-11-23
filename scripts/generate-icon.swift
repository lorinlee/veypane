#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Reproducible clean-room vector icon generator for Veypane.
// Renders an original macOS continuous-squircle icon in pure CoreGraphics:
// - Deep indigo -> twilight violet -> lilac squircle canvas with specular rim light
// - Softly lit frosted glass slide-over panel on the right edge
// - Stylized warm-gold & mint-emerald wing swoosh gliding into the panel
// Produces all 10 macOS .iconset sizes (16..1024 px), compiles Veypane.icns via iconutil,
// and writes a 1024x1024 PNG preview at Assets/AppIcon/Veypane-1024.png.

func makeSRGBColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1.0) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

/// Builds a smooth macOS-style rounded squircle path inside `rect`.
func makeSquirclePath(in rect: CGRect, cornerRadius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
}

func renderVeypaneIcon(pixelSize: Int) -> CGImage {
    let s = CGFloat(pixelSize)
    let scale = s / 1024.0
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

    guard let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: pixelSize * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        fatalError("Failed to allocate CGContext for \(pixelSize)x\(pixelSize)")
    }

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    // Clear transparent canvas
    ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

    // Standard macOS icon canvas proportions (832x832 inside 1024x1024, corner radius ~186)
    let margin = 96.0 * scale
    let cardSide = s - margin * 2.0
    let cardRect = CGRect(x: margin, y: margin, width: cardSide, height: cardSide)
    let cardRadius = 186.0 * scale
    let squirclePath = makeSquirclePath(in: cardRect, cornerRadius: cardRadius)

    // 1. Ambient outer shadow (for sizes >= 64)
    if pixelSize >= 64 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -14.0 * scale),
            blur: 28.0 * scale,
            color: makeSRGBColor(0.06, 0.05, 0.16, 0.42)
        )
        ctx.addPath(squirclePath)
        ctx.setFillColor(makeSRGBColor(0.14, 0.13, 0.34, 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // 2. Clip to squircle and paint indigo -> violet -> lilac gradient background
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    let bgGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            makeSRGBColor(0.11, 0.13, 0.33, 1.0), // Deep night indigo (bottom-left)
            makeSRGBColor(0.24, 0.21, 0.60, 1.0), // Rich royal indigo (center)
            makeSRGBColor(0.53, 0.39, 0.94, 1.0)  // Luminous lilac-violet (top-right)
        ] as CFArray,
        locations: [0.0, 0.52, 1.0]
    )!
    ctx.drawLinearGradient(
        bgGradient,
        start: CGPoint(x: cardRect.minX, y: cardRect.minY),
        end: CGPoint(x: cardRect.maxX, y: cardRect.maxY),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )

    // Soft aurora glow behind the right glass panel
    let glowGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            makeSRGBColor(0.68, 0.58, 1.0, 0.42),
            makeSRGBColor(0.32, 0.85, 0.75, 0.18),
            makeSRGBColor(0.24, 0.21, 0.60, 0.0)
        ] as CFArray,
        locations: [0.0, 0.48, 1.0]
    )!
    ctx.drawRadialGradient(
        glowGradient,
        startCenter: CGPoint(x: cardRect.minX + cardSide * 0.68, y: cardRect.minY + cardSide * 0.62),
        startRadius: 0,
        endCenter: CGPoint(x: cardRect.minX + cardSide * 0.68, y: cardRect.minY + cardSide * 0.62),
        endRadius: cardSide * 0.58,
        options: [.drawsBeforeStartLocation]
    )

    // 3. Softly lit floating glass side-panel on the right side of the squircle
    let panelInsetRight = 56.0 * scale
    let panelInsetVert = 78.0 * scale
    let panelWidth = cardSide * 0.43
    let panelHeight = cardSide - panelInsetVert * 2.0
    let panelRect = CGRect(
        x: cardRect.maxX - panelInsetRight - panelWidth,
        y: cardRect.minY + panelInsetVert,
        width: panelWidth,
        height: panelHeight
    )
    let panelRadius = 64.0 * scale
    let panelPath = CGPath(roundedRect: panelRect, cornerWidth: panelRadius, cornerHeight: panelRadius, transform: nil)

    // Panel subtle drop shadow onto squircle canvas
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: -10.0 * scale, height: -8.0 * scale),
        blur: 24.0 * scale,
        color: makeSRGBColor(0.05, 0.04, 0.18, 0.36)
    )
    ctx.addPath(panelPath)
    ctx.setFillColor(makeSRGBColor(1.0, 1.0, 1.0, 0.10))
    ctx.fillPath()
    ctx.restoreGState()

    // Frosted glass panel fill
    ctx.saveGState()
    ctx.addPath(panelPath)
    ctx.clip()
    let glassGradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            makeSRGBColor(1.0, 1.0, 1.0, 0.30),
            makeSRGBColor(0.88, 0.90, 1.0, 0.14)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        glassGradient,
        start: CGPoint(x: panelRect.minX, y: panelRect.maxY),
        end: CGPoint(x: panelRect.maxX, y: panelRect.minY),
        options: []
    )

    // Subtle rail divider + luminous rail dots inside the glass panel (at >= 64px)
    if pixelSize >= 64 {
        let railX = panelRect.minX + panelWidth * 0.22
        ctx.setStrokeColor(makeSRGBColor(1.0, 1.0, 1.0, 0.22))
        ctx.setLineWidth(max(1.0, 3.0 * scale))
        ctx.move(to: CGPoint(x: railX, y: panelRect.minY + 36.0 * scale))
        ctx.addLine(to: CGPoint(x: railX, y: panelRect.maxY - 36.0 * scale))
        ctx.strokePath()

        let dotX = panelRect.minX + panelWidth * 0.11
        let dotR = 11.0 * scale
        let dotOffsets: [(CGFloat, CGColor)] = [
            (0.78, makeSRGBColor(0.38, 0.93, 0.76, 0.90)),
            (0.65, makeSRGBColor(1.0, 1.0, 1.0, 0.55)),
            (0.52, makeSRGBColor(1.0, 1.0, 1.0, 0.35))
        ]
        for (frac, col) in dotOffsets {
            let cy = panelRect.minY + panelHeight * frac
            ctx.setFillColor(col)
            ctx.fillEllipse(in: CGRect(x: dotX - dotR, y: cy - dotR, width: dotR * 2, height: dotR * 2))
        }
    }
    ctx.restoreGState()

    // Crisp luminous glass border around the slide-over panel
    ctx.saveGState()
    ctx.addPath(panelPath)
    ctx.setStrokeColor(makeSRGBColor(1.0, 1.0, 1.0, 0.48))
    ctx.setLineWidth(max(1.0, 5.5 * scale))
    ctx.strokePath()
    ctx.restoreGState()

    // 4. Stylized Lark Wing / Swoosh gliding from left into the glowing side-panel
    let originX = cardRect.minX
    let originY = cardRect.minY

    // Secondary trailing mint-emerald feather swoosh (all smooth cubic Beziers, no flat chords)
    let mintWing = CGMutablePath()
    mintWing.move(to: CGPoint(x: originX + cardSide * 0.16, y: originY + cardSide * 0.33))
    mintWing.addCurve(
        to: CGPoint(x: originX + cardSide * 0.69, y: originY + cardSide * 0.56),
        control1: CGPoint(x: originX + cardSide * 0.34, y: originY + cardSide * 0.31),
        control2: CGPoint(x: originX + cardSide * 0.54, y: originY + cardSide * 0.40)
    )
    mintWing.addCurve(
        to: CGPoint(x: originX + cardSide * 0.16, y: originY + cardSide * 0.33),
        control1: CGPoint(x: originX + cardSide * 0.53, y: originY + cardSide * 0.30),
        control2: CGPoint(x: originX + cardSide * 0.31, y: originY + cardSide * 0.22)
    )
    mintWing.closeSubpath()

    ctx.saveGState()
    ctx.addPath(mintWing)
    ctx.clip()
    let mintGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            makeSRGBColor(0.12, 0.80, 0.66, 0.96),
            makeSRGBColor(0.52, 0.97, 0.84, 0.98)
        ] as CFArray,
        locations: [0.0, 1.0]
    )!
    ctx.drawLinearGradient(
        mintGrad,
        start: CGPoint(x: originX + cardSide * 0.16, y: originY + cardSide * 0.25),
        end: CGPoint(x: originX + cardSide * 0.69, y: originY + cardSide * 0.56),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // Primary uplifting warm-gold -> champagne lark wing crest (graceful crescent wing)
    let goldWing = CGMutablePath()
    goldWing.move(to: CGPoint(x: originX + cardSide * 0.15, y: originY + cardSide * 0.45))
    goldWing.addCurve(
        to: CGPoint(x: originX + cardSide * 0.78, y: originY + cardSide * 0.75),
        control1: CGPoint(x: originX + cardSide * 0.34, y: originY + cardSide * 0.46),
        control2: CGPoint(x: originX + cardSide * 0.58, y: originY + cardSide * 0.58)
    )
    goldWing.addCurve(
        to: CGPoint(x: originX + cardSide * 0.15, y: originY + cardSide * 0.45),
        control1: CGPoint(x: originX + cardSide * 0.62, y: originY + cardSide * 0.44),
        control2: CGPoint(x: originX + cardSide * 0.34, y: originY + cardSide * 0.30)
    )
    goldWing.closeSubpath()

    if pixelSize >= 64 {
        ctx.saveGState()
        ctx.setShadow(
            offset: CGSize(width: 0, height: -8.0 * scale),
            blur: 20.0 * scale,
            color: makeSRGBColor(0.07, 0.05, 0.20, 0.34)
        )
        ctx.addPath(goldWing)
        ctx.setFillColor(makeSRGBColor(0.98, 0.78, 0.26, 1.0))
        ctx.fillPath()
        ctx.restoreGState()
    }

    ctx.saveGState()
    ctx.addPath(goldWing)
    ctx.clip()
    let goldGrad = CGGradient(
        colorsSpace: colorSpace,
        colors: [
            makeSRGBColor(0.96, 0.64, 0.16, 1.0), // Warm amber-gold
            makeSRGBColor(0.99, 0.84, 0.38, 1.0), // Sunlit lark gold
            makeSRGBColor(1.00, 0.96, 0.80, 1.0)  // Bright champagne wingtip
        ] as CFArray,
        locations: [0.0, 0.58, 1.0]
    )!
    ctx.drawLinearGradient(
        goldGrad,
        start: CGPoint(x: originX + cardSide * 0.15, y: originY + cardSide * 0.36),
        end: CGPoint(x: originX + cardSide * 0.78, y: originY + cardSide * 0.75),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    ctx.restoreGState()

    // 5. Inner squircle specular rim highlight
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.setStrokeColor(makeSRGBColor(1.0, 1.0, 1.0, 0.32))
    ctx.setLineWidth(max(1.0, 4.0 * scale))
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState() // End squircle clip

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw CocoaError(.fileWriteUnknown)
    }
}

let fm = FileManager.default
let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let repoRoot = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
let assetsDir = repoRoot.appendingPathComponent("Assets/AppIcon", isDirectory: true)
let coreResourcesDir = repoRoot.appendingPathComponent("Sources/VeypaneCore/Resources", isDirectory: true)
let iconsetDir = fm.temporaryDirectory.appendingPathComponent("Veypane-\(UUID().uuidString).iconset", isDirectory: true)

try fm.createDirectory(at: assetsDir, withIntermediateDirectories: true)
try fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconsetDir) }

let iconSpecs: [(filename: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

var preview1024: CGImage?
for spec in iconSpecs {
    let rendered = renderVeypaneIcon(pixelSize: spec.pixels)
    if spec.pixels == 1024 {
        preview1024 = rendered
    }
    try writePNG(rendered, to: iconsetDir.appendingPathComponent(spec.filename))
}

let previewURL = assetsDir.appendingPathComponent("Veypane-1024.png")
if let preview1024 {
    try writePNG(preview1024, to: previewURL)
}

let icnsURL = assetsDir.appendingPathComponent("Veypane.icns")
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", icnsURL.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    fputs("iconutil failed with status \(proc.terminationStatus)\n", stderr)
    exit(1)
}

// Copy Veypane.icns into VeypaneCore/Resources as well so About/Welcome views always resolve it
let bundledResourceICNS = coreResourcesDir.appendingPathComponent("Veypane.icns")
if fm.fileExists(atPath: bundledResourceICNS.path) {
    try fm.removeItem(at: bundledResourceICNS)
}
try fm.copyItem(at: icnsURL, to: bundledResourceICNS)

print("Generated \(previewURL.path)")
print("Generated \(icnsURL.path)")
print("Copied \(bundledResourceICNS.path)")
