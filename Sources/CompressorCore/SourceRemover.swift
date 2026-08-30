import Foundation

public protocol SourceRemoving: Sendable {
    /// Removes an item the user asked to be cleaned up, and reports where it went.
    func remove(_ url: URL) throws -> URL?
}

/// Moves items to the Trash rather than unlinking them.
///
/// 7-Zip has `-sdel` for this, but it deletes outright. Compression is something a drag
/// and drop can start by accident, so the removal is made recoverable: the originals sit
/// in the Trash until the user empties it.
public struct TrashSourceRemover: SourceRemoving {
    public init() {}

    public func remove(_ url: URL) throws -> URL? {
        var trashedURL: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashedURL)
        return trashedURL as URL?
    }
}
