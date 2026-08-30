import Foundation

public struct ArchiveEntry: Equatable, Sendable {
    public let path: String
    /// Uncompressed size, as declared by the archive (contract #29).
    public let size: Int64
    public let packedSize: Int64
    public let isDirectory: Bool
    public let isSymlink: Bool
    public let isEncrypted: Bool

    public init(path: String, size: Int64, packedSize: Int64,
                isDirectory: Bool, isSymlink: Bool, isEncrypted: Bool) {
        self.path = path
        self.size = size
        self.packedSize = packedSize
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.isEncrypted = isEncrypted
    }

    /// Accepts only the shape a legitimate entry has, rather than blacklisting the
    /// tricks we happen to know about (contract #26).
    ///
    /// 7-Zip 26.02 already neutralises `..` and leading `/` — but it does so silently,
    /// with exit 0, quietly writing the file somewhere else. This check exists so such an
    /// archive is refused and reported instead of surprising the user, and so the app
    /// does not depend on that behaviour staying correct in future versions.
    public static func isSafePath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        guard !path.contains("\0") else { return false }
        guard !path.contains("\\") else { return false }   // Windows separators
        guard !path.hasPrefix("/") else { return false }
        guard !path.hasSuffix("/") else { return false }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        // A leading "C:" style drive specifier.
        if let first = components.first, first.count == 2,
           first.first?.isLetter == true, first.last == ":" {
            return false
        }
        for component in components {
            // "." is what `tar cf x.tar .` puts in front of every entry and it cannot
            // traverse anywhere, so rejecting it would refuse perfectly ordinary archives.
            // ".." is the one that has to go.
            if component.isEmpty || component == ".." { return false }
        }
        return true
    }
}

public struct ArchiveListing: Equatable, Sendable {
    public let format: String?
    /// Size of the archive itself, as 7zz reports it.
    public let physicalSize: Int64
    public let entries: [ArchiveEntry]

    public init(format: String?, physicalSize: Int64, entries: [ArchiveEntry]) {
        self.format = format
        self.physicalSize = physicalSize
        self.entries = entries
    }

    public var fileEntries: [ArchiveEntry] { entries.filter { !$0.isDirectory } }
    public var totalUncompressedSize: Int64 { fileEntries.reduce(0) { $0 + $1.size } }
    public var containsEncryptedEntries: Bool { entries.contains(where: \.isEncrypted) }
    public var symlinkPaths: [String] { entries.filter(\.isSymlink).map(\.path) }
    public var unsafePaths: [String] { entries.map(\.path).filter { !ArchiveEntry.isSafePath($0) } }
    public var isSafeToExtract: Bool { unsafePaths.isEmpty }

    public var expansionRatio: Double {
        physicalSize > 0 ? Double(totalUncompressedSize) / Double(physicalSize) : 0
    }
}

/// Parses `7zz l -slt` output.
///
/// Everything before the `----------` line describes the archive itself; entries follow
/// as blank-line separated `Key = Value` blocks. Values can be empty
/// (`Packed Size = ` happens for entries inside a solid block).
public enum ArchiveListingParser {
    private static let separator = "----------"

    public static func parse(_ text: String) -> ArchiveListing {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let separatorIndex = lines.firstIndex(where: { $0.hasPrefix(separator) }) else {
            return ArchiveListing(format: nil, physicalSize: 0, entries: [])
        }

        let header = fields(in: lines[lines.startIndex..<separatorIndex])
        var entries: [ArchiveEntry] = []
        var block: [String: String] = [:]

        func flush() {
            defer { block = [:] }
            guard let path = block["Path"], !path.isEmpty else { return }
            entries.append(makeEntry(path: path, fields: block))
        }

        for line in lines[(separatorIndex + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if let (key, value) = keyValue(line) {
                block[key] = value
            }
        }
        flush()

        return ArchiveListing(
            format: header["Type"],
            physicalSize: Int64(header["Physical Size"] ?? "") ?? 0,
            entries: entries)
    }

    private static func makeEntry(path: String, fields block: [String: String]) -> ArchiveEntry {
        let attributes = block["Attributes"] ?? ""
        // "D drwxr-xr-x" / "A lrwxr-xr-x" / "A -rw-r--r--" / "A"
        let parts = attributes.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let unixMode = parts.count > 1 ? parts[1] : ""
        let dosFlags = parts.first ?? ""

        return ArchiveEntry(
            path: path,
            size: Int64(block["Size"] ?? "") ?? 0,
            packedSize: Int64(block["Packed Size"] ?? "") ?? 0,
            isDirectory: dosFlags.hasPrefix("D") || unixMode.hasPrefix("d") || block["Folder"] == "+",
            isSymlink: unixMode.hasPrefix("l"),
            isEncrypted: block["Encrypted"] == "+")
    }

    private static func fields(in lines: some Sequence<String>) -> [String: String] {
        var result: [String: String] = [:]
        for line in lines {
            if let (key, value) = keyValue(line) { result[key] = value }
        }
        return result
    }

    private static func keyValue(_ line: String) -> (String, String)? {
        guard let range = line.range(of: " = ") else { return nil }
        let key = String(line[line.startIndex..<range.lowerBound])
        let value = String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.contains(" = ") else { return nil }
        return (key, value)
    }
}
