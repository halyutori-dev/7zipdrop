import Foundation

/// 7-Zip's documented exit codes (contract #17).
///
/// `warning` is the dangerous one: 7zz returns 1 when it could not read some input
/// file, and the archive it produced is **missing that file** (contract #14). It is
/// therefore never treated as success.
public enum SevenZipExitStatus: Equatable, Sendable {
    case success
    case warning
    case fatal
    case commandLineError
    case outOfMemory
    case cancelled
    case unknown(Int32)

    public init(code: Int32) {
        switch code {
        case 0: self = .success
        case 1: self = .warning
        case 2: self = .fatal
        case 7: self = .commandLineError
        case 8: self = .outOfMemory
        case 255: self = .cancelled
        default: self = .unknown(code)
        }
    }

    public var isSuccess: Bool { self == .success }

    /// True when 7zz actually left a readable archive behind.
    public var isUsableArchive: Bool { self == .success || self == .warning }

    public var message: String {
        switch self {
        case .success: "成功"
        case .warning: "警告あり（読み取れなかったファイルが書庫に入っていない可能性があります）"
        case .fatal: "致命的なエラー"
        case .commandLineError: "コマンドラインの指定が不正"
        case .outOfMemory: "メモリ不足"
        case .cancelled: "中断（ユーザー操作）"
        case .unknown(let code): "不明な終了コード \(code)"
        }
    }
}
