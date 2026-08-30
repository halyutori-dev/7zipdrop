import Foundation

public protocol FileMoving: Sendable {
    /// Moves a **file** to `destination`, failing if `destination` is already taken.
    func claim(from source: URL, to destination: URL) throws
    /// Moves a **directory** to `destination`, failing if `destination` is already taken.
    func claimDirectory(from source: URL, to destination: URL) throws
}

/// Claims a destination name with `renamex_np(..., RENAME_EXCL)`, which fails with
/// `EEXIST` **atomically** rather than replacing what is already there.
///
/// `FileManager.moveItem` checks for existence and then renames, leaving a window in
/// which another process can create the file — and plain `rename(2)` would overwrite it
/// silently.
///
/// `link(2)` was used here at first, and it works in `/tmp` — but macOS refuses to create
/// a new hard link directly inside a protected user folder: measured on macOS 26.5,
/// `link()` into `~/Downloads` fails with `EPERM` while the same call inside a
/// subdirectory of it succeeds, and `renamex_np` succeeds either way. Since the whole
/// point of this step is to put the result into folders like Downloads, Desktop and
/// Documents, rename is the operation that has to be used.
public struct AtomicFileMover: FileMoving {
    public init() {}

    public func claim(from source: URL, to destination: URL) throws {
        try exclusiveRename(from: source, to: destination)
    }

    public func claimDirectory(from source: URL, to destination: URL) throws {
        try exclusiveRename(from: source, to: destination)
    }

    private func exclusiveRename(from source: URL, to destination: URL) throws {
        let result = source.withUnsafeFileSystemRepresentation { sourcePath -> Int32 in
            destination.withUnsafeFileSystemRepresentation { destinationPath -> Int32 in
                guard let sourcePath, let destinationPath else { return EINVAL }
                return renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
            }
        }
        switch result {
        case 0:
            return
        case EEXIST, ENOTEMPTY:
            throw CompressorError.destinationExists(destination.path)
        default:
            throw CompressorError.linkFailed(code: result, path: destination.path)
        }
    }
}
