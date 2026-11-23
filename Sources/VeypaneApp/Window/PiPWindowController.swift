import AppKit
import SwiftUI
import WebKit
import VeypaneCore

/// Floating always-on-top Picture-in-Picture window for any pad (SPEC.md #20).
@MainActor
public final class PiPWindowController: NSObject, NSWindowDelegate {
    public let padID: UUID
    public let panel: NSPanel
    private let webView: WKWebView
    public var onDockBackToSidebar: ((UUID) -> Void)?

    public init(pad: Pad, webView: WKWebView) {
        self.padID = pad.id
        self.webView = webView

        let rect = NSRect(x: 120, y: 120, width: 400, height: 280)
        let pipPanel = NSPanel(
            contentRect: rect,
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        pipPanel.title = "\(pad.title) — Picture in Picture"
        pipPanel.isFloatingPanel = true
        pipPanel.level = .floating
        pipPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        pipPanel.hidesOnDeactivate = false
        pipPanel.minSize = NSSize(width: 240, height: 160)
        self.panel = pipPanel
        super.init()

        pipPanel.delegate = self

        let container = NSView(frame: rect)
        container.autoresizingMask = [.width, .height]

        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)

        pipPanel.contentView = container
        pipPanel.center()
        pipPanel.orderFrontRegardless()
    }

    public func closeAndReturnWebView() {
        panel.delegate = nil
        webView.removeFromSuperview()
        panel.close()
        onDockBackToSidebar?(padID)
    }

    public func windowWillClose(_ notification: Notification) {
        webView.removeFromSuperview()
        onDockBackToSidebar?(padID)
    }
}
