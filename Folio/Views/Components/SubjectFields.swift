import SwiftUI
import FolioKit

/// A subject's colour dot that opens a palette when clicked.
struct ColourDotPicker: View {
    @Binding var colorHex: UInt32
    var size: CGFloat = 14
    @State private var isPicking = false

    var body: some View {
        Button {
            isPicking = true
        } label: {
            Circle()
                .fill(Color(hex: colorHex))
                .frame(width: size, height: size)
                .padding(5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Change colour")
        .accessibilityLabel("Colour")
        .accessibilityValue(Text(NewSubjectSheet.palette.first { $0.hex == colorHex }?.name ?? "Custom"))
        .popover(isPresented: $isPicking, arrowEdge: .bottom) {
            HStack(spacing: 4) {
                ForEach(NewSubjectSheet.palette, id: \.hex) { swatch in
                    Button {
                        colorHex = swatch.hex
                        isPicking = false
                    } label: {
                        Circle()
                            .fill(Color(hex: swatch.hex))
                            .frame(width: 20, height: 20)
                            .padding(3)
                            .overlay {
                                if swatch.hex == colorHex {
                                    Circle().strokeBorder(Color.white, lineWidth: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(swatch.name))
                    .accessibilityAddTraits(swatch.hex == colorHex ? .isSelected : [])
                }
            }
            .padding(10)
        }
    }
}

/// Edits a list of words as comma-separated text, such as "Maths, Math,
/// Mathématiques". The list is updated when you press Return or leave the
/// field, so typing a comma doesn't get tidied away mid-word.
struct CommaListField: View {
    let title: Text
    var prompt: LocalizedStringKey = ""
    @Binding var items: [String]
    @State private var text = ""
    @FocusState private var isFocused: Bool

    init(title: LocalizedStringKey, prompt: LocalizedStringKey = "", items: Binding<[String]>) {
        self.title = Text(title)
        self.prompt = prompt
        _items = items
    }

    /// A field named after something of the student's, such as a kind of document.
    init(verbatimTitle title: String, prompt: LocalizedStringKey = "", items: Binding<[String]>) {
        self.title = Text(verbatim: title)
        self.prompt = prompt
        _items = items
    }

    var body: some View {
        TextField(text: $text, prompt: Text(prompt), axis: .vertical) { title }
            .lineLimit(1...4)
            .focused($isFocused)
            .onAppear { text = items.joined(separator: ", ") }
            .onChange(of: items) {
                if !isFocused { text = items.joined(separator: ", ") }
            }
            .onChange(of: isFocused) {
                if !isFocused { commit() }
            }
            .onSubmit(commit)
            .onDisappear(perform: commit)
    }

    private func commit() {
        let parsed = text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if parsed != items { items = parsed }
    }
}

/// A colour no other subject uses yet, from the palette.
func unusedSubjectColour(among subjects: [Subject]) -> UInt32 {
    NewSubjectSheet.palette.first { swatch in
        !subjects.contains { $0.colorHex == swatch.hex }
    }?.hex ?? NewSubjectSheet.palette[subjects.count % NewSubjectSheet.palette.count].hex
}
