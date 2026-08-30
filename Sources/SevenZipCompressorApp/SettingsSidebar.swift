import SwiftUI
import CompressorCore

enum SettingsTab: String, CaseIterable, Identifiable, Codable {
    case general, sevenZip, zip

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .general: "General"
        case .sevenZip: "7z"
        case .zip: "Zip"
        }
    }
}

struct SettingsSidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            // A Divider takes its orientation from the enclosing stack, so putting the
            // standard separator in an HStack is what makes it the pane's vertical edge.
            // (In `.overlay(alignment: .leading)` there is no stack and it draws
            // horizontally — that is how 1.2 shipped with no visible boundary.)
            PaneDivider()
            pane
        }
        .background(.regularMaterial)
        .background(Color(nsColor: .windowBackgroundColor))
        .shadow(color: .black.opacity(0.18), radius: 6, x: -2, y: 0)
    }

    private var pane: some View {
        VStack(spacing: 0) {
            Picker("", selection: $model.settingsTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.displayName).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Segmented pickers size to their labels, which left the tabs floating in
            // the middle of the wider pane instead of heading it.
            .frame(maxWidth: .infinity)
            .padding(SettingsMetrics.tabInset)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.groupSpacing) {
                    switch model.settingsTab {
                    case .general: GeneralSettingsTab(model: model)
                    case .sevenZip: FormatSettingsTab(model: model, format: .sevenZip)
                    case .zip: FormatSettingsTab(model: model, format: .zip)
                    }
                }
                .padding(SettingsMetrics.contentInset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @Bindable var model: AppModel

    var body: some View {
        SettingsGroup(header: "全般設定") {
            SettingsRow(title: "形式",
                        help: "圧縮するときに作る書庫の形式です。7z は圧縮率が高くファイル名も暗号化できます。zip はどこでも開けます。") {
                Picker("", selection: $model.settings.general.format) {
                    ForEach(ArchiveFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                }
                .settingsPickerStyle()
            }
            RowDivider()
            SettingsRow(title: "保存先",
                        help: "「元ファイルと同じ場所」はドロップされた項目の隣に、「指定フォルダ」は常に同じ場所に出力します。") {
                DestinationControl(destination: $model.settings.general.destination)
            }
            RowDivider()
            SettingsRow(title: "ドロップ処理判定",
                        help: "「自動」はドロップされたものが全て書庫なら展開、それ以外は圧縮します。混在しているときは圧縮します。") {
                Picker("", selection: $model.settings.general.dropMode) {
                    ForEach(DropMode.allCases) { Text($0.shortName).tag($0) }
                }
                .settingsPickerStyle()
            }
            RowDivider()
            SettingsRow(title: "完了時にFinderで表示") {
                Toggle("", isOn: $model.settings.general.revealInFinder).settingsSwitchStyle()
            }
            RowDivider()
            SettingsRow(title: "完了時に通知") {
                Toggle("", isOn: $model.settings.general.notifyOnCompletion).settingsSwitchStyle()
            }
        }

        SettingsGroup(header: "圧縮設定") {
            SettingsRow(title: "読み取れないファイルの処理",
                        help: "「スキップ」だと、読めないファイルを黙って除いた書庫ができて警告で終わります。「処理中止」は書庫を作らず中止します（既定）。") {
                Picker("", selection: $model.settings.general.unreadableFilePolicy) {
                    ForEach(UnreadableFilePolicy.allCases) { Text($0.displayName).tag($0) }
                }
                .settingsPickerStyle()
            }
            RowDivider()
            SettingsRow(title: "シンボリックリンクの取り込み",
                        help: "オン: リンクをリンクのまま保存します。オフ: リンク先の実体を取り込むため、フォルダ外のファイルまで書庫に入ることがあります。") {
                Toggle("", isOn: $model.settings.general.includeSymlinks).settingsSwitchStyle()
            }
            RowDivider()
            SettingsRow(title: "メタデータ保存",
                        help: ".DS_Store / .localized / .Spotlight-V100 などの macOS が作る隠しファイルを書庫に含めます。オフにすると除外します（配布用の書庫を作るときはオフが無難です）。") {
                Toggle("", isOn: $model.settings.general.preserveMetadata).settingsSwitchStyle()
            }
            RowDivider()
            SettingsRow(title: "マルチスレッド処理",
                        help: "CPU のコアを使い切って高速化します。オフにすると遅くなりますが、他の作業の邪魔をしにくくなります。") {
                Toggle("", isOn: $model.settings.general.multithreaded).settingsSwitchStyle()
            }
            RowDivider()
            SettingsRow(title: "処理後のファイル検証",
                        help: "作成した書庫を読み直して壊れていないか確認します。暗号化した書庫は、7-Zip の検証コマンドがパスワードを安全に受け取れないため検証を省略し、結果に「検証スキップ」と表示します。") {
                Toggle("", isOn: $model.settings.general.verifyAfterProcessing).settingsSwitchStyle()
            }
            RowDivider()
            SettingsRow(title: "圧縮後に元のファイルを削除",
                        help: "書庫が問題なく作られたときだけ、元のファイルを「ゴミ箱」へ移します（完全削除ではないので戻せます）。警告が出た場合や失敗した場合は削除しません。") {
                Toggle("", isOn: $model.settings.general.deleteSourceAfterCompress).settingsSwitchStyle()
            }
        }

        SettingsGroup(header: "展開設定") {
            SettingsRow(title: "展開後のサイズ制限",
                        help: "書庫が申告する展開後の合計サイズがこれを超えると展開しません（例: 10g）。空欄なら上限なしですが、ディスクの空き容量が足りない場合は常に中止します。") {
                TextField("空欄ならサイズ制限しません",
                          text: $model.settings.general.extractionSizeLimitText)
                    .settingsFieldStyle(width: 170)
            }
            RowDivider()
            SettingsRow(title: "展開時の同名ファイルの上書き",
                        help: "オン: 展開先に同じ名前があれば置き換えます（元のものは「ゴミ箱」へ移すので戻せます）。オフ: 「名前 2」のように空いている名前を使い、既存のものに触りません（既定）。") {
                Toggle("", isOn: $model.settings.general.overwriteOnExtract).settingsSwitchStyle()
            }
            RowDivider()
            SettingsRow(title: "フォルダを作成して展開",
                        help: "展開結果が必ずフォルダ 1 つになるようにします。書庫の中身が既にフォルダ 1 つならそれをそのまま使うので、Docs/Docs のような二重フォルダにはなりません。中身がファイル 1 つ、または複数ある場合に書庫名のフォルダを作ります。オフにすると、中身が 1 つならファイルでもそのまま置きます。") {
                Toggle("", isOn: $model.settings.general.createContainingFolder).settingsSwitchStyle()
            }
            RowDivider()
            SettingsRow(title: "再帰的に展開",
                        help: "tar.gz / tar.bz2 / tar.xz のように二重になっている書庫を、中の .tar まで続けて展開します。オフにすると .tar が残ります。") {
                Toggle("", isOn: $model.settings.general.extractRecursively).settingsSwitchStyle()
            }
        }

        if let error = model.settingsError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - per format

private struct FormatSettingsTab: View {
    @Bindable var model: AppModel
    let format: ArchiveFormat

    private var binding: Binding<FormatSettings> {
        switch format {
        case .sevenZip: $model.settings.sevenZip
        case .zip: $model.settings.zip
        }
    }

    private var label: String { format == .sevenZip ? "7Zip" : "Zip" }

    var body: some View {
        if format != model.settings.general.format {
            Label("いまの出力形式は \(model.settings.general.format.rawValue.uppercased()) です。ここの設定は「形式」を \(label) にしたときに使われます。",
                  systemImage: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        SettingsGroup(header: "圧縮設定（\(label)）") {
            SettingsRow(title: "圧縮率",
                        help: "0 は無圧縮（コピーのみ）で最速、9 は最も小さくなりますが時間とメモリを使います。") {
                Picker("", selection: binding.level) {
                    ForEach(CompressionLevel.allCases) { Text($0.displayName).tag($0) }
                }
                .settingsPickerStyle()
            }
            if format.supportsHeaderEncryption {
                RowDivider()
                SettingsRow(title: "ファイル名の暗号化",
                            help: "7z のみ可能です。オンにすると、パスワードなしでは中身のファイル名すら見られなくなります。パスワードを設定したときだけ効きます。") {
                    Toggle("", isOn: binding.encryptFileNames).settingsSwitchStyle()
                }
            }
            RowDivider()
            SettingsRow(title: "パスワード",
                        help: passwordHelp) {
                Picker("", selection: binding.passwordMode) {
                    ForEach(PasswordMode.allCases) { Text($0.displayName).tag($0) }
                }
                .settingsPickerStyle()
            }
            // Directly under the mode it belongs to, so the pair reads as one setting.
            if binding.wrappedValue.passwordMode == .shared {
                RowDivider()
                SettingsRow(title: "共通パスワード",
                            help: "「毎回共通」で使うパスワードです。キーチェーンに保存され、Mac のロックが解除されているときだけ読み出されます。iCloud には同期しません。") {
                    HStack(spacing: 6) {
                        if model.hasSharedPassword {
                            Label("設定済み", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11)).foregroundStyle(.green)
                            Button("変更…") { model.requestSharedPasswordChange() }
                                .controlSize(.small)
                            Button("削除") { model.clearSharedPassword() }
                                .controlSize(.small)
                        } else {
                            Button("設定…") { model.requestSharedPasswordChange() }
                                .controlSize(.small)
                        }
                    }
                }
            }
            RowDivider()
            SettingsRow(title: "分割サイズ", help: splitHelp) {
                TextField("空欄なら分割しない", text: binding.splitSizeText)
                    .settingsFieldStyle()
            }
        }

        SettingsGroup(header: "実行されるコマンド（\(label)）") {
            Text(model.commandPreview(for: format))
                .font(.system(size: 10, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(SettingsMetrics.blockInset)
        }

        if let error = model.settingsError {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var passwordHelp: String {
        """
        「しない」= 暗号化しません。
        「都度質問」= 圧縮を始める前に毎回ダイアログで入力します。
        「毎回共通」= 保存した 1 つのパスワードを常に使います。
        暗号化した書庫を展開するときは、いずれの設定でもダイアログで入力を求めます。
        """
    }

    private var splitHelp: String {
        let common = "例: 100m / 700MB / 2g（k・m・g は 1024 進）。空欄なら分割しません。出力は .\(format.fileExtension).001 から連番になります。"
        guard format == .zip else { return common }
        return common + "\nzip の分割は 7-Zip 方式の単純分割です。他のツールで開くには、全パートを結合してください（例: cat name.zip.0* > name.zip）。"
    }
}

// MARK: - destination

private struct DestinationControl: View {
    @Binding var destination: DestinationMode

    private enum Kind: Hashable { case sameAsSource, fixed }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 6) {
                if destination.fixedURL != nil {
                    Button("変更…") { chooseFolder() }.controlSize(.small)
                }
                Picker("", selection: kind) {
                    Text("元ファイルと同じ場所").tag(Kind.sameAsSource)
                    Text("指定フォルダ").tag(Kind.fixed)
                }
                .settingsPickerStyle()
            }
            if case .fixedDirectory(let url) = destination {
                // Under the button rather than in front of it: the full path needs the
                // row's whole width, and squeezing it beside the controls meant showing
                // only the last component.
                Text(Self.display(url))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .multilineTextAlignment(.trailing)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .explains(url.path)
            }
        }
    }

    /// `~` for the home directory, the way every other Mac app shows a path.
    private static func display(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private var kind: Binding<Kind> {
        Binding(
            get: { destination == .sameAsSource ? .sameAsSource : .fixed },
            set: { newValue in
                switch newValue {
                case .sameAsSource: destination = .sameAsSource
                case .fixed: if destination.fixedURL == nil { chooseFolder() }
                }
            })
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "このフォルダを使う"
        if panel.runModal() == .OK, let url = panel.url {
            destination = .fixedDirectory(url)
        }
    }
}
