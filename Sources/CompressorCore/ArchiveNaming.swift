import Foundation

public enum ArchiveNaming {
    /// One item → its name without the last extension; several → the enclosing folder's name.
    public static func baseName(for plan: InputPlan) -> String {
        if plan.relativeNames.count == 1 {
            let name = (plan.relativeNames[0] as NSString).lastPathComponent
            let stem = (name as NSString).deletingPathExtension
            // A dotfile such as ".bashrc" has no usable stem, so keep the whole name.
            return (stem.isEmpty || stem == ".") ? name : stem
        }
        return plan.commonParentName ?? "Archive"
    }
}

/// Picks a destination name that is **not already in use**.
///
/// This is not cosmetic: contract #3 says `7zz a` on an existing archive silently
/// *appends* to it and still exits 0, so writing to a name that is already taken would
/// quietly merge unrelated files into someone else's archive.
public struct ArchiveNamer: Sendable {
    public static let maximumAttempts = 999
    private static let maximumNameBytes = 255

    private let probe: any FileSystemProbing

    public init(probe: any FileSystemProbing) {
        self.probe = probe
    }

    public func uniqueArchiveURL(baseName: String, format: ArchiveFormat, in directory: URL) throws -> URL {
        let base = Self.clamp(Self.sanitize(baseName), extensionLength: format.fileExtension.utf8.count)
        let existing = Set(probe.entryNames(inDirectory: directory))

        for attempt in 1...Self.maximumAttempts {
            let candidate = attempt == 1 ? base : "\(base) \(attempt)"
            let fileName = "\(candidate).\(format.fileExtension)"
            let url = directory.appendingPathComponent(fileName)

            // Taken by the plain archive, or by any volume part of it (contract #12).
            let volumePrefix = fileName + "."
            let occupied = existing.contains(fileName)
                || existing.contains { $0.hasPrefix(volumePrefix) }
                || probe.fileExists(at: url)
            if !occupied { return url }
        }
        throw ArchiveNamingError.tooManyCollisions(baseName: base)
    }

    static func sanitize(_ raw: String) -> String {
        var name = raw
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "." || name == ".." { name = "Archive" }
        return name
    }

    /// Keeps room for `.ext` plus a ` 999` collision suffix inside the 255-byte limit.
    static func clamp(_ name: String, extensionLength: Int) -> String {
        let reserve = 1 + extensionLength + 4
        let budget = maximumNameBytes - reserve
        guard name.utf8.count > budget else { return name }
        var result = ""
        var used = 0
        for character in name {
            let width = String(character).utf8.count
            if used + width > budget { break }
            result.append(character)
            used += width
        }
        return result.isEmpty ? "Archive" : result
    }
}
