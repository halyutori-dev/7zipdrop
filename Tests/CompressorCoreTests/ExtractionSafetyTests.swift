import Foundation
import Testing
@testable import CompressorCore

@Suite("Path containment (pure)")
struct PathContainmentTests {

    @Test("a path inside the base is contained; a sibling with a shared prefix is not")
    func containment() {
        #expect(PathContainment.isContained("/a/b/c", within: "/a/b"))
        #expect(PathContainment.isContained("/a/b", within: "/a/b"))
        #expect(!PathContainment.isContained("/a/bb/c", within: "/a/b"),
                "a shared string prefix is not a shared path prefix")
        #expect(!PathContainment.isContained("/a", within: "/a/b"))
        #expect(!PathContainment.isContained("/x/y", within: "/a/b"))
    }

    @Test("relative link targets resolve against the link's own directory")
    func resolvesRelativeTargets() {
        #expect(PathContainment.resolve(target: "sibling.txt", relativeTo: "/a/b") == "/a/b/sibling.txt")
        #expect(PathContainment.resolve(target: "../up.txt", relativeTo: "/a/b") == "/a/up.txt")
        #expect(PathContainment.resolve(target: "../../../../etc/passwd", relativeTo: "/a/b") == "/etc/passwd")
        #expect(PathContainment.resolve(target: "./x", relativeTo: "/a/b") == "/a/b/x")
    }

    @Test("absolute link targets ignore the containing directory")
    func resolvesAbsoluteTargets() {
        #expect(PathContainment.resolve(target: "/etc/hosts", relativeTo: "/a/b") == "/etc/hosts")
    }

    @Test("climbing above the root does not underflow")
    func doesNotUnderflow() {
        #expect(PathContainment.resolve(target: "../../../../../..", relativeTo: "/a") == "/")
    }
}

/// The engine's post-extraction containment check, exercised directly.
///
/// Contract #38: no archive could be built that gets an escaping symlink past 7-Zip 26.02
/// itself, so this layer cannot be reached end to end. It exists to catch a regression in
/// 7-Zip — which means it has to be tested here, or it would be untested code.
@Suite("Symlink containment check")
struct SymlinkContainmentTests {

    private let engine = ExtractionEngine()

    private func makeTree() throws -> URL {
        let root = try TestSupport.makeTemporaryDirectory()
        let content = root.appendingPathComponent("content", isDirectory: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try TestSupport.write("real", to: content.appendingPathComponent("sub/real.txt"))
        return content
    }

    @Test func acceptsATreeWithNoLinks() throws {
        try engine.assertNoSymlinkEscapes(in: try makeTree())
    }

    @Test func acceptsLinksThatStayInside() throws {
        let content = try makeTree()
        try FileManager.default.createSymbolicLink(
            atPath: content.appendingPathComponent("inside-relative").path,
            withDestinationPath: "sub/real.txt")
        try FileManager.default.createSymbolicLink(
            atPath: content.appendingPathComponent("inside-absolute").path,
            withDestinationPath: content.appendingPathComponent("sub/real.txt").path)
        try engine.assertNoSymlinkEscapes(in: content)
    }

    @Test func rejectsARelativeLinkThatClimbsOut() throws {
        let content = try makeTree()
        try FileManager.default.createSymbolicLink(
            atPath: content.appendingPathComponent("escape").path,
            withDestinationPath: "../../../../../../etc")
        #expect(throws: (any Error).self) { try self.engine.assertNoSymlinkEscapes(in: content) }
    }

    @Test func rejectsAnAbsoluteLinkPointingOutside() throws {
        let content = try makeTree()
        try FileManager.default.createSymbolicLink(
            atPath: content.appendingPathComponent("escape").path,
            withDestinationPath: "/etc/hosts")
        #expect(throws: (any Error).self) { try self.engine.assertNoSymlinkEscapes(in: content) }
    }

    @Test("a link buried deep in the tree is found too")
    func findsNestedEscapes() throws {
        let content = try makeTree()
        let deep = content.appendingPathComponent("a/b/c", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            atPath: deep.appendingPathComponent("escape").path,
            withDestinationPath: "../../../../../../../tmp")
        #expect(throws: (any Error).self) { try self.engine.assertNoSymlinkEscapes(in: content) }
    }

    @Test("""
    the walk never follows a link, so a directory link pointing outside cannot steer it \
    into the rest of the filesystem
    """)
    func doesNotWalkThroughLinks() throws {
        let content = try makeTree()
        let outside = try TestSupport.makeTemporaryDirectory()
        try TestSupport.write("x", to: outside.appendingPathComponent("victim.txt"))
        // the link itself is an escape, so this must throw — and it must throw from the
        // link check rather than from wandering into `outside`
        try FileManager.default.createSymbolicLink(
            atPath: content.appendingPathComponent("door").path,
            withDestinationPath: outside.path)
        #expect(throws: (any Error).self) { try self.engine.assertNoSymlinkEscapes(in: content) }
        #expect(TestSupport.entryNames(in: outside) == ["victim.txt"], "nothing outside was touched")
    }
}
