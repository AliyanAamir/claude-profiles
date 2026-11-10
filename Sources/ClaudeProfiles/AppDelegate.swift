import AppKit
import ClaudeProfilesCore
import Carbon
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationWillFinishLaunching(_ notification: Notification) {
        // claude:// links (e.g. sign-in callbacks) arrive here when Claude Profiles is the scheme handler.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:withReply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass),
                                                     andEventID: AEEventID(kAEGetURL))
        if let appearance = UserDefaults.standard.string(forKey: "forceAppearance") {
            NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MainActor.assumeIsolated { AppModel.shared.start() }
        if let path = UserDefaults.standard.string(forKey: "snapshot") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { Self.snapshotMainWindow(to: path) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { sender.windows.first { $0.identifier?.rawValue == "main" || $0.title == "Claude Profiles" }?.makeKeyAndOrderFront(nil) }
        return true
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let url = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        MainActor.assumeIsolated {
            if let parsed = URL(string: url), parsed.scheme == "claudeprofiles" {
                AppModel.shared.handleAutomation(parsed)
            } else {
                AppModel.shared.route(url)
            }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    static func showAbout() {
        let credits = NSAttributedString(
            string: "An unofficial helper that launches the official Claude Desktop app with separate data folders, so several accounts can be signed in at once. Not affiliated with or endorsed by Anthropic. Claude is a trademark of Anthropic.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Debug aid used for README screenshots: `ClaudeProfiles -snapshot /path.png [-forceAppearance dark]`.
    static func snapshotMainWindow(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == "main" }) ?? NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) && $0.contentView != nil }),
              let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        frameView.cacheDisplay(in: bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        print("snapshot written to \(path)")
    }
}
