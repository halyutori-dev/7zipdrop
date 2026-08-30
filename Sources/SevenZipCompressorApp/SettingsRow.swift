import AppKit
import SwiftUI

/// Attaches the *system* tooltip (`NSView.toolTip`) to a view.
///
/// SwiftUI's own `.help()` installs nothing here: dumping the running app's whole view
/// tree found **zero** tooltip-bearing views while an injected `NSButton.toolTip` in the
/// same tree was found, so the walker had detection power and the modifier really was
/// producing nothing (`scripts/check-tooltips.sh` keeps that measurement runnable).
/// This does not draw a tooltip of its own — it hands the text to AppKit's tooltip
/// service, so the delay, appearance and accessibility behaviour are the OS's.
private struct SystemToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = TrackingView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }

    /// A tooltip only appears for a view AppKit is tracking, and an overlay added by
    /// SwiftUI has no tracking area of its own.
    private final class TrackingView: NSView {
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                owner: self))
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steal clicks
    }
}

/// Attaches an explanation: the system tooltip for the pointer, `.help` and an
/// accessibility hint for VoiceOver. A row without an explanation gets none of them —
/// applying `.help("")` to it would put an empty help string on every plain row.
private struct Explains: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text {
            content
                .overlay { SystemToolTip(text: text).allowsHitTesting(false) }
                .help(text)
                .accessibilityHint(text)
        } else {
            content
        }
    }
}

extension View {
    /// Shows `text` as a system tooltip on hover, and as accessibility help.
    func explains(_ text: String?) -> some View {
        modifier(Explains(text: text))
    }
}

/// A "?" badge marking a row that has an explanation. The explanation itself is attached
/// to the whole row, so it appears wherever the pointer rests rather than only on an
/// 11pt glyph.
struct HelpBadge: View {
    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }
}

/// Vertical rule separating the settings pane from the window.
///
/// `Divider()` is the OS-standard separator and follows the current appearance. It does
/// *not* follow "Increase contrast", though: `NSColor.separatorColor` resolves to the
/// same rgba (alpha 0.098) under `accessibilityHighContrastAqua` and
/// `accessibilityHighContrastDarkAqua` as under plain aqua — measured. So when the system
/// asks for more contrast the rule is drawn in the label colour instead.
struct PaneDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if contrast == .increased {
            Rectangle()
                .fill(Color(nsColor: .labelColor))
                .frame(width: SettingsMetrics.paneBorderWidth)
        } else {
            Divider()
        }
    }
}

/// One line of a settings group: a label on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var help: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.rowGap) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 12))
                if help != nil { HelpBadge() }
            }
            Spacer(minLength: SettingsMetrics.rowGap)
            control()
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.rowVerticalInset)
        // A solid shape so the whole row — not just the glyphs — is a hover target.
        .contentShape(Rectangle())
        .explains(help)
    }
}

/// A rounded card of rows with hairlines between them, as in the mockups.
struct SettingsGroup<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var header: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.headerSpacing) {
            if let header {
                Text(header).font(.system(size: 12, weight: .bold))
            }
            VStack(spacing: 0) {
                content()
            }
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius)
                    .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.cardCornerRadius)
                    .strokeBorder(Color(nsColor: borderColor),
                                  lineWidth: SettingsMetrics.paneBorderWidth))
        }
    }

    /// Same reasoning as `PaneDivider`: the semantic separator colour does not react to
    /// "Increase contrast", so the card's outline is strengthened explicitly.
    private var borderColor: NSColor {
        contrast == .increased ? .labelColor : .separatorColor
    }
}

/// Separator between rows — the OS-standard one, with nothing painted over it.
struct RowDivider: View {
    var body: some View {
        Divider()
    }
}

extension View {
    /// Compact menu-style picker sized for the right-hand column.
    func settingsPickerStyle() -> some View {
        labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .font(.system(size: 12))
    }

    func settingsSwitchStyle() -> some View {
        labelsHidden().toggleStyle(.switch).controlSize(.small)
    }

    func settingsFieldStyle(width: CGFloat = 150) -> some View {
        textFieldStyle(.roundedBorder)
            .font(.system(size: 12))
            .multilineTextAlignment(.trailing)
            .frame(width: width)
    }
}
