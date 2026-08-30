import Foundation

public struct ExtractionSettings: Equatable, Sendable {
    public var destination: DestinationMode
    /// Guarantee that the result is a single folder rather than loose items.
    ///
    /// On: a single root *folder* in the archive already satisfies that and is used as-is
    /// (`Docs.7z` → `Docs/`, never `Docs/Docs/`); a single root *file*, or several roots,
    /// get a folder created around them.
    /// Off: a single root item — file or folder — is delivered exactly as it is.
    public var guaranteeContainingFolder: Bool
    /// Off by default: an archive whose entry paths try to escape is refused, not
    /// silently rewritten by 7-Zip (contract #26).
    public var allowUnsafeEntryPaths: Bool
    /// Refuse anything that claims to expand beyond this, whatever the disk says.
    public var maximumTotalBytes: Int64
    /// `foo.tar.gz` should end up as a folder, not as `foo.tar` (contract #32).
    public var followSingleStreamArchives: Bool
    /// On: replace an existing item of the same name (the old one goes to the Trash).
    /// Off: pick a free name instead, so nothing is ever lost.
    public var overwriteExisting: Bool
    public var revealInFinder: Bool
    public var notifyOnCompletion: Bool

    public static let `default` = ExtractionSettings(
        destination: .sameAsSource,
        guaranteeContainingFolder: true,
        allowUnsafeEntryPaths: false,
        maximumTotalBytes: 10 * 1024 * 1024 * 1024,   // 10 GiB
        followSingleStreamArchives: true,
        overwriteExisting: false,
        revealInFinder: true,
        notifyOnCompletion: true
    )
}

extension ExtractionSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case destination, guaranteeContainingFolder, allowUnsafeEntryPaths, maximumTotalBytes
        case followSingleStreamArchives, overwriteExisting, revealInFinder, notifyOnCompletion
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ExtractionSettings.default
        destination = try c.decodeIfPresent(DestinationMode.self, forKey: .destination) ?? d.destination
        guaranteeContainingFolder = try c.decodeIfPresent(Bool.self, forKey: .guaranteeContainingFolder) ?? d.guaranteeContainingFolder
        allowUnsafeEntryPaths = try c.decodeIfPresent(Bool.self, forKey: .allowUnsafeEntryPaths) ?? d.allowUnsafeEntryPaths
        // A persisted zero or negative ceiling would disable extraction entirely; fall back.
        let ceiling = try c.decodeIfPresent(Int64.self, forKey: .maximumTotalBytes) ?? d.maximumTotalBytes
        maximumTotalBytes = ceiling > 0 ? ceiling : d.maximumTotalBytes
        followSingleStreamArchives = try c.decodeIfPresent(Bool.self, forKey: .followSingleStreamArchives) ?? d.followSingleStreamArchives
        overwriteExisting = try c.decodeIfPresent(Bool.self, forKey: .overwriteExisting) ?? d.overwriteExisting
        revealInFinder = try c.decodeIfPresent(Bool.self, forKey: .revealInFinder) ?? d.revealInFinder
        notifyOnCompletion = try c.decodeIfPresent(Bool.self, forKey: .notifyOnCompletion) ?? d.notifyOnCompletion
    }
}

public enum ExtractionSafety {
    /// Leave this much of the disk alone rather than extracting until it is full.
    public static let diskHeadroomBytes: Int64 = 1024 * 1024 * 1024

    public static func check(
        _ listing: ArchiveListing,
        settings: ExtractionSettings,
        availableBytes: Int64
    ) throws {
        if !settings.allowUnsafeEntryPaths, !listing.isSafeToExtract {
            throw CompressorError.unsafeEntryPaths(listing.unsafePaths)
        }
        let total = listing.totalUncompressedSize
        guard total <= settings.maximumTotalBytes else {
            throw CompressorError.extractionTooLarge(
                totalBytes: total, limitBytes: settings.maximumTotalBytes)
        }
        let usable = availableBytes - diskHeadroomBytes
        guard total <= usable else {
            throw CompressorError.notEnoughDiskSpace(
                neededBytes: total, availableBytes: availableBytes)
        }
    }
}

/// Pure path containment test, used to prove an extracted symlink cannot point outside
/// the staging directory (contract #30: the listing never reveals link targets, so this
/// has to be checked on the real tree afterwards).
public enum PathContainment {
    public static func isContained(_ candidate: String, within base: String) -> Bool {
        let baseComponents = normalise(base)
        let candidateComponents = normalise(candidate)
        guard candidateComponents.count >= baseComponents.count else { return false }
        return Array(candidateComponents.prefix(baseComponents.count)) == baseComponents
    }

    /// Resolves `.` and `..` logically, without touching the filesystem — the target of a
    /// malicious symlink often does not exist, so `realpath` is not usable here.
    public static func resolve(target: String, relativeTo directory: String) -> String {
        let combined = target.hasPrefix("/") ? target : directory + "/" + target
        return "/" + normalise(combined).joined(separator: "/")
    }

    private static func normalise(_ path: String) -> [String] {
        var stack: [String] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !stack.isEmpty { stack.removeLast() }
            default: stack.append(String(component))
            }
        }
        return stack
    }
}

/// Picks an unused name in a directory, preserving any extension.
///
/// Deliberately simpler than `ArchiveNamer`: that one also treats `name.7z.001` as
/// occupying `name.7z`, which is right when creating volumes but wrong here — extracting
/// `Docs.7z` into a folder called `Docs` must not be blocked by `Docs.7z` itself.
public enum UniqueName {
    public static let maximumAttempts = 999

    public static func pick(
        stem: String, extension fileExtension: String, in directory: URL, probe: any FileSystemProbing
    ) throws -> URL {
        let safeStem = ArchiveNamer.clamp(
            ArchiveNamer.sanitize(stem), extensionLength: fileExtension.utf8.count)
        for attempt in 1...maximumAttempts {
            let base = attempt == 1 ? safeStem : "\(safeStem) \(attempt)"
            let name = fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
            let url = directory.appendingPathComponent(name)
            if !probe.fileExists(at: url) { return url }
        }
        throw ArchiveNamingError.tooManyCollisions(baseName: safeStem)
    }
}
