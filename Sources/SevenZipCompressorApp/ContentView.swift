import SwiftUI
import CompressorCore

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // The pane still slides in over the window, but the main area gives up the
            // width it covers: otherwise the pane — now opaque, so that its edge reads —
            // hides the right-hand half of the drop label.
            main
                .padding(.trailing, model.isSettingsOpen ? SettingsMetrics.paneWidth : 0)
            if model.isSettingsOpen {
                SettingsSidebar(model: model)
                    .frame(width: SettingsMetrics.paneWidth)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.22), value: model.isSettingsOpen)
        // Unchanged at 680: making the minimum depend on the pane would raise the floor
        // for people who never open it. At the minimum width with the pane open the drop
        // area is about 270pt, which is narrow but still readable and still a drop target.
        .frame(minWidth: 680, minHeight: 460)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.isSettingsOpen.toggle()
                } label: {
                    Image(systemName: model.isSettingsOpen ? "gearshape.fill" : "gearshape")
                }
                .help(model.isSettingsOpen ? "設定を閉じる" : "設定")
            }
        }
        .sheet(item: Binding(
            get: { model.passwordRequest },
            set: { if $0 == nil { model.cancelPasswordRequest() } })
        ) { request in
            PasswordPromptSheet(request: request)
        }
    }

    private var main: some View {
        VStack(spacing: 10) {
            if let problem = model.setupProblem {
                setupBanner(problem)
            }
            ZStack(alignment: .bottom) {
                DropZone(isEnabled: model.sevenZipURL != nil) { model.enqueue($0) }
                if !model.jobs.isEmpty { jobOverlay }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setupBanner(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("セットアップが必要です", systemImage: "exclamationmark.triangle.fill")
                .font(.headline).foregroundStyle(.orange)
            Text(problem).font(.caption).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Button("7zz を選択…") { chooseExecutable() }.controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    /// The queue sits over the bottom of the drop area, so the window stays a single
    /// surface while still showing what is happening.
    private var jobOverlay: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("キュー").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.jobs.contains(where: \.isFinished) {
                    Button("完了分を消す") { model.clearFinished() }.controlSize(.small)
                }
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(model.jobs) { job in
                        JobRow(job: job,
                               onCancel: { model.cancel(job) },
                               onRetry: { model.retry(job) },
                               onPassword: { model.retryWithPassword(job) },
                               onReveal: { model.reveal($0) })
                    }
                }
            }
            .frame(maxHeight: 190)
            HStack(spacing: 6) {
                Image(systemName: model.sevenZipURL != nil ? "checkmark.seal" : "xmark.seal")
                    .foregroundStyle(model.sevenZipURL != nil ? .green : .red)
                Text(model.sevenZipVersionSummary)
                    .font(.system(size: 9, design: .monospaced))
                    .lineLimit(1).truncationMode(.head)
                Spacer()
            }
            .foregroundStyle(.secondary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial))
        .padding(10)
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "この 7zz を使う"
        if panel.runModal() == .OK, let url = panel.url {
            model.useExecutable(at: url)
        }
    }
}
