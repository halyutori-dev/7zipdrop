import Foundation
import Testing
@testable import CompressorCore

/// The settings pane lives in the app target, which is an executable and so cannot be
/// imported here, and SwiftUI spacing does not exist as a value until it renders. These
/// checks therefore read the *source of truth* for the pane's density and its edge, so
/// that changing either is a deliberate edit instead of a silent drift. They do not
/// claim the pane looks right — that is checked by rendering it, see docs/VERIFICATION.md.
@Suite("settings pane layout")
struct SettingsPaneLayoutTests {

    // MARK: - reading the app sources

    private static var appSources: URL {
        TestSupport.packageRoot.appendingPathComponent("Sources/SevenZipCompressorApp")
    }

    private static func source(_ name: String) throws -> String {
        try String(contentsOf: appSources.appendingPathComponent(name), encoding: .utf8)
    }

    /// Reads the declared value as a number, so that respelling it (`408.0`, `408`)
    /// or reformatting around it is not mistaken for a change of density.
    private static func declaredValue(_ name: String, in text: String) -> Double? {
        let pattern = "static\\s+let\\s+\(name)\\s*:\\s*CGFloat\\s*=\\s*([0-9]+(?:\\.[0-9]+)?)"
        guard let hit = text.range(of: pattern, options: .regularExpression) else { return nil }
        let digits = String(text[hit]).drop(while: { !$0.isNumber })
        return Double(digits)
    }

