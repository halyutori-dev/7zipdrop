import Foundation

/// How the dropped items will be handed to 7zz.
///
/// Contract #6/#7: absolute paths get collapsed to bare basenames by 7zz, and two
/// items with the same basename make it die with `Duplicate filename on disk`. So we
/// run 7zz with its working directory set to the items' common parent and pass
/// **relative** names, which both preserves structure and keeps names distinct.
public struct InputPlan: Equatable, Sendable {
    public let workingDirectory: URL
    public let relativeNames: [String]
    public let commonParentName: String?

    public var itemCount: Int { relativeNames.count }

    public init(workingDirectory: URL, relativeNames: [String], commonParentName: String?) {
        self.workingDirectory = workingDirectory
        self.relativeNames = relativeNames
        self.commonParentName = commonParentName
    }

    public static func make(from urls: [URL]) throws -> InputPlan {
        guard !urls.isEmpty else { throw InputPlanError.noInputs }

        var seen = Set<String>()
        var paths: [String] = []
        for url in urls {
            guard url.isFileURL else { throw InputPlanError.notAFileURL(url.absoluteString) }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix("/"), path != "/" else { throw InputPlanError.notAFileURL(path) }
            if seen.insert(path).inserted { paths.append(path) }
        }
        paths.sort()
        paths = pruneDescendants(of: paths)

        let parents = paths.map { ($0 as NSString).deletingLastPathComponent }
        let ancestorComponents = commonPrefix(of: parents.map(Self.components))
        guard !ancestorComponents.isEmpty else { throw InputPlanError.commonAncestorIsRoot }

        let workingPath = "/" + ancestorComponents.joined(separator: "/")
        let names = paths.map { String($0.dropFirst(workingPath.count + 1)) }

        return InputPlan(
            workingDirectory: URL(fileURLWithPath: workingPath, isDirectory: true),
            relativeNames: names,
            commonParentName: ancestorComponents.last
        )
    }

    /// Dropping a folder *and* something inside it would make 7zz see the inner item
    /// twice, which is fatal (contract #6). The folder already covers it recursively
    /// (contract #8), so the redundant descendant is removed.
    private static func pruneDescendants(of sortedPaths: [String]) -> [String] {
        var kept: [String] = []
        for path in sortedPaths {
            if let last = kept.last, path.hasPrefix(last + "/") { continue }
            kept.append(path)
        }
        return kept
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func commonPrefix(of lists: [[String]]) -> [String] {
        guard var common = lists.first else { return [] }
        for list in lists.dropFirst() {
            var i = 0
            while i < min(common.count, list.count), common[i] == list[i] { i += 1 }
            common = Array(common.prefix(i))
            if common.isEmpty { break }
        }
        return common
    }
}
