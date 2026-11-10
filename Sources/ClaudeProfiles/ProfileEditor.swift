import ClaudeProfilesCore
import SwiftUI

struct ProfileEditor: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profile: Profile?

    @State private var name = ""
    @State private var color: ProfileColor = .blue
    @State private var emoji = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                ProfileBadge(profile: preview, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(profile == nil ? "New Profile" : "Edit Profile").font(.title3.weight(.semibold))
                    Text(profile == nil ? "A separate Claude with its own sign-in, chats and settings." : "Changes are saved to profiles.json.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Work"))
                    .focused($nameFocused)
                TextField("Emoji (optional)", text: $emoji, prompt: Text("Initials are used if empty"))
                    .onChange(of: emoji) { _, new in
                        if new.count > 1 { emoji = String(new.prefix(1)) }
                    }
                LabeledContent("Color") {
                    HStack(spacing: 8) {
                        ForEach(ProfileColor.allCases, id: \.self) { c in
                            Button { color = c } label: {
                                Circle().fill(c.color).frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(Color.primary.opacity(c == color ? 0.8 : 0), lineWidth: 2).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(c.displayName)
                            .accessibilityLabel(c.displayName)
                        }
                    }
                }
            }
            .formStyle(.columns)

            if profile?.isDefault == true {
                Text("The Default profile always uses Claude's own data folder.").font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(profile == nil ? "Create" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            if let p = profile {
                name = p.name; color = p.color; emoji = p.emoji ?? ""
            } else {
                color = ProfileColor.allCases.first { c in !model.profiles.contains { $0.color == c } } ?? .blue
            }
            nameFocused = true
        }
    }

    private var preview: Profile {
        Profile(id: "preview", name: name.isEmpty ? "?" : name, color: color, emoji: emoji.isEmpty ? nil : emoji, dataDirectory: "")
    }

    private func save() {
        if let p = profile {
            model.updateProfile(id: p.id, name: name, color: color, emoji: emoji)
        } else {
            model.createProfile(name: name, color: color, emoji: emoji)
        }
        dismiss()
    }
}
