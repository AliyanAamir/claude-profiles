import ClaudeProfilesCore
import SwiftUI

extension ProfileColor {
    var color: Color {
        switch self {
        case .orange: return .orange
        case .red: return .red
        case .pink: return .pink
        case .purple: return .purple
        case .indigo: return .indigo
        case .blue: return .blue
        case .teal: return .teal
        case .green: return .green
        case .yellow: return .yellow
        case .gray: return .gray
        }
    }
}

/// Runtime state of a profile as shown in the UI.
enum ProfileRunState: Equatable {
    case stopped, starting, running, stopping, outdated

    var title: String {
        switch self {
        case .stopped: return "Not Running"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Quitting…"
        case .outdated: return "Restart to Update"
        }
    }

    var tint: Color {
        switch self {
        case .stopped: return .secondary
        case .starting, .stopping: return .accentColor
        case .running: return .green
        case .outdated: return .orange
        }
    }

    var isActive: Bool { self == .running || self == .outdated }
}

extension AppModel {
    func state(of profile: Profile) -> ProfileRunState {
        let running = isRunning(profile)
        if isBusy(profile) { return running ? .stopping : .starting }
        if running { return isOutdated(profile) ? .outdated : .running }
        return .stopped
    }
}

struct ProfileBadge: View {
    let profile: Profile
    var size: CGFloat = 44
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let base = profile.color.color
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [base.mix(with: .white, by: 0.28), base, base.mix(with: .black, by: 0.18)],
                                     startPoint: .top, endPoint: .bottom))
            Circle()
                .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                .padding(size * 0.06)
                .blendMode(.plusLighter)
            Circle()
                .strokeBorder(.black.opacity(contrast == .increased ? 0.45 : 0.12), lineWidth: max(0.5, size / 64))
            if let emoji = profile.emoji {
                Text(emoji).font(.system(size: size * 0.5))
            } else {
                Text(profile.initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: size / 60, y: size / 80)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: base.opacity(size > 30 ? 0.35 : 0), radius: size / 10, y: size / 20)
        .accessibilityHidden(true)
    }
}

/// A native-feeling status indicator: SF Symbol with a soft halo and pulse while running.
struct StatusIndicator: View {
    let state: ProfileRunState
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if compact {
            symbol.font(.system(size: 7))
                .help(state.title)
                .accessibilityLabel(state.title)
        } else {
            HStack(spacing: 5) {
                if state == .starting || state == .stopping {
                    ProgressView().controlSize(.mini)
                } else {
                    symbol.font(.system(size: 7))
                }
                Text(state.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state == .stopped ? .secondary : state.tint)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(state.tint.opacity(state == .stopped ? 0.08 : 0.13)))
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var symbol: some View {
        let image = Image(systemName: state.isActive ? "circle.fill" : "circle")
            .foregroundStyle(state.tint)
            .shadow(color: state.isActive ? state.tint.opacity(0.7) : .clear, radius: 2.5)
        if state.isActive && !reduceMotion {
            image.symbolEffect(.pulse, options: .repeating.speed(0.4))
        } else {
            image
        }
    }
}

struct ProfileCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let profile: Profile
    let index: Int
    var onShowDetails: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        let state = model.state(of: profile)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                ProfileBadge(profile: profile, size: 46)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(profile.name).font(.title3.weight(.semibold)).lineLimit(1)
                        if profile.isDefault {
                            Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                                .help("Built-in profile using Claude's own data folder")
                        }
                    }
                    StatusIndicator(state: state)
                }
                Spacer(minLength: 0)
                Menu {
                    ProfileMenuItems(profile: profile)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .opacity(hovering ? 1 : 0.55)
                .help("More Actions")
            }

            VStack(alignment: .leading, spacing: 4) {
                InfoLine(symbol: "folder", text: profile.isDefault ? "Claude's own data folder" : (profile.dataDirectory as NSString).abbreviatingWithTildeInPath)
                InfoLine(symbol: "clock", text: lastUsedText(state))
            }

            HStack(spacing: 8) {
                Button {
                    model.primaryAction(profile)
                } label: {
                    Label(state.isActive ? "Open" : "Launch", systemImage: state.isActive ? "macwindow" : "play.fill")
                        .frame(minWidth: 74)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state == .starting || state == .stopping || model.isUpdating)

                if state.isActive {
                    Button("Quit") { model.quit(profile) }
                        .controlSize(.large)
                        .disabled(model.isUpdating)
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
                Spacer(minLength: 0)
                if index < 9 {
                    Text("⌘\(index + 1)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .help("Press ⌘\(index + 1) to launch or open this profile")
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(hovering: hovering, active: state.isActive, tint: profile.color.color))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(borderColor(state), lineWidth: contrast == .increased ? 1.5 : 1)
        }
        .scaleEffect(hovering && !reduceMotion ? 1.008 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.8), value: state)
        .animation(reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.85), value: hovering)
        .onHover { hovering = $0 }
        .contextMenu { ProfileMenuItems(profile: profile) }
        .onTapGesture(count: 2) { model.primaryAction(profile) }
        .onTapGesture { onShowDetails() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(profile.name), \(state.title)")
    }

    private func borderColor(_ state: ProfileRunState) -> Color {
        if contrast == .increased { return .primary.opacity(0.5) }
        return state.isActive ? profile.color.color.opacity(0.45) : Color.primary.opacity(0.08)
    }

    private func lastUsedText(_ state: ProfileRunState) -> String {
        if state.isActive, let inst = model.instances(for: profile).last {
            let version = inst.launchedVersion.map { "Claude \($0)" } ?? "an older Claude"
            return "Started \(inst.startTime.formatted(.relative(presentation: .named))) · \(version)"
        }
        if let last = profile.lastLaunchedAt { return "Last used \(last.formatted(.relative(presentation: .named)))" }
        return "Never launched from Claude Profiles"
    }
}

