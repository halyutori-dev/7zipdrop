import Foundation

public enum PasswordError: Error, Equatable, LocalizedError {
    case empty
    case containsNewline
    case containsNUL

    public var errorDescription: String? {
        switch self {
        case .empty: "パスワードが空です。"
        case .containsNewline: "パスワードに改行を含めることはできません（7-Zip への受け渡し経路が1行のため）。"
        case .containsNUL: "パスワードに NUL 文字を含めることはできません。"
        }
    }
}

public enum SplitSizeError: Error, Equatable, LocalizedError {
    case malformed(String)
    case unknownUnit(String)
    case tooSmall(minimumBytes: Int64)
    case overflow

    public var errorDescription: String? {
        switch self {
        case .malformed(let text):
            "分割サイズ「\(text)」を解釈できません。例: 100m, 700MB, 2g, 4480m"
        case .unknownUnit(let unit):
            "分割サイズの単位「\(unit)」は使えません。b / k / m / g（1024進）のいずれかを指定してください。"
        case .tooSmall(let minimum):
            "分割サイズが小さすぎます（最小 \(minimum) バイト）。"
        case .overflow:
            "分割サイズが大きすぎます（最大 16 TiB）。"
        }
    }
}

public enum InputPlanError: Error, Equatable, LocalizedError {
    case noInputs
    case notAFileURL(String)
    case commonAncestorIsRoot

    public var errorDescription: String? {
        switch self {
        case .noInputs:
            "圧縮対象がありません。"
        case .notAFileURL(let s):
            "ファイル以外の項目はドロップできません: \(s)"
        case .commonAncestorIsRoot:
            "ドロップされた項目の共通の親フォルダがルート（/）になります。ボリュームをまたぐ選択はできません。別々にドロップするか、保存先を固定フォルダにして同じ場所の項目だけを選んでください。"
        }
    }
}

public enum ArchiveNamingError: Error, Equatable, LocalizedError {
    case tooManyCollisions(baseName: String)

    public var errorDescription: String? {
        switch self {
        case .tooManyCollisions(let base):
            "「\(base)」で使える空きの名前が見つかりませんでした（同名の書庫が多すぎます）。"
        }
    }
}

public enum CommandBuilderError: Error, Equatable, LocalizedError {
    case argumentListTooLarge(bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .argumentListTooLarge(let bytes, let limit):
            """
            ファイル数が多すぎてコマンドラインの上限を超えます（\(bytes) / \(limit) バイト）。
            個々のファイルではなく、それらを含むフォルダをドロップしてください（フォルダは1項目として再帰的に圧縮されます）。
            """
        }
    }
}

public enum CompressorError: Error, Equatable, LocalizedError {
    case sevenZipNotFound
    case sevenZipNotExecutable(String)
    case destinationNotWritable(String)
    case destinationIsNotADirectory(String)
    case destinationExists(String)
    case sevenZipFailed(status: SevenZipExitStatus, log: String)
    case verificationFailed(status: SevenZipExitStatus, log: String)
    case noArchiveProduced
    case cancelled
    case linkFailed(code: Int32, path: String)
    case passwordRequired
    case wrongPassword
    case listingFailed(status: SevenZipExitStatus, log: String)
    case extractionFailed(status: SevenZipExitStatus, log: String)
    case unsafeEntryPaths([String])
    case extractionTooLarge(totalBytes: Int64, limitBytes: Int64)
    case notEnoughDiskSpace(neededBytes: Int64, availableBytes: Int64)
    case symlinkEscapesDestination(entry: String, target: String)
    case nothingExtracted
    case missingVolumePart(String)

    public var errorDescription: String? {
        switch self {
        case .sevenZipNotFound:
            "7-Zip 実行ファイル (7zz) が見つかりません。設定でパスを指定してください。"
        case .sevenZipNotExecutable(let path):
            "7-Zip 実行ファイルに実行権限がありません: \(path)"
        case .destinationNotWritable(let path):
            "保存先に書き込めません: \(path)"
        case .destinationIsNotADirectory(let path):
            "保存先がフォルダではありません: \(path)"
        case .destinationExists(let path):
            "保存先に同名のファイルが既にあります: \(path)"
        case .sevenZipFailed(let status, let log):
            "圧縮に失敗しました（\(status.message)）。\n\(log)"
        case .verificationFailed(let status, let log):
            "作成後の検証に失敗しました（\(status.message)）。書庫は保存していません。\n\(log)"
        case .noArchiveProduced:
            "7-Zip は成功を返しましたが、書庫ファイルが作られていません。"
        case .cancelled:
            "キャンセルしました。"
        case .linkFailed(let code, let path):
            "保存先へのファイル作成に失敗しました (errno \(code)): \(path)"
        case .passwordRequired:
            "この書庫は暗号化されています。パスワードを入力してから再実行してください。"
        case .wrongPassword:
            "パスワードが違います。"
        case .listingFailed(let status, let log):
            "書庫の内容を読み取れませんでした（\(status.message)）。\n\(log)"
        case .extractionFailed(let status, let log):
            "展開に失敗しました（\(status.message)）。\n\(log)"
        case .unsafeEntryPaths(let paths):
            """
            この書庫には、展開先の外へ書き込もうとするパスが含まれています（\(paths.count) 件）。
            安全のため展開しませんでした: \(paths.prefix(5).joined(separator: ", "))
            信頼できる書庫だと分かっている場合のみ、詳細設定で許可できます。
            """
        case .extractionTooLarge(let total, let limit):
            """
            展開後のサイズが上限を超えます: \(ByteCountFormatter.string(fromByteCount: total, countStyle: .binary))             （上限 \(ByteCountFormatter.string(fromByteCount: limit, countStyle: .binary))）。
            意図した書庫であれば、詳細設定で上限を引き上げてください。
            """
        case .notEnoughDiskSpace(let needed, let available):
            """
            ディスクの空き容量が足りません。必要 \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .binary)) /             空き \(ByteCountFormatter.string(fromByteCount: available, countStyle: .binary))。
            """
        case .symlinkEscapesDestination(let entry, let target):
            """
            この書庫には展開先の外を指すシンボリックリンクが含まれていました: \(entry) → \(target)
            安全のため展開結果を破棄しました。
            """
        case .nothingExtracted:
            "書庫は開けましたが、展開されたファイルがありません。"
        case .missingVolumePart(let name):
            "分割書庫の先頭ファイルが見つかりません: \(name)"
        }
    }
}
