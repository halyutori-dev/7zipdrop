import SwiftUI
import CompressorCore

struct JobRow: View {
    let job: Job
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onPassword: () -> Void
    let onReveal: ([URL]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIcon
                Image(systemName: job.kind == .compress ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help(job.kind == .compress ? "圧縮" : "展開")
                Text(job.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                trailing
            }
            detail
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.secondary.opacity(0.07)))
    }

    @ViewBuilder private var statusIcon: some View {
        switch job.state {
        case .queued:    Image(systemName: "clock").foregroundStyle(.secondary)
        case .running:   ProgressView().controlSize(.small)
        case .succeeded(let outcome):
            Image(systemName: warningIcon(for: outcome) ?? "checkmark.circle.fill")
                .foregroundStyle(warningIcon(for: outcome) == nil ? .green : .orange)
        case .failed:    Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "slash.circle").foregroundStyle(.secondary)
        }
    }

    private func warningIcon(for outcome: Job.Outcome) -> String? {
        switch outcome {
        case .compressed(let result): result.hadWarnings ? "exclamationmark.triangle.fill" : nil
        case .extracted(let result):
            (result.hadWarnings || !result.sanitizedPaths.isEmpty) ? "exclamationmark.triangle.fill" : nil
        }
    }

    @ViewBuilder private var trailing: some View {
        switch job.state {
        case .queued, .running:
            Button("中止", action: onCancel).controlSize(.small)
        case .succeeded(let outcome):
            Button("Finder で表示") { onReveal(outcome.urls) }.controlSize(.small)
        case .failed(_, let needsPassword):
            if needsPassword {
                Button("パスワードを入力…", action: onPassword).controlSize(.small)
            } else {
                Button("再実行", action: onRetry).controlSize(.small)
            }
        case .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder private var detail: some View {
        switch job.state {
        case .queued:
            Text("待機中").font(.caption2).foregroundStyle(.secondary)
        case .running:
            VStack(alignment: .leading, spacing: 2) {
                if let percent = job.percent {
                    ProgressView(value: Double(percent), total: 100).controlSize(.small)
                } else {
                    ProgressView().progressViewStyle(.linear).controlSize(.small)
                }
                Text(job.currentItem ?? "準備中…")
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        case .succeeded(let outcome):
            Text(summary(for: outcome)).font(.caption2).foregroundStyle(.secondary)
                .lineLimit(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .failed(let message, _):
            Text(message).font(.caption2).foregroundStyle(.red)
                .lineLimit(6).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Text(job.kind == .compress
                 ? "中止しました（書庫は作られていません）"
                 : "中止しました（展開結果は残していません）")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func summary(for outcome: Job.Outcome) -> String {
        switch outcome {
        case .compressed(let result):
            var parts: [String] = []
            if let name = result.primaryURL?.lastPathComponent { parts.append(name) }
            if result.archiveURLs.count > 1 { parts.append("\(result.archiveURLs.count) 分割") }
            parts.append(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))
            switch result.verification {
            case .passed: parts.append("検証OK")
            case .skippedBecauseEncrypted: parts.append("検証スキップ（暗号化書庫）")
            case .notRequested: break
            }
            if !result.removedSources.isEmpty {
                parts.append("元ファイル \(result.removedSources.count) 件をゴミ箱へ")
            }
            if !result.removalFailures.isEmpty {
                parts.append("⚠︎ 削除できなかった元ファイル \(result.removalFailures.count) 件")
            }
            if result.hadWarnings { parts.append("⚠︎ 一部のファイルが入っていない可能性") }
            return parts.joined(separator: " ・ ")
        case .extracted(let result):
            var parts = [result.outputURL.lastPathComponent]
            parts.append("\(result.fileCount) ファイル")
            parts.append(ByteCountFormatter.string(fromByteCount: result.totalBytes, countStyle: .file))
            if let inner = result.followedInnerArchive { parts.append("\(inner) も展開") }
            if !result.sanitizedPaths.isEmpty {
                parts.append("⚠︎ 展開先の外を指すパス \(result.sanitizedPaths.count) 件を 7-Zip が書き換えました")
            }
            if result.hadWarnings { parts.append("⚠︎ 一部のファイルを取り出せませんでした") }
            return parts.joined(separator: " ・ ")
        }
    }
}
