import SwiftUI
import AppKit

/// SoundPick's look, in one place: a graphite interface where colour is
/// saved for the two things you act on — Download and the preview's play
/// button. Album covers supply the rest of the colour.
enum Theme {
    // MARK: Colour

    /// The one accent: the red of the app icon. Download, play, Paste, the
    /// chosen segment, tick boxes and the chosen cover.
    static let accent = dynamic(light: 0xD4151C, dark: 0xE5302C)
    /// Controls that are "on": tick boxes, the edited mark, chosen cover.
    static let ink = Color.primary
    /// Tint for system controls (sliders, progress bars).
    static let neutralTint = dynamic(light: 0x6E6E73, dark: 0xAEAEB2)
    /// Background of the selected row.
    static let selection = Color.primary.opacity(0.10)
    /// Recessed areas: segmented-control track, chips.
    static let well = Color.primary.opacity(0.08)
    /// The raised pill of a selected segment.
    static let segment = dynamic(light: 0xFFFFFF, dark: 0x636366)
    /// The right pane, a shade off the window.
    static let sidePane = Color.primary.opacity(0.025)

    // Status colours carry meaning and always come with an icon or words.
    static let success = Color.green
    static let warning = Color.orange
    /// Failure is still a red, but told apart from the accent by lightness:
    /// a dark wine on light backgrounds, a pale salmon on dark ones.
    static let failure = dynamic(light: 0x7A1F1F, dark: 0xFFB4AB)

    // MARK: Shape and spacing

    static let controlRadius: CGFloat = 6     // buttons, segments, thumbnails
    static let groupRadius: CGFloat = 8       // fields, segmented tracks
    static let coverRadius: CGFloat = 12      // the big cover and video frame

    /// Spacing runs on a 4-point grid.
    static let gapTight: CGFloat = 4          // a title and its subtitle
    static let gap: CGFloat = 8               // items that belong together
    static let gapLoose: CGFloat = 12         // parts of a row
    static let sectionGap: CGFloat = 16       // blocks in the inspector
    static let gutter: CGFloat = 16           // distance from a pane's edge
    static let rowPadding: CGFloat = 8        // above and below a list row
    static let buttonHeight: CGFloat = 32     // Download and the button beside it
    static let headerHeight: CGFloat = 30     // section header bars

    // MARK: Type — five roles, nothing below 11 pt

    /// The selected track's name (15 pt semibold).
    static let heading = Font.title3.weight(.semibold)
    /// List titles, fields, buttons (13 pt).
    static let body = Font.body
    /// Field labels, secondary buttons, file name (12 pt).
    static let label = Font.callout
    /// Section header bars (11 pt semibold).
    static let section = Font.subheadline.weight(.semibold)
    /// Subtitles, captions, status lines (11 pt).
    static let meta = Font.subheadline

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// A text button that doesn't shout: secondary text, underlined on hover.
struct QuietLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label(configuration: configuration)
    }

    private struct Label: View {
        let configuration: Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .foregroundStyle(enabled ? (hovering ? Color.primary : Color.secondary) : Color.secondary.opacity(0.5))
                .underline(hovering && enabled)
                .opacity(configuration.isPressed ? 0.6 : 1)
                .onHover { hovering = $0 }
        }
    }
}

extension ButtonStyle where Self == QuietLinkStyle {
    static var quietLink: QuietLinkStyle { QuietLinkStyle() }
}

/// The main action: a solid accent rectangle that matches the segments and
/// Paste, and keeps its colour when the window isn't focused.
struct SolidButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Face(configuration: configuration) }

    private struct Face: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(Theme.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(height: Theme.buttonHeight)
                .padding(.horizontal, Theme.gapLoose)
                .background(RoundedRectangle(cornerRadius: Theme.groupRadius).fill(Theme.accent))
                .opacity(!isEnabled ? 0.4 : (configuration.isPressed ? 0.8 : 1))
                .contentShape(Rectangle())
        }
    }
}
