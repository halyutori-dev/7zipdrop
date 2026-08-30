import SwiftUI

/// Every spacing the settings pane uses, in one place, so the pane's density is a single
/// decision instead of a dozen literals that drift apart row by row.
///
/// The values are pinned by `SettingsPaneLayoutTests`; the pane is checked by rendering
/// it (docs/VERIFICATION.md), because these numbers only mean something on screen.
enum SettingsMetrics {
    /// Pane width. Wider than 1.2's 380 so the roomier row insets below come out of the
    /// window rather than out of the right-hand control column.
    static let paneWidth: CGFloat = 408

    /// The rule down the pane's leading edge, and the hairline under the tab picker.
    static let paneBorderWidth: CGFloat = 1

    /// Inset around the scrolling settings content.
    static let contentInset: CGFloat = 18
    /// Gap between one group (header + card) and the next.
    static let groupSpacing: CGFloat = 22
    /// Gap between a group's header and its card.
    static let headerSpacing: CGFloat = 8
    /// Inset around the tab picker at the top of the pane.
    static let tabInset: CGFloat = 14

    /// Row insets. 13 vertical puts the rows at about 46pt, which is what the mockup's
    /// rows measure and roughly what System Settings uses.
    static let rowHorizontalInset: CGFloat = 16
    static let rowVerticalInset: CGFloat = 13
    /// Smallest gap left between a row's label and its control before the label wraps.
    static let rowGap: CGFloat = 16

    static let cardCornerRadius: CGFloat = 8
    /// Inset for a card holding free-form content (the command preview) instead of rows.
    static let blockInset: CGFloat = 14
}
