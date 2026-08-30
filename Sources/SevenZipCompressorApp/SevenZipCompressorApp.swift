import AppKit
import SwiftUI

@main
struct SevenZipCompressorApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("7Zip Drop", id: "main") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 900, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("同梱している 7-Zip について…") { AppDelegate.showAboutSevenZip() }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set once the window exists, so files dropped on the Dock icon before then are queued.
    var model: AppModel? {
        didSet { flushPending() }
    }

    private var pending: [URL] = []

    /// Files dropped on the Dock icon, or opened with "Open With".
    func application(_ application: NSApplication, open urls: [URL]) {
        if let model {
            MainActor.assumeIsolated { model.enqueue(urls) }
        } else {
            pending += urls
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

#if DEBUG
    /// Debug-only (see `#if DEBUG` above): a persisted `dumpTooltips` key would otherwise
    /// make a shipped app dump and quit on every launch, looking bricked.
    ///
    /// Diagnostic used by `scripts/check-tooltips.sh` and nothing else: with
    /// `-dumpTooltips 1` the app prints every tooltip-bearing view in its own view tree
    /// and quits. Hovering cannot be automated on this machine (Accessibility is not
    /// granted, so synthesised mouse-moved events are dropped), and this is what caught
    /// SwiftUI's `.help()` installing no tooltip at all. The last line is a control: it
    /// adds a view with a known tooltip and re-counts, so a report of "0 found" can be
    /// told apart from a walker that cannot see tooltips in the first place.
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Diagnostic: renders under a named appearance, so the "Increase contrast" look
        // can be checked without changing the machine's own accessibility settings.
        if let name = UserDefaults.standard.string(forKey: "forceAppearance") {
            let appearance = NSAppearance(named: NSAppearance.Name(name))
            NSApp.appearance = appearance
            // The window already exists by now and keeps its own appearance, so setting
            // it on NSApp alone leaves the window in the system's appearance.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                for window in NSApp.windows { window.appearance = appearance }
                print("APPEARANCE requested=\(name) "
                      + "effective=\(NSApp.windows.first?.effectiveAppearance.name.rawValue ?? "?")")
                // stdout is block-buffered when it is not a terminal, and these
                // diagnostics are read from a redirected file.
                fflush(stdout)
            }
        }
        guard UserDefaults.standard.bool(forKey: "dumpTooltips") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { Self.dumpTooltips() }
    }

    private static func countTooltips(in view: NSView, report: Bool) -> Int {
        var found = 0
        if let tip = view.toolTip {
            if report {
                let frame = view.convert(view.bounds, to: nil)
                print("TIP \(type(of: view)) "
                      + "frame=\(Int(frame.origin.x)),\(Int(frame.origin.y)) "
                      + "\(Int(frame.width))x\(Int(frame.height)) "
                      + "text=\(tip.prefix(28))")
            }
            found += 1
        }
        for subview in view.subviews {
            found += countTooltips(in: subview, report: report)
        }
        return found
    }

    private static func dumpTooltips() {
        var windows = 0
        var total = 0
        for window in NSApp.windows {
            guard let content = window.contentView else { continue }
            windows += 1
            total += countTooltips(in: content, report: true)
        }
        print("TOOLTIP-DUMP windows=\(windows) tooltipViews=\(total)")
        fflush(stdout)

        guard let content = NSApp.windows.first?.contentView else {
            print("TOOLTIP-DUMP control=unavailable")
            exit(0)
        }
        let control = NSButton(title: "control", target: nil, action: nil)
        control.toolTip = "control tooltip"
        content.addSubview(control)
        let seen = countTooltips(in: content, report: false)
            - countTooltips(in: content, report: false, excluding: control)
        control.removeFromSuperview()
        print("TOOLTIP-DUMP control=\(seen)")
        exit(0)
    }

    private static func countTooltips(in view: NSView, report: Bool, excluding: NSView) -> Int {
        if view === excluding { return 0 }
        var found = view.toolTip != nil ? 1 : 0
        for subview in view.subviews {
            found += countTooltips(in: subview, report: report, excluding: excluding)
        }
        return found
    }
#endif

    private func flushPending() {
        guard let model, !pending.isEmpty else { return }
        let urls = pending
        pending = []
        MainActor.assumeIsolated { model.enqueue(urls) }
    }

    static func showAboutSevenZip() {
        let alert = NSAlert()
        alert.messageText = "同梱している 7-Zip について"
        alert.informativeText = """
            このアプリは圧縮処理に 7-Zip のコンソール版 (7zz) を同梱して使用しています。

            7-Zip 26.02 — Copyright (C) 1999-2026 Igor Pavlov
            ライセンス: GNU LGPL
            配布元: https://www.7-zip.org/

            7-Zip のソースコードは上記サイトで公開されています。
            同梱バイナリのライセンス全文は、アプリバンドル内の
            Contents/Resources/ThirdParty/7-Zip/License.txt にあります。
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
