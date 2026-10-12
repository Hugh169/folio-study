import AppKit
import SwiftUI

/// The first thing a new student sees: what Folio does, and an optional name
/// for Folio to call them. There's no account; everything stays on this Mac.
/// Someone moving to a new Mac can restore a backup instead.
struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    @Bindable var setup: SetupModel
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            // Brand pane
            VStack(alignment: .leading, spacing: 28) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 104, height: 104)
                    .padding(-8)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your schoolwork, sorted.")
                        .font(.system(size: 40, weight: .semibold))
                        .frame(maxWidth: 420, alignment: .leading)
                        .accessibilityAddTraits(.isHeader)
                    Text("Drop files in and Folio files them by subject, then helps you plan when to study.")
                        .font(.system(size: 17))
                        .lineSpacing(4)
                        .foregroundStyle(Theme.primaryText.opacity(0.65))
                        .frame(maxWidth: 380, alignment: .leading)
                }
            }
            .padding(.horizontal, 64)
            .padding(.vertical, 64)
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color(hex: 0x151517))

            // Getting started
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Folio")
                        .font(.system(size: 26, weight: .semibold))
                    Text("Setting up takes about a minute.")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.secondaryText)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("What should Folio call you?")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.primaryText.opacity(0.7))
                    TextField("Name", text: $setup.studentName, prompt: Text("Your name (optional)"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .focused($nameFocused)
                        .padding(.horizontal, 14)
                        .frame(height: 44)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(nameFocused ? 0.09 : 0.07)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(nameFocused ? Theme.accent : .clear, lineWidth: 1))
                        .onSubmit(start)
                        .textContentType(.name)
                }

                Button(action: start) {
                    Text("Get Started").frame(maxWidth: .infinity)
                }
                .buttonStyle(FilledButtonStyle(kind: .primary, fullWidth: true, isLarge: true))
                .keyboardShortcut(.defaultAction)

                Button("Restore from a Backup…") { model.chooseAndRestoreBackup() }
                    .buttonStyle(.folioLink)
                    .frame(maxWidth: .infinity)

                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "lock")
                    Text("No account needed. Your files and settings stay on this Mac.")
                }
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
            }
            .frame(width: 380)
            .padding(.horizontal, 56)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { nameFocused = true }
    }

    private func start() {
        withAnimation(Theme.motion()) {
            setup.showsWelcome = false
        }
    }
}
