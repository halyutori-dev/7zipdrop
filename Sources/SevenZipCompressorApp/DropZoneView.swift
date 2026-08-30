import AppKit
import SwiftUI

/// AppKit-backed drop target.
///
/// `NSPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])`
/// is the canonical way to get dragged files on macOS and behaves consistently for
/// multi-item drags, aliases and volumes — unlike reading item providers by type string.
struct FileDropTarget: NSViewRepresentable {
    var isEnabled: Bool
    var onDrop: ([URL]) -> Void
    var onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> DropView {
        let view = DropView()
        view.onDrop = onDrop
        view.onHoverChange = onHoverChange
        view.isEnabled = isEnabled
        return view
    }

    func updateNSView(_ view: DropView, context: Context) {
        view.onDrop = onDrop
        view.onHoverChange = onHoverChange
        view.isEnabled = isEnabled
    }

    final class DropView: NSView {
        var onDrop: (([URL]) -> Void)?
        var onHoverChange: ((Bool) -> Void)?
        var isEnabled = true

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            registerForDraggedTypes([.fileURL])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        private static let readingOptions: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        private func urls(from dragging: any NSDraggingInfo) -> [URL] {
            let objects = dragging.draggingPasteboard.readObjects(
                forClasses: [NSURL.self], options: Self.readingOptions)
            return (objects as? [URL]) ?? []
        }

        override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard isEnabled, !urls(from: sender).isEmpty else { return [] }
            onHoverChange?(true)
            return .copy
        }

        override func draggingExited(_ sender: (any NSDraggingInfo)?) {
            onHoverChange?(false)
        }

        override func draggingEnded(_ sender: any NSDraggingInfo) {
            onHoverChange?(false)
        }

        override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            onHoverChange?(false)
            guard isEnabled else { return false }
            let dropped = urls(from: sender)
            guard !dropped.isEmpty else { return false }
            onDrop?(dropped)
            return true
        }
    }
}
