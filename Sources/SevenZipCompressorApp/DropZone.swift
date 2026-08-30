import SwiftUI
import CompressorCore

/// The whole window is the drop target.
struct DropZone: View {
    let isEnabled: Bool
    let onDrop: ([URL]) -> Void

    @State private var isHovering = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovering ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(0.04))
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isHovering ? Color.accentColor : Color.secondary.opacity(0.45),
                    style: StrokeStyle(lineWidth: isHovering ? 2 : 1,
                                       dash: isHovering ? [8, 5] : []))

            VStack(spacing: 10) {
                Image(systemName: isHovering ? "arrow.down.doc.fill" : "archivebox")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(isHovering ? Color.accentColor : Color.secondary)
                Text(isEnabled ? "Drop File/Directory" : "7zz が見つからないため使用できません")
                    .font(.system(size: 17))
                    .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
            }
            .allowsHitTesting(false)

            FileDropTarget(
                isEnabled: isEnabled,
                onDrop: onDrop,
                onHoverChange: { isHovering = $0 })
        }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
