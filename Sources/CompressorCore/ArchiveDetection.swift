import Foundation

/// What a drop should do.
public enum DropMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case auto
    case compress
    case extract

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: "自動判別（書庫なら展開・それ以外は圧縮）"
        case .compress: "常に圧縮"
        case .extract: "常に展開"
        }
    }

    /// Short form for the settings row, where the column is narrow.
    public var shortName: String {
        switch self {
        case .auto: "自動"
        case .compress: "圧縮"
        case .extract: "展開"
        }
    }
}

public enum DropAction: Equatable, Sendable {
    case compress([URL])
    case extract([URL])
}

public enum DropClassifier {
    /// Auto mode is deliberately all-or-nothing: a drop is an extraction only when
    /// *every* item looks like an archive. Mixed drops compress, because wrapping an
    /// archive together with other files is a legitimate thing to want.
    public static func classify(_ urls: [URL], mode: DropMode) -> DropAction? {
        guard !urls.isEmpty else { return nil }
        switch mode {
        case .compress: return .compress(urls)
        case .extract: return .extract(urls)
        case .auto:
            return urls.allSatisfy(ArchiveDetection.looksLikeArchive) ? .extract(urls) : .compress(urls)
        }
    }
}

public enum ArchiveDetection {
    /// Extensions we are willing to extract **automatically**.
    ///
    /// Contract #33: the bundled 7zz can also open `exe`, `dmg`, `iso`, `docx`, `apk`,
    /// `jar` and friends, but nobody drops those meaning "unpack this", so they are left
    /// out of auto mode. Choosing "常に展開" hands the file to 7-Zip regardless.
    public static let autoExtractExtensions: Set<String> = [
        "7z", "zip", "rar", "r00", "tar", "gz", "gzip", "tgz", "tpz",
        "bz2", "bzip2", "tbz", "tbz2", "xz", "txz", "zst", "tzst",
        "lzma", "cab", "arj", "lzh", "lha", "cpio", "wim", "swm", "z", "taz",
    ]

    /// Formats that compress exactly one stream, so a second unwrap is predictable
    /// (contract #32: `foo.tar.gz` leaves a `foo.tar` behind after one pass).
    public static let singleStreamExtensions: Set<String> = [
        "gz", "gzip", "tgz", "tpz", "bz2", "bzip2", "tbz", "tbz2",
        "xz", "txz", "zst", "tzst", "lzma", "z", "taz",
    ]

    public static func looksLikeArchive(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard !name.isEmpty else { return false }
        let extensions = archiveExtensionChain(of: name)
        return !extensions.isEmpty
    }

    public static func isSingleStreamCompressor(_ url: URL) -> Bool {
        singleStreamExtensions.contains(url.pathExtension.lowercased())
    }

    /// `big.7z.004` → `big.7z.001`, which is the only part 7zz will open (contract #31).
    /// Returns nil when the URL is not a follow-on volume part.
    public static func firstVolume(of url: URL) -> URL? {
        let suffix = url.pathExtension
        guard isVolumeNumber(suffix), suffix != "001" else { return nil }
        let stem = url.deletingPathExtension()
        guard autoExtractExtensions.contains(stem.pathExtension.lowercased()) else { return nil }
        return stem.appendingPathExtension("001")
    }

    /// The name the extracted content should get: every archive layer stripped.
    public static func payloadName(for url: URL) -> String {
        var name = url.lastPathComponent
        // Bounded: each pass removes one extension.
        for _ in 0..<8 {
            let candidate = URL(fileURLWithPath: name)
            let ext = candidate.pathExtension.lowercased()
            guard !ext.isEmpty else { break }
            guard autoExtractExtensions.contains(ext) || isVolumeNumber(ext) else { break }
            let stripped = candidate.deletingPathExtension().lastPathComponent
            guard !stripped.isEmpty else { break }
            name = stripped
        }
        return name
    }

    private static func isVolumeNumber(_ text: String) -> Bool {
        (1...4).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The recognised archive extensions of a name, outermost first. Empty when the name
    /// is not an archive at all.
    private static func archiveExtensionChain(of name: String) -> [String] {
        var chain: [String] = []
        var current = name
        for _ in 0..<8 {
            let candidate = URL(fileURLWithPath: current)
            let ext = candidate.pathExtension.lowercased()
            guard !ext.isEmpty else { break }
            if autoExtractExtensions.contains(ext) {
                chain.append(ext)
            } else if isVolumeNumber(ext), chain.isEmpty {
                // A numeric suffix only counts when what is underneath is an archive.
                let stem = candidate.deletingPathExtension()
                guard autoExtractExtensions.contains(stem.pathExtension.lowercased()) else { break }
                chain.append(ext)
            } else {
                break
            }
            let stripped = candidate.deletingPathExtension().lastPathComponent
            guard !stripped.isEmpty else { break }
            current = stripped
        }
        return chain
    }
}
