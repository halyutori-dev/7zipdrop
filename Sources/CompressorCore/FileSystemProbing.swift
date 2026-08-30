import Foundation

/// Read-only view of the filesystem, injected so naming logic is testable without disk I/O.
public protocol FileSystemProbing: Sendable {
    func fileExists(at url: URL) -> Bool
    func entryNames(inDirectory url: URL) -> [String]
}

public struct LiveFileSystemProbe: FileSystemProbing {
    public init() {}

    public func fileExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func entryNames(inDirectory url: URL) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
    }
}
