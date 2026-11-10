import AppKit
import ClaudeProfilesCore
import SwiftUI

@main
struct ClaudeProfilesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Claude Profiles", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 500)
        }
        .defaultSize(width: 980, height: 640)
        .windowToolbarStyle(.unified)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.outdatedInstances.isEmpty && !isUpdateAvailable ? "person.2" : "person.2.badge.gearshape.fill")
        }
    }

    private var isUpdateAvailable: Bool {
        if case .available = model.updateStatus { return true }
        return false
    }
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Claude Profiles") { AppDelegate.showAbout() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Profile…") {
                openWindow(id: "main")
                model.editorRequest = EditorRequest(profile: nil)
            }
            .keyboardShortcut("n")
        }
        CommandMenu("Profiles") {
            ForEach(Array(model.profiles.prefix(9).enumerated()), id: \.element.id) { index, profile in
                Button("\(model.isRunning(profile) ? "Open" : "Launch") \(profile.name)") {
                    model.launchProfile(atIndex: index)
                }
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider()
            Button("Launch All") { model.launchAll() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Quit All Profiles") { model.quitAll() }
                .keyboardShortcut("q", modifiers: [.command, .option])
            Divider()
            Button("Check for Claude Updates") { Task { await model.checkForUpdates(userInitiated: true) } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
        }
    }
}
