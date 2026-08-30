import Foundation

/// Finds the `7zz` executable, preferring the copy bundled inside the app.
///
/// Fail-closed: if nothing usable is found this returns `nil` and the caller reports
/// it, rather than falling back to some other archiver.
public struct SevenZipLocator: Sendable {
    public static let executableName = "7zz"

    /// Homebrew and MacPorts locations, used only when no bundled copy exists.
    public static let fallbackDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin",
    ].map { URL(fileURLWithPath: $0, isDirectory: true) }

    public init() {}

    /// - Parameters:
    ///   - override: an explicit path chosen by the user; tried first and never bypassed.
    ///   - bundled: candidate locations inside the running app bundle.
    public func locate(override: URL? = nil, bundled: [URL] = [], fallbacks: [URL]? = nil) -> URL? {
        var candidates: [URL] = []
        if let override { candidates.append(override) }
        candidates += bundled
        candidates += (fallbacks ?? Self.fallbackDirectories).map {
            $0.appendingPathComponent(Self.executableName)
        }
        return candidates.first(where: isUsable)
    }

    public func isUsable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        guard !isDirectory.boolValue else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }
}
