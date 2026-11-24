import Foundation
import VeypaneCore
import WebKit
import UserNotifications

/// Bridges standard HTML5 `window.Notification` inside `WKWebView` to macOS `UNUserNotificationCenter` (SPEC.md #15).
@MainActor
public final class WebNotificationBridge: NSObject, WKScriptMessageHandler {
    public static let handlerName = "veypaneNotify"

    public static let bootstrapJavaScript = """
    (function() {
        if (window !== window.top) return;
        if (window.__veypaneNotificationsInstalled) return;
        if (typeof window.Notification !== "undefined") return;
        window.__veypaneNotificationsInstalled = true;
        var currentPermission = "default";
        function Notification(title, options) {
            options = options || {};
            this.title = String(title || "");
            this.body = String(options.body || "");
            this.tag = String(options.tag || "");
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.veypaneNotify) {
                    window.webkit.messageHandlers.veypaneNotify.postMessage({
                        type: "notify",
                        title: this.title,
                        body: this.body,
                        tag: this.tag
                    });
                }
            } catch (e) {}
        }
        Object.defineProperty(Notification, "permission", {
            get: function() { return currentPermission; }
        });
        Notification.requestPermission = function(cb) {
            currentPermission = "granted";
            try {
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.veypaneNotify) {
                    window.webkit.messageHandlers.veypaneNotify.postMessage({ type: "requestPermission" });
                }
            } catch (e) {}
            if (typeof cb === "function") { cb(currentPermission); }
            return Promise.resolve(currentPermission);
        };
        Notification.prototype = Object.create(EventTarget.prototype);
        Notification.prototype.constructor = Notification;
        Notification.prototype.close = function() {};
        window.Notification = Notification;
    })();
    """

    public var padTitleProvider: (() -> String)?

    public override init() {
        super.init()
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.name == Self.handlerName,
              let dict = message.body as? [String: Any],
              let type = dict["type"] as? String else {
            return
        }

        // UNUserNotificationCenter requires running inside a signed/bundled .app with a bundle identifier
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else {
            return
        }

        let center = UNUserNotificationCenter.current()
        if type == "requestPermission" {
            center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
            return
        }

        if type == "notify" {
            let rawTitle = (dict["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let body = (dict["body"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawTag = dict["tag"] as? String
            let padLabel = padTitleProvider?() ?? AppBrandIdentity.productName

            center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                guard granted else { return }
                let content = UNMutableNotificationContent()
                content.title = rawTitle.isEmpty ? padLabel : rawTitle
                content.subtitle = rawTitle.isEmpty ? "" : padLabel
                content.body = body
                content.sound = .default

                let id = rawTag.flatMap { $0.isEmpty ? nil : "veypane-\($0)" }
                    ?? "veypane-\(UUID().uuidString)"
                let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
                UNUserNotificationCenter.current().add(req)
            }
        }
    }
}
