import SwiftUI

/// The design's buttons: accent-filled primary, translucent ghost, capsule
/// chips, and red for what can't be undone.
struct FilledButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case ghost
        case chip
        case danger
    }

    var kind: Kind
    var height: CGFloat = 32
    var fullWidth = false
    /// Setup's bigger buttons: 44 points high, with 15-point text.
    var isLarge = false

    func makeBody(configuration: Configuration) -> some View {
        FilledButton(configuration: configuration, kind: kind, height: isLarge ? 44 : height, fullWidth: fullWidth, isLarge: isLarge)
    }
}

private struct FilledButton: View {
    let configuration: ButtonStyleConfiguration
    let kind: FilledButtonStyle.Kind
    let height: CGFloat
    let fullWidth: Bool
    let isLarge: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .font(.system(size: isLarge ? 15 : 13, weight: .medium))
            .foregroundStyle(kind == .primary || kind == .danger ? Color.white : Theme.primaryText)
            .padding(.leading, isLarge ? 22 : kind == .chip ? 12 : 14)
            .padding(.trailing, isLarge ? 22 : 14)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .background(shape.fill(fill))
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .onHover { isHovered = $0 }
    }

    private var shape: AnyShape {
        kind == .chip ? AnyShape(Capsule()) : AnyShape(RoundedRectangle(cornerRadius: isLarge ? 12 : Theme.Radius.button))
    }

    private var fill: Color {
        switch kind {
        case .primary: isHovered && isEnabled ? Theme.accentFillHover : Theme.accentFill
        case .ghost: Color.white.opacity(isHovered ? 0.15 : 0.1)
        case .chip: Color.white.opacity(isHovered ? 0.16 : 0.1)
        case .danger: Theme.danger.mixed(with: .black, by: isHovered && isEnabled ? 0.08 : 0.18)
        }
    }
}

/// A text link in the accent colour, such as "Undo".
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TextLink(configuration: configuration)
    }

    private struct TextLink: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13))
                .foregroundStyle(Theme.accentText)
                .underline(isHovered)
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovered = $0 }
                .pointerStyle(.link)
        }
    }
}

extension ButtonStyle where Self == FilledButtonStyle {
    static var folioPrimary: FilledButtonStyle { FilledButtonStyle(kind: .primary) }
    static var folioGhost: FilledButtonStyle { FilledButtonStyle(kind: .ghost) }
    static var folioDanger: FilledButtonStyle { FilledButtonStyle(kind: .danger) }
    static var folioChip: FilledButtonStyle { FilledButtonStyle(kind: .chip) }
    static var folioPrimaryLarge: FilledButtonStyle { FilledButtonStyle(kind: .primary, isLarge: true) }
    static var folioGhostLarge: FilledButtonStyle { FilledButtonStyle(kind: .ghost, isLarge: true) }
}

extension ButtonStyle where Self == TextLinkButtonStyle {
    static var folioLink: TextLinkButtonStyle { TextLinkButtonStyle() }
}
