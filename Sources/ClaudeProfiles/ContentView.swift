import ClaudeProfilesCore
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case profile(String)
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection: SidebarItem? = .all
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            Group {
                if model.claudeMissing {
                    ClaudeMissingView()
                } else {
                    switch selection {
                    case .profile(let id):
                        if let profile = model.profiles.first(where: { $0.id == id }) {
                            ProfileDetailView(profile: profile)
                        } else {
                            AllProfilesView(selection: $selection)
                        }
                    default:
                        AllProfilesView(selection: $selection)
                    }
                }
            }
            .frame(minWidth: 480)
        }
        .navigationTitle(navigationTitle)
        .navigationSubtitle(subtitle)
        .toolbar { MainToolbar() }
        .sheet(item: $model.editorRequest) { request in
            ProfileEditor(profile: request.profile)
                .environmentObject(model)
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible, presenting: model.profilePendingDelete) { profile in
            Button("Delete Profile", role: .destructive) {
                if case .profile(profile.id) = selection { selection = .all }
                model.confirmDelete(profile)
            }
            Button("Cancel", role: .cancel) { model.profilePendingDelete = nil }
        } message: { profile in
            Text("“\(profile.name)” will be removed and its data folder moved to the Trash. Its Claude account will be signed out on this Mac.")
        }
        .onChange(of: model.profiles) { _, profiles in
            if case .profile(let id) = selection, !profiles.contains(where: { $0.id == id }) { selection = .all }
        }
    }

    private var navigationTitle: String {
        if case .profile(let id) = selection, let p = model.profiles.first(where: { $0.id == id }) { return p.name }
        return "Claude Profiles"
    }

    private var subtitle: String {
        let running = model.runningProfileCount
        return running == 0 ? "No profiles running" : "\(running) of \(model.profiles.count) running"
    }

    private var deleteTitle: String { "Delete “\(model.profilePendingDelete?.name ?? "")”?" }

    private var deleteBinding: Binding<Bool> {
        Binding(get: { model.profilePendingDelete != nil }, set: { if !$0 { model.profilePendingDelete = nil } })
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Label("All Profiles", systemImage: "square.grid.2x2")
                .tag(SidebarItem.all)

            Section("Profiles") {
                ForEach(model.profiles) { profile in
                    SidebarProfileRow(profile: profile)
                        .tag(SidebarItem.profile(profile.id))
                        .contextMenu { ProfileMenuItems(profile: profile) }
                }
                .onMove { model.moveProfiles(from: $0, to: $1) }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { SidebarFooter() }
    }
}

struct SidebarProfileRow: View {
    @EnvironmentObject private var model: AppModel
    let profile: Profile

    var body: some View {
        HStack(spacing: 9) {
            ProfileBadge(profile: profile, size: 22)
            Text(profile.name).lineLimit(1)
            Spacer(minLength: 4)
            StatusIndicator(state: model.state(of: profile), compact: true)
        }
        .padding(.vertical, 1)
    }
}

struct SidebarFooter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: footerSymbol)
                .foregroundStyle(footerTint)
                .imageScale(.medium)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.installation?.version.map { "Claude \($0)" } ?? "Claude not installed")
                    .font(.callout.weight(.medium))
                Text(footerDetail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var footerSymbol: String {
        switch model.updateStatus {
        case .available: return "arrow.down.circle.fill"
        case .upToDate: return "checkmark.seal.fill"
        case .claudeMissing: return "exclamationmark.triangle.fill"
        case .unknown: return "questionmark.circle"
        }
    }

    private var footerTint: Color {
        switch model.updateStatus {
        case .available: return .accentColor
        case .upToDate: return .green
        case .claudeMissing: return .orange
        case .unknown: return .secondary
        }
    }

    private var footerDetail: String {
        if model.isUpdating { return "Updating…" }
        if model.isChecking { return "Checking for updates…" }
        switch model.updateStatus {
        case .available(_, let latest): return "Version \(latest.version) available"
        case .upToDate: return model.lastCheck.map { "Up to date · checked \($0.formatted(date: .omitted, time: .shortened))" } ?? "Up to date"
        case .claudeMissing: return "Install Claude to continue"
        case .unknown: return model.checkError == nil ? "Not checked yet" : "Update check failed"
        }
    }
}