struct InfoLine: View {
    let symbol: String
    let text: String
    var body: some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol).frame(width: 14)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

struct CardBackground: View {
    let hovering: Bool
    let active: Bool
    let tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        ZStack {
            shape.fill(scheme == .dark ? Color(nsColor: .controlBackgroundColor).opacity(0.85) : Color(nsColor: .controlBackgroundColor))
            if active {
                shape.fill(LinearGradient(colors: [tint.opacity(scheme == .dark ? 0.14 : 0.08), .clear],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.35 : (hovering ? 0.10 : 0.06)), radius: hovering ? 12 : 6, y: hovering ? 5 : 2)
    }
}

struct ProfileMenuItems: View {
    @EnvironmentObject private var model: AppModel
    let profile: Profile

    var body: some View {
        let running = model.isRunning(profile)
        Button { model.primaryAction(profile) } label: {
            Label(running ? "Open" : "Launch", systemImage: running ? "macwindow" : "play")
        }
        Button { model.signIn(profile) } label: { Label("Sign In…", systemImage: "person.badge.key") }
        if running {
            Button { model.restart(profile) } label: { Label("Restart", systemImage: "arrow.clockwise") }
            Button { model.quit(profile) } label: { Label("Quit", systemImage: "xmark.circle") }
        }
        Divider()
        Button { model.editorRequest = EditorRequest(profile: profile) } label: { Label("Edit…", systemImage: "pencil") }
        Menu {
            Picker("Color", selection: Binding(get: { profile.color }, set: { model.setColor(profile, $0) })) {
                ForEach(ProfileColor.allCases, id: \.self) { c in Text(c.displayName).tag(c) }
            }
            .pickerStyle(.inline)
        } label: { Label("Color", systemImage: "paintpalette") }
        Button { model.duplicateAsEmpty(profile) } label: { Label("Duplicate as Empty Profile", systemImage: "plus.square.on.square") }
        Button { model.revealDataDirectory(profile) } label: { Label("Show Data Folder in Finder", systemImage: "folder") }
        if !profile.isDefault {
            Divider()
            Button(role: .destructive) { model.requestDelete(profile) } label: { Label("Delete…", systemImage: "trash") }
                .disabled(running)
        }
    }
}

// MARK: - Detail

struct ProfileDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let profile: Profile

    var body: some View {
        let state = model.state(of: profile)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                BannerStack()
                HStack(alignment: .center, spacing: 18) {
                    ProfileBadge(profile: profile, size: 76)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(profile.name).font(.largeTitle.weight(.semibold))
                        StatusIndicator(state: state)
                    }
                    Spacer()
                }
                HStack(spacing: 10) {
                    Button { model.primaryAction(profile) } label: {
                        Label(state.isActive ? "Open" : "Launch", systemImage: state.isActive ? "macwindow" : "play.fill").frame(minWidth: 80)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(state == .starting || state == .stopping || model.isUpdating)
                    Button { model.signIn(profile) } label: { Label("Sign In…", systemImage: "person.badge.key") }.controlSize(.large)
                    if state.isActive {
                        Button { model.restart(profile) } label: { Label("Restart", systemImage: "arrow.clockwise") }.controlSize(.large)
                        Button { model.quit(profile) } label: { Label("Quit", systemImage: "xmark") }.controlSize(.large)
                    }
                    Spacer()
                    Button { model.editorRequest = EditorRequest(profile: profile) } label: { Label("Edit", systemImage: "pencil") }
                        .controlSize(.large)
                }
                .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85), value: state)

                GroupBox {
                    VStack(spacing: 0) {
                        DetailRow(title: "Data folder", value: profile.isDefault ? "Claude's own data folder" : (profile.dataDirectory as NSString).abbreviatingWithTildeInPath) {
                            Button("Show in Finder") { model.revealDataDirectory(profile) }.buttonStyle(.link)
                        }
                        Divider()
                        DetailRow(title: "Claude version", value: versionText)
                        Divider()
                        DetailRow(title: "Created", value: profile.createdAt.formatted(date: .abbreviated, time: .shortened))
                        Divider()
                        DetailRow(title: "Last launched", value: profile.lastLaunchedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                        if let pids = pidText {
                            Divider()
                            DetailRow(title: "Process", value: pids)
                        }
                    }
                }
                Text(profile.isDefault
                     ? "The Default profile is the Claude you already use. It launches exactly like opening Claude normally and can't be deleted here."
                     : "This profile keeps its own sign-in, chats, settings and MCP configuration in its data folder. It runs the same Claude app as every other profile, so updates apply to all of them.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(28)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .background(DetailBackground())
    }

    private var versionText: String {
        if let inst = model.instances(for: profile).last {
            return inst.launchedVersion.map { "\($0) (running)" } ?? "Older version (running) · restart to update"
        }
        return model.installation?.version.map { "\($0) (installed)" } ?? "—"
    }

    private var pidText: String? {
        let pids = model.instances(for: profile).map { String($0.pid) }
        return pids.isEmpty ? nil : "PID " + pids.joined(separator: ", ")
    }
}

struct DetailRow<Trailing: View>: View {
    let title: String
    let value: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
    }
}

extension DetailRow where Trailing == EmptyView {
    init(title: String, value: String) {
        self.init(title: title, value: value) { EmptyView() }
    }
}
