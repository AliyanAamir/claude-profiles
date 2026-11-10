import ClaudeProfilesCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage(SettingsKey.checkInterval) private var checkInterval = 3600.0
    @AppStorage(SettingsKey.autoRestartIdle) private var autoRestartIdle = false
    @AppStorage(SettingsKey.routeLinks) private var routeLinks = true

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch Claude Profiles at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.launchAtLogin = $0 }))
            }
            Section("Updates") {
                Picker("Check for Claude updates", selection: $checkInterval) {
                    Text("Every 15 minutes").tag(900.0)
                    Text("Every hour").tag(3600.0)
                    Text("Every 6 hours").tag(21600.0)
                    Text("Daily").tag(86400.0)
                    Text("Never").tag(0.0)
                }
                Toggle("Restart idle profiles automatically after Claude updates", isOn: $autoRestartIdle)
                Text("A profile counts as idle when its window hasn't been in front for 10 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Check Now") { Task { await model.checkForUpdates(userInitiated: true) } }
                    if let date = model.lastCheck {
                        Text("Last checked \(date.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Sign-in links") {
                Toggle("Route sign-in links to the profile you're signing in to", isOn: $routeLinks)
                    .onChange(of: routeLinks) { _, on in
                        if !on { Task { await model.restoreClaudeAsURLHandler() } }
                    }
                Text("With several profiles open, macOS sends claude:// links (like sign-in callbacks) to the oldest Claude window. When you choose Sign In… on a profile, Claude Profiles takes over claude:// links and forwards each one to that profile's window. macOS may ask you once to confirm using Claude Profiles for claude links.")
                    .font(.caption).foregroundStyle(.secondary)
                if let last = model.lastRoute {
                    Text("Last: \(last)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("About") {
                Text("Claude Profiles is an unofficial helper. It launches the official Claude app from /Applications with a separate data folder for each profile. Not affiliated with Anthropic.")
                    .font(.callout).foregroundStyle(.secondary)
                Button("Open Profiles Folder") { NSWorkspace.shared.open(model.paths.supportDirectory) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Profiles") {
            ForEach(Array(model.profiles.enumerated()), id: \.element.id) { index, profile in
                let state = model.state(of: profile)
                Button {
                    model.primaryAction(profile)
                } label: {
                    Label {
                        Text(profile.name) + Text(state.isActive ? "  Running" : "").foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: state.isActive ? "circle.fill" : "circle")
                    }
                }
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1)))) : nil)
            }
        }
        Section("Claude") {
            switch model.updateStatus {
            case .available(_, let latest):
                Button { model.updateAllProfiles() } label: {
                    Label("Update All Profiles to \(latest.version)", systemImage: "arrow.down.circle")
                }
                .disabled(model.isUpdating)
            case .upToDate(let v):
                Label("Claude \(v) Is Up to Date", systemImage: "checkmark.seal")
            case .claudeMissing:
                Button { NSWorkspace.shared.open(ClaudeConstants.downloadPageURL) } label: {
                    Label("Download Claude…", systemImage: "exclamationmark.triangle")
                }
            case .unknown:
                Button { Task { await model.checkForUpdates(userInitiated: true) } } label: {
                    Label("Check for Updates", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let p = model.updateProgress {
                Label(p.title, systemImage: "hourglass")
            }
            if !model.outdatedInstances.isEmpty {
                Button { model.restartOutdated() } label: {
                    Label("Restart \(model.outdatedInstances.count) Outdated Profile(s)", systemImage: "arrow.clockwise")
                }
            }
        }
        Divider()
        Button("Launch All") { model.launchAll() }
            .disabled(model.claudeMissing)
        Button("Quit All Profiles") { model.quitAll() }
            .disabled(model.instances.isEmpty)
        Divider()
        Button("Open Claude Profiles") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Claude Profiles") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
