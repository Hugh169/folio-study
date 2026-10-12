import SwiftUI

/// Adds a subject with a name and a colour.
struct NewSubjectSheet: View {
    struct Swatch {
        /// The colour's name, for VoiceOver.
        let name: LocalizedStringResource
        let hex: UInt32
    }

    static let palette = [
        Swatch(name: "Blue", hex: 0x0A84FF),
        Swatch(name: "Orange", hex: 0xFF9F0A),
        Swatch(name: "Teal", hex: 0x40C8E0),
        Swatch(name: "Purple", hex: 0xBF5AF2),
        Swatch(name: "Pink", hex: 0xFF6482),
        Swatch(name: "Green", hex: 0x30D158),
        Swatch(name: "Yellow", hex: 0xFFD60A),
        Swatch(name: "Indigo", hex: 0x5E5CE6),
        Swatch(name: "Red", hex: 0xFF453A),
        Swatch(name: "Brown", hex: 0xAC8E68),
        Swatch(name: "Mint", hex: 0x66D4CF),
        Swatch(name: "Grey", hex: 0x8E8E93),
    ]

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var selection = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Subject")
                .font(.system(size: 17, weight: .semibold))

            TextField("Name", text: $name, prompt: Text("e.g. Biology"))
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)

            VStack(alignment: .leading, spacing: 6) {
                TextField("What it covers", text: $summary, prompt: Text("e.g. Cells, genetics, ecology and the human body"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Text("A few topics help Folio recognise this subject's files.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Colour")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.secondaryText)
                HStack(spacing: 6) {
                    ForEach(Self.palette.indices, id: \.self) { index in
                        Button {
                            selection = index
                        } label: {
                            Circle()
                                .fill(Color(hex: Self.palette[index].hex))
                                .frame(width: 22, height: 22)
                                .padding(4)
                                .overlay {
                                    if index == selection {
                                        Circle().strokeBorder(Color.white, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(Self.palette[index].name))
                        .accessibilityAddTraits(index == selection ? .isSelected : [])
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Subject", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .onAppear {
            // Start on a colour no other subject uses.
            selection = Self.palette.firstIndex { swatch in
                !model.subjects.contains { $0.colorHex == swatch.hex }
            } ?? 0
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func add() {
        guard !trimmedName.isEmpty else { return }
        model.addSubject(
            named: trimmedName,
            colorHex: Self.palette[selection].hex,
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        dismiss()
    }
}
