import ClaudeProfilesCore
import SwiftUI

struct Banner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var message: String?
    @ViewBuilder var actions: () -> Actions
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                if let message {
                    Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            actions()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint.opacity(0.07))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(contrast == .increased ? 0.8 : 0.25), lineWidth: 1)
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct BannerStack: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 10) {
            if let progress = model.updateProgress {
                Banner(symbol: "arrow.down.circle", tint: .accentColor, title: progress.title, message: progress.detail ?? progressDetail(progress)) {
                    HStack(spacing: 10) {
                        Group {
                            if let f = progress.fraction {
                                ProgressView(value: f)
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                        }
                        .frame(width: 170)
                        if progress.cancellable { Button("Cancel") { model.cancelUpdate() } }
                    }
                }
            } else if case .available(let installed, let latest) = model.updateStatus {
                Banner(symbol: "arrow.down.circle.fill", tint: .accentColor,
                       title: "Claude \(latest.version) Is Available",
                       message: "You have \(installed). Updating quits running profiles, installs the verified official build, then reopens the same profiles.") {
                    Button("Update All Profiles") { model.updateAllProfiles() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }

            if let failure = model.updateFailure {
                Banner(symbol: "exclamationmark.octagon.fill", tint: .red, title: "Update Didn't Complete",
                       message: failure + " Your previous version of Claude is still installed.") {
                    HStack {
                        Button("Let Claude Update Itself") { model.updateViaClaudeUpdater() }
                        Button("Try Again") { model.updateAllProfiles() }.buttonStyle(.borderedProminent)
                    }
                }
            }

            let outdated = model.outdatedInstances
            if !outdated.isEmpty && model.updateProgress == nil {
                Banner(symbol: "clock.arrow.circlepath", tint: .orange,
                       title: "\(outdated.count) Profile\(outdated.count == 1 ? " Is" : "s Are") Running an Older Version",
                       message: "Claude \(model.installation?.version?.string ?? "") is installed. Restart to switch over.") {
                    Button("Restart Them") { model.restartOutdated() }.buttonStyle(.borderedProminent).tint(.orange)
                }
            }

            if let id = model.signingInProfileID, let profile = model.profiles.first(where: { $0.id == id }) {
                Banner(symbol: "person.badge.key.fill", tint: .purple, title: "Signing In to “\(profile.name)”",
                       message: "Sign-in links from your browser will open in this profile's Claude window.") {
                    Button("Done") { model.cancelSignIn() }
                }
            }

            if let notice = model.transientNotice {
                Banner(symbol: "info.circle.fill", tint: .secondary, title: notice) { EmptyView() }
            }

            if let error = model.errorMessage {
                Banner(symbol: "exclamationmark.triangle.fill", tint: .yellow, title: "Something Needs Attention", message: error) {
                    Button("Dismiss") { model.errorMessage = nil }
                }
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: model.updateProgress)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: model.errorMessage)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: model.transientNotice)
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.9), value: model.signingInProfileID)
    }

    private func progressDetail(_ p: UpdateProgress) -> String? {
        guard let f = p.fraction else { return nil }
        if let size = model.latestRelease?.size {
            let done = ByteCountFormatter.string(fromByteCount: Int64(Double(size) * f), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            return "\(done) of \(total)"
        }
        return "\(Int(f * 100))%"
    }
}
