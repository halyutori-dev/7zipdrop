import Foundation

public enum ArchiveFormat: String, Codable, CaseIterable, Sendable, Identifiable {
    case sevenZip = "7z"
    case zip

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }
    public var typeSwitch: String { "-t\(rawValue)" }

    /// Only 7z can encrypt the file list itself (contract #5).
    public var supportsHeaderEncryption: Bool { self == .sevenZip }

    /// zip defaults to the broken ZipCrypto cipher and must be told to use AES-256 (contract #4).
    public var needsExplicitAESSwitch: Bool { self == .zip }

    public var displayName: String {
        switch self {
        case .sevenZip: "7z（圧縮率が高い・AES-256・ファイル名も暗号化可）"
        case .zip: "zip（どこでも開ける・AES-256）"
        }
    }
}

public enum CompressionLevel: Int, Codable, CaseIterable, Sendable, Identifiable {
    /// Only values that are legal for **both** 7z and zip (contract #18).
    case store = 0
    case fastest = 1
    case fast = 3
    case normal = 5
    case maximum = 7
    case ultra = 9

    public var id: Int { rawValue }
    public var methodSwitch: String { "-mx=\(rawValue)" }

    public var displayName: String {
        switch self {
        case .store: "0 — 無圧縮（格納のみ・最速）"
        case .fastest: "1 — 最速"
        case .fast: "3 — 高速"
        case .normal: "5 — 標準"
        case .maximum: "7 — 高圧縮"
        case .ultra: "9 — 最高圧縮（遅い・メモリ多め）"
        }
    }
}