// MARK: - Toolbar

struct MainToolbar: ToolbarContent {
    @EnvironmentObject private var model: AppModel

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            UpdateToolbarButton()
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.launchAll() } label: { Label("Launch All", systemImage: "play.fill") }
                .help("Launch every profile that isn't running (⇧⌘L)")
                .disabled(model.claudeMissing || model.isUpdating || model.instances.count >= model.profiles.count)
            Button { model.quitAll() } label: { Label("Quit All", systemImage: "stop.fill") }
                .help("Quit every running profile (⌥⌘Q)")
                .disabled(model.instances.isEmpty || model.isUpdating)
        }
        ToolbarItem(placement: .primaryAction) {
            Button { model.editorRequest = EditorRequest(profile: nil) } label: { Label("New Profile", systemImage: "plus") }
                .help("New Profile (⌘N)")
        }
    }
}

struct UpdateToolbarButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Button {
            if case .available = model.updateStatus { model.updateAllProfiles() }
            else { Task { await model.checkForUpdates(userInitiated: true) } }
        } label: {
            Label(title, systemImage: symbol)
        }
        .help(help)
        .disabled(model.isUpdating || model.isChecking || model.claudeMissing)
    }

    private var title: String {
        if case .available(_, let latest) = model.updateStatus { return "Update to \(latest.version)" }
        return "Check for Updates"
    }

    private var symbol: String {
        if case .available = model.updateStatus { return "arrow.down.circle" }
        return "arrow.triangle.2.circlepath"
    }

    private var help: String {
        if case .available(_, let latest) = model.updateStatus { return "Update every profile to Claude \(latest.version)" }
        if let error = model.checkError { return "Last check failed: \(error)" }
        if let date = model.lastCheck { return "Checked \(date.formatted(.relative(presentation: .named))). Click to check again." }
        return "Check Claude's official update feed"
    }
}

// MARK: - All profiles grid

struct AllProfilesView: View {
    @EnvironmentObject private var model: AppModel
    @Binding var selection: SidebarItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let columns = [GridItem(.adaptive(minimum: 260, maximum: 380), spacing: 18)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BannerStack()
                LazyVGrid(columns: columns, alignment: .leading, spacing: 18) {
                    ForEach(model.profiles) { profile in
                        ProfileCard(profile: profile, index: model.profiles.firstIndex(of: profile) ?? 0) {
                            selection = .profile(profile.id)
                        }
                    }
                }
                if model.profiles.count <= 1 {
                    ContentUnavailableView {
                        Label("No Other Profiles Yet", systemImage: "person.2")
                    } description: {
                        Text("Add a profile to sign in to another Claude account. Each profile runs in its own window with separate chats, settings and sign-in.")
                    } actions: {
                        Button("New Profile") { model.editorRequest = EditorRequest(profile: nil) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(24)
            .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85), value: model.profiles)
        }
        .scrollContentBackground(.hidden)
        .background(DetailBackground())
    }
}

struct DetailBackground: View {
    var body: some View {
        Rectangle().fill(.background).ignoresSafeArea()
    }
}

struct ClaudeMissingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContentUnavailableView {
            Label("Claude Isn't Installed", systemImage: "exclamationmark.triangle")
        } description: {
            Text("Claude Profiles launches the official Claude app from /Applications/Claude.app. Install it and this window updates automatically.")
        } actions: {
            Button("Download Claude") { NSWorkspace.shared.open(ClaudeConstants.downloadPageURL) }
                .buttonStyle(.borderedProminent)
            Button("Check Again") { model.refresh() }
        }
    }
}
