import AppKit
import SwiftUI
import FolioKit

/// The design's colours and corner radii. Views read from here, so changing a
/// value here changes it everywhere.
enum Theme {
    /// The accent colour. Change this one line to recolour the app.
    static let accent = Color(hex: 0x0A84FF)

    /// Accent darkened a little, for filled buttons and today's date.
    static let accentFill = accent.mixed(with: .black, by: 0.18)
    static let accentFillHover = accent.mixed(with: .black, by: 0.10)
    /// Accent lightened, for text links on dark backgrounds.
    static let accentText = accent.mixed(with: .white, by: 0.4)

    static let windowBackground = Color(hex: 0x1C1C1E)
    static let cardBackground = Color(hex: 0x232325)
    static let cardHover = Color(hex: 0x2A2A2D)

    static let primaryText = Color(hex: 0xF5F5F7)
    /// Apple's secondary label grey on dark backgrounds, about 60% white.
    static let secondaryText = grey(0.6, increased: 0.8)
    /// The faintest text, still at least 4.5:1 against Folio's backgrounds.
    static let tertiaryText = grey(0.55, increased: 0.72)
    static let sidebarIcon = grey(0.55, increased: 0.75)

    static let separator = white(0.07, increased: 0.22)
    static let gridLine = white(0.06, increased: 0.16)
    static let selection = Color.white.opacity(0.08)
    static let hover = Color.white.opacity(0.06)
    static let success = Color(hex: 0x30D158)
    static let warning = Color(hex: 0xFF9F0A)
    /// For the Inbox tile and sorting steps, so Today's colours vary.
    static let purple = Color(hex: 0xBF5AF2)

    /// Folio's animations, or none when Reduce Motion is on in System
    /// Settings › Accessibility › Display.
    static func motion(_ animation: Animation = .snappy) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation
    }

    // MARK: Increase Contrast

    /// Apple's label grey at an opacity, brighter when Increase Contrast is
    /// on in System Settings › Accessibility › Display.
    private static func grey(_ opacity: Double, increased: Double) -> Color {
        adaptive(red: 0xEB, green: 0xEB, blue: 0xF5, opacity: opacity, increased: increased)
    }

    private static func white(_ opacity: Double, increased: Double) -> Color {
        adaptive(red: 0xFF, green: 0xFF, blue: 0xFF, opacity: opacity, increased: increased)
    }

    private static func adaptive(red: Int, green: Int, blue: Int, opacity: Double, increased: Double) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let highContrast = appearance.bestMatch(from: [.accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua, .darkAqua, .aqua])?.rawValue.contains("HighContrast") == true
            return NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: highContrast ? increased : opacity)
        })
    }

    enum Radius {
        /// Drop zone and Inbox cards.
        static let panel: CGFloat = 22
        /// Subject and folder cards.
        static let card: CGFloat = 18
        /// The "Recently sorted" list.
        static let list: CGFloat = 16
        /// Icon tiles, planner blocks and sidebar items.
        static let tile: CGFloat = 10
        static let button: CGFloat = 9
    }
}

extension Color {
    /// A colour from a hex value such as `0x0A84FF`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }

    /// Blends towards `other` in sRGB, like CSS `color-mix`.
    func mixed(with other: Color, by fraction: Double) -> Color {
        mix(with: other, by: fraction, in: .device)
    }
}

extension Subject {
    var color: Color { Color(hex: colorHex) }
    /// Background for this subject's icon tiles and planner blocks.
    var tintBackground: Color { color.opacity(0.22) }
    /// Icons and text drawn on `tintBackground`.
    var tintForeground: Color { color.mixed(with: .white, by: 0.45) }
}