    /// Negative checks have to ignore comments: the sidebar *documents* why an overlaid
    /// `Divider()` is wrong, and matching that sentence failed the very test it explains.
    /// A `//` inside a string literal is not a comment (a help string could contain a
    /// URL), so quotes are counted before cutting.
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var quoted = false
                var previous: Character?
                var index = line.startIndex
                while index < line.endIndex {
                    let character = line[index]
                    if character == "\"" && previous != "\\" { quoted.toggle() }
                    if !quoted, character == "/", previous == "/" {
                        return String(line[line.startIndex..<line.index(before: index)])
                    }
                    previous = character
                    index = line.index(after: index)
                }
                return String(line)
            }
            .joined(separator: "\n")
    }

    /// The comment stripper is itself a place a false pass can hide, so pin both
    /// directions: it must cut a real comment and must not cut a string containing "//".
    @Test("the comment stripper cuts comments and not string literals")
    func codeOnlyIsCorrect() {
        #expect(Self.codeOnly("let a = 1 // .overlay(alignment: .leading)")
                == "let a = 1 ")
        #expect(Self.codeOnly("let url = \"https://example.com/x\"")
                == "let url = \"https://example.com/x\"")
        #expect(Self.codeOnly("f(\"a//b\") // gone").hasPrefix("f(\"a//b\")"))
        #expect(!Self.codeOnly("f(\"a//b\") // gone").contains("gone"))
    }

    private static func matches(of pattern: String, in text: String) -> [String] {
        var found: [String] = []
        var searchRange = text.startIndex..<text.endIndex
        while let hit = text.range(of: pattern, options: .regularExpression, range: searchRange) {
            found.append(String(text[hit]))
            searchRange = hit.upperBound..<text.endIndex
        }
        return found
    }

    // MARK: - density

    private static let expectedMetrics: [(String, Double)] = [
        ("paneWidth", 408),
        ("paneBorderWidth", 1),
        ("contentInset", 18),
        ("groupSpacing", 22),
        ("headerSpacing", 8),
        ("rowHorizontalInset", 16),
        ("rowVerticalInset", 13),
        ("rowGap", 16),
        ("blockInset", 14),
        ("tabInset", 14),
        ("cardCornerRadius", 8),
    ]

    /// Pinned so that changing the pane's density is a deliberate edit: the value, the
    /// call sites that apply it, and the absence of competing literals are each checked.
    /// What is *not* checked here is how the result looks — that needs a render.
    @Test("the pane's spacing is declared once, at the measured values")
    func metricsArePinned() throws {
        let text = try Self.source("SettingsMetrics.swift")
        for (name, value) in Self.expectedMetrics {
            #expect(Self.declaredValue(name, in: text) == value,
                    "SettingsMetrics.\(name) should be \(value)")
        }
    }

    /// A token nothing uses is a token that has stopped describing the pane.
    @Test("every declared metric is actually applied by the pane")
    func metricsAreApplied() throws {
        let users = try ["SettingsRow.swift", "SettingsSidebar.swift", "ContentView.swift"]
            .map { try Self.source($0) }
            .joined(separator: "\n")
        for (name, _) in Self.expectedMetrics {
            #expect(users.contains("SettingsMetrics.\(name)"),
                    "nothing reads SettingsMetrics.\(name)")
        }
    }

    /// Deleting a `.padding(...)` outright leaves no literal behind for the check below
    /// to catch, and the value in SettingsMetrics still reads 13 — so without naming the
    /// call sites, dropping a row's insets entirely passes every other test here. That
    /// exact deletion was injected and confirmed green before this test existed.
    @Test("the row, card and pane insets are all wired to a metric")
    func theInsetsAreWiredUp() throws {
        let row = try Self.source("SettingsRow.swift")
        for expression in [".padding(.horizontal, SettingsMetrics.rowHorizontalInset)",
                           ".padding(.vertical, SettingsMetrics.rowVerticalInset)",
                           "spacing: SettingsMetrics.rowGap",
                           "Spacer(minLength: SettingsMetrics.rowGap)",
                           "spacing: SettingsMetrics.headerSpacing",
                           "cornerRadius: SettingsMetrics.cardCornerRadius"] {
            #expect(row.contains(expression), "SettingsRow.swift no longer applies \(expression)")
        }

        let sidebar = try Self.source("SettingsSidebar.swift")
        for expression in [".padding(SettingsMetrics.tabInset)",
                           ".padding(SettingsMetrics.contentInset)",
                           "spacing: SettingsMetrics.groupSpacing",
                           ".padding(SettingsMetrics.blockInset)"] {
            #expect(sidebar.contains(expression),
                    "SettingsSidebar.swift no longer applies \(expression)")
        }
    }

    /// One row deciding its own padding is exactly how the pane ends up looking uneven,
    /// and it is invisible in review because each literal looks reasonable on its own.
    /// Only `.padding` is policed: the remaining `spacing:` literals are gaps *inside* a
    /// control cluster (label + badge, a pair of buttons) and the deliberate `spacing: 0`
    /// that lets the row dividers do the separating, none of which are pane density.
    @Test("no row or group re-decides its spacing with a bare literal")
    func spacingAlwaysComesFromTheMetrics() throws {
        for name in ["SettingsRow.swift", "SettingsSidebar.swift"] {
            let text = try Self.source(name)
            let strays = Self.matches(
                of: "\\.padding\\(\\s*(?:\\.[A-Za-z]+\\s*,\\s*)?[0-9]", in: text)
            #expect(strays.isEmpty,
                    "\(name) sets padding from a literal instead of SettingsMetrics: \(strays)")
        }
    }

    // MARK: - the edge

    /// `Divider()` takes its orientation from the enclosing stack, so it is only the
    /// pane's vertical edge when it sits in an `HStack`. Inside
    /// `.overlay(alignment: .leading)` there is no stack and it draws a *horizontal*
    /// hairline across the middle instead — which is how 1.2 shipped with no visible
    /// boundary at all.
    @Test("the leading edge is the standard separator, in a stack that makes it vertical")
    func theEdgeIsAVerticalRule() throws {
        let primitives = try Self.source("SettingsRow.swift")
        #expect(primitives.contains("struct PaneDivider"))
        #expect(primitives.contains("Divider()"),
                "the edge should be the OS separator, not a hand-rolled rule")
        #expect(primitives.contains("frame(width: SettingsMetrics.paneBorderWidth)"),
                "the high-contrast rule must be sized by width, so it spans the height")

        let sidebar = try Self.source("SettingsSidebar.swift")
        #expect(sidebar.contains("HStack(spacing: 0) {"),
                "the divider needs a horizontal stack to be vertical")
        #expect(sidebar.contains("PaneDivider()"), "the pane must draw its own leading edge")
        #expect(!Self.codeOnly(sidebar).contains(".overlay(alignment: .leading)"),
                "an overlaid Divider draws horizontally")
    }

    /// `NSColor.separatorColor` resolves to the same rgba under
    /// `accessibilityHighContrastAqua` / `...DarkAqua` as under plain aqua — measured, see
    /// docs/VERIFICATION.md — so the semantic colour alone does not honour "Increase
    /// contrast" and the pane has to read the environment for it.
    @Test("the pane's rules react to the Increase-contrast setting")
    func theRulesFollowTheContrastSetting() throws {
        let primitives = try Self.source("SettingsRow.swift")
        #expect(primitives.contains("@Environment(\\.colorSchemeContrast)"),
                "nothing reads the contrast setting")
        #expect(Self.matches(of: "contrast == \\.increased", in: primitives).count >= 2,
                "both the pane edge and the card outline should react")
    }

    // MARK: - where things sit

    private static func order(_ needles: [String], in text: String) throws -> Bool {
        var cursor = text.startIndex
        for needle in needles {
            guard let hit = text.range(of: needle, range: cursor..<text.endIndex) else {
                Issue.record("\(needle) is missing")
                return false
            }
            cursor = hit.upperBound
        }
        return true
    }

    /// 共通パスワード belongs directly under the mode that uses it, inside the same card,
    /// so the pair reads as one setting instead of a stray group further down the pane.
    @Test("the shared password sits under the password mode, in the same card")
    func sharedPasswordFollowsTheMode() throws {
        let sidebar = try Self.source("SettingsSidebar.swift")
        #expect(try Self.order(["SettingsGroup(header: \"圧縮設定（\\(label)）\")",
                                "title: \"パスワード\"",
                                "title: \"共通パスワード\"",
                                "title: \"分割サイズ\""],
                               in: sidebar))
        // ...and not as a card of its own any more.
        #expect(!Self.codeOnly(sidebar).contains("SettingsGroup {"),
                "the shared password should not be its own group")
    }

    /// The chosen folder is shown under the button, not squeezed in front of it — in front
    /// there was only room for the last path component.
    @Test("the destination path is shown under the button")
    func destinationPathSitsBelowTheButton() throws {
        let sidebar = try Self.source("SettingsSidebar.swift")
        #expect(sidebar.contains("VStack(alignment: .trailing"),
                "the control needs a vertical stack to put anything below the button")
        #expect(try Self.order(["VStack(alignment: .trailing",
                                "Button(\"変更…\")",
                                "case .fixedDirectory(let url) = destination",
                                "Self.display(url)"],
                               in: sidebar))
        #expect(sidebar.contains("abbreviatingWithTildeInPath"),
                "show the whole path with ~, the way other Mac apps do")
    }

    /// The explanations are the whole point of the "?" badges, and 1.2/1.3 shipped with
    /// every one of them inert: SwiftUI's `.help()` installed no tooltip at all. The
    /// count and the row-sized hit area are measured against the running app by
    /// scripts/check-tooltips.sh; this only pins that the wiring is still in place.
    @Test("rows hand their explanation to the system tooltip, not just to .help()")
    func rowsInstallASystemToolTip() throws {
        let primitives = try Self.source("SettingsRow.swift")
        #expect(primitives.contains("NSViewRepresentable"),
                "the system tooltip needs an AppKit view to hang on")
        #expect(primitives.contains("view.toolTip = text"))
        #expect(primitives.contains("NSTrackingArea"),
                "AppKit only shows a tooltip for a view it is tracking")
        #expect(primitives.contains(".contentShape(Rectangle())"),
                "the whole row must be a hover target, not just the glyphs")
        #expect(primitives.contains(".explains(help)"),
                "SettingsRow must attach its explanation to the row")
        // The tooltip is measured against a DEBUG build (the diagnostic that counts them
        // is `#if DEBUG`), so the shipped release build is only as verified as the source
        // being identical in both configurations.
        #expect(!primitives.contains("#if"),
                "no part of the tooltip wiring may be compiled conditionally")
    }

    /// A translucent pane over the drop zone shows the drop zone's border and label
    /// through itself, which is the other half of why the boundary was unreadable.
    @Test("the pane is opaque and does not sit on top of the drop label")
    func thePaneIsItsOwnSurface() throws {
        let sidebar = try Self.source("SettingsSidebar.swift")
        #expect(sidebar.contains("windowBackgroundColor"),
                "the pane needs an opaque backing under the material")

        let content = try Self.source("ContentView.swift")
        #expect(content.contains("SettingsMetrics.paneWidth"))
        #expect(content.contains("padding(.trailing"),
                "the main area must reserve the pane's width instead of being covered")
    }
}
