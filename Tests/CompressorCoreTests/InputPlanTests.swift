import Foundation
import Testing
@testable import CompressorCore

@Suite("InputPlan — cwd + relative names (contract #6/#7)")
struct InputPlanTests {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    @Test func rejectsEmptyInput() {
        #expect(throws: InputPlanError.noInputs) { try InputPlan.make(from: []) }
    }

    @Test func singleFileUsesItsParentAsWorkingDirectory() throws {
        let p = try InputPlan.make(from: [u("/Users/me/Desktop/report.pdf")])
        #expect(p.workingDirectory.path == "/Users/me/Desktop")
        #expect(p.relativeNames == ["report.pdf"])
        #expect(p.commonParentName == "Desktop")
    }

    @Test func siblingsShareTheParentAndStayAsBasenames() throws {
        let p = try InputPlan.make(from: [
            u("/Users/me/Trip/a.jpg"), u("/Users/me/Trip/b.jpg"), u("/Users/me/Trip/sub"),
        ])
        #expect(p.workingDirectory.path == "/Users/me/Trip")
        #expect(p.relativeNames == ["a.jpg", "b.jpg", "sub"])
    }

    @Test func differentDirectoriesFallBackToTheCommonAncestor() throws {
        let p = try InputPlan.make(from: [
            u("/Users/me/Desktop/a.txt"), u("/Users/me/Documents/b.txt"),
        ])
        #expect(p.workingDirectory.path == "/Users/me")
        #expect(p.relativeNames == ["Desktop/a.txt", "Documents/b.txt"])
    }

    @Test("identical basenames from different directories must not collapse — 7zz fails fatally on that (contract #6)")
    func identicalBasenamesStayDistinct() throws {
        let p = try InputPlan.make(from: [
            u("/Users/me/Desktop/same.txt"), u("/Users/me/Documents/same.txt"),
        ])
        #expect(p.workingDirectory.path == "/Users/me")
        #expect(p.relativeNames == ["Desktop/same.txt", "Documents/same.txt"])
        #expect(Set(p.relativeNames).count == p.relativeNames.count)
    }

    @Test func deduplicatesRepeatedDrops() throws {
        let p = try InputPlan.make(from: [
            u("/Users/me/Trip/a.jpg"), u("/Users/me/Trip/a.jpg"), u("/Users/me/Trip/a.jpg"),
        ])
        #expect(p.relativeNames == ["a.jpg"])
        #expect(p.itemCount == 1)
    }

    @Test func normalisesTrailingSlashesAndDotSegments() throws {
        let p = try InputPlan.make(from: [
            URL(fileURLWithPath: "/Users/me/Trip/sub/", isDirectory: true),
            u("/Users/me/Trip/./other"),
        ])
        #expect(p.workingDirectory.path == "/Users/me/Trip")
        #expect(p.relativeNames.sorted() == ["other", "sub"])
    }

    @Test func namesAreSortedForDeterministicArchives() throws {
        let p = try InputPlan.make(from: [u("/x/c"), u("/x/a"), u("/x/b")])
        #expect(p.relativeNames == ["a", "b", "c"])
    }

    @Test("dropping items whose only common ancestor is / is refused rather than archiving from the root")
    func refusesRootLevelCommonAncestor() {
        #expect(throws: InputPlanError.commonAncestorIsRoot) {
            try InputPlan.make(from: [URL(fileURLWithPath: "/Users/me/a.txt"), URL(fileURLWithPath: "/Volumes/Ext/b.txt")])
        }
    }

    @Test func rejectsNonFileURLs() {
        #expect(throws: InputPlanError.notAFileURL("https://example.com/a.txt")) {
            try InputPlan.make(from: [URL(string: "https://example.com/a.txt")!])
        }
    }

    @Test("dropping a folder together with something inside it must not feed 7zz the same item twice")
    func prunesRedundantDescendants() throws {
        let p = try InputPlan.make(from: [u("/x/A"), u("/x/A/b.txt"), u("/x/A/sub/c.txt"), u("/x/d.txt")])
        #expect(p.relativeNames == ["A", "d.txt"])
    }

    @Test func unicodeNamesSurviveUnchanged() throws {
        let p = try InputPlan.make(from: [u("/Users/me/写真/夏 2026.jpg")])
        #expect(p.relativeNames == ["夏 2026.jpg"])
        #expect(p.commonParentName == "写真")
    }

    @Test func namesWithWildcardCharactersAreKeptVerbatim() throws {
        // contract #9: -spd makes these literal; the plan must not mangle them
        let p = try InputPlan.make(from: [u("/x/star[1]*name.txt"), u("/x/-dash.txt"), u("/x/@at.txt")])
        #expect(p.relativeNames == ["-dash.txt", "@at.txt", "star[1]*name.txt"])
    }
}

@Suite("Archive naming and never-overwrite (contract #3)")
struct ArchiveNamingTests {

    /// In-memory probe so naming logic is tested without touching the disk.
    private struct FakeProbe: FileSystemProbing {
        var existing: Set<String>
        func fileExists(at url: URL) -> Bool { existing.contains(url.path) }
        func entryNames(inDirectory url: URL) -> [String] {
            existing.compactMap { path in
                let parent = (path as NSString).deletingLastPathComponent
                return parent == url.path ? (path as NSString).lastPathComponent : nil
            }
        }
    }

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }
    private let dir = URL(fileURLWithPath: "/out", isDirectory: true)

    // MARK: base name derivation

    @Test func singleFileDropsItsExtension() throws {
        let plan = try InputPlan.make(from: [u("/in/report.pdf")])
        #expect(ArchiveNaming.baseName(for: plan) == "report")
    }

    @Test func singleFolderKeepsItsName() throws {
        let plan = try InputPlan.make(from: [u("/in/MyFolder")])
        #expect(ArchiveNaming.baseName(for: plan) == "MyFolder")
    }

    @Test func doubleExtensionOnlyLosesTheLastComponent() throws {
        let plan = try InputPlan.make(from: [u("/in/backup.tar.gz")])
        #expect(ArchiveNaming.baseName(for: plan) == "backup.tar")
    }

    @Test("a dotfile keeps its whole name instead of becoming empty")
    func dotfileKeepsFullName() throws {
        let plan = try InputPlan.make(from: [u("/in/.bashrc")])
        #expect(ArchiveNaming.baseName(for: plan) == ".bashrc")
    }

    @Test func multipleItemsUseTheEnclosingFolderName() throws {
        let plan = try InputPlan.make(from: [u("/in/Trip2026/a.jpg"), u("/in/Trip2026/b.jpg")])
        #expect(ArchiveNaming.baseName(for: plan) == "Trip2026")
    }

    @Test func fallsBackToArchiveWhenThereIsNoUsableFolderName() throws {
        let plan = InputPlan(workingDirectory: URL(fileURLWithPath: "/"), relativeNames: ["a", "b"], commonParentName: nil)
        #expect(ArchiveNaming.baseName(for: plan) == "Archive")
    }

    // MARK: uniquification — the guard against 7zz silently appending

    @Test func usesThePlainNameWhenNothingIsInTheWay() throws {
        let namer = ArchiveNamer(probe: FakeProbe(existing: []))
        let url = try namer.uniqueArchiveURL(baseName: "report", format: .sevenZip, in: dir)
        #expect(url.path == "/out/report.7z")
    }

    @Test func stepsAsideWhenTheArchiveAlreadyExists() throws {
        let namer = ArchiveNamer(probe: FakeProbe(existing: ["/out/report.7z"]))
        let url = try namer.uniqueArchiveURL(baseName: "report", format: .sevenZip, in: dir)
        #expect(url.path == "/out/report 2.7z")
    }

    @Test func keepsCountingPastMultipleCollisions() throws {
        let namer = ArchiveNamer(probe: FakeProbe(existing: ["/out/report.7z", "/out/report 2.7z", "/out/report 3.7z"]))
        let url = try namer.uniqueArchiveURL(baseName: "report", format: .sevenZip, in: dir)
        #expect(url.path == "/out/report 4.7z")
    }

    @Test("split output collides on its .001 part, since the bare base name is never created (contract #12)")
    func splitChecksVolumeParts() throws {
        let namer = ArchiveNamer(probe: FakeProbe(existing: ["/out/report.7z.001"]))
        let url = try namer.uniqueArchiveURL(baseName: "report", format: .sevenZip, in: dir)
        #expect(url.path == "/out/report 2.7z")
    }

    @Test("any stray volume part blocks the name, not just .001")
    func splitChecksEveryExistingPart() throws {
        let namer = ArchiveNamer(probe: FakeProbe(existing: ["/out/report.7z.007"]))
        let url = try namer.uniqueArchiveURL(baseName: "report", format: .sevenZip, in: dir)
        #expect(url.path == "/out/report 2.7z")
    }

    @Test func nonSplitAlsoRefusesANameOwnedByVolumeParts() throws {
        let namer = ArchiveNamer(probe: FakeProbe(existing: ["/out/report.7z.001"]))
        let url = try namer.uniqueArchiveURL(baseName: "report", format: .sevenZip, in: dir)
        #expect(url.path == "/out/report 2.7z")
    }

    @Test func zipFormatUsesZipExtension() throws {
        let namer = ArchiveNamer(probe: FakeProbe(existing: []))
        #expect(try namer.uniqueArchiveURL(baseName: "x", format: .zip, in: dir).path == "/out/x.zip")
    }

    @Test func givesUpLoudlyInsteadOfLoopingForever() throws {
        var taken = Set<String>(["/out/report.7z"])
        for n in 2...(ArchiveNamer.maximumAttempts + 1) { taken.insert("/out/report \(n).7z") }
        let namer = ArchiveNamer(probe: FakeProbe(existing: taken))
        #expect(throws: ArchiveNamingError.tooManyCollisions(baseName: "report")) {
            try namer.uniqueArchiveURL(baseName: "report", format: .sevenZip, in: dir)
        }
    }

    // MARK: name sanitisation

    @Test("path separators and NUL can never reach a file name",
          arguments: ["a/b", "a\0b", "..", ".", ""])
    func sanitisesDangerousBaseNames(_ raw: String) throws {
        let namer = ArchiveNamer(probe: FakeProbe(existing: []))
        let url = try namer.uniqueArchiveURL(baseName: raw, format: .sevenZip, in: dir)
        let name = url.lastPathComponent
        #expect(!name.contains("/"))
        #expect(!name.contains("\0"))
        #expect(url.deletingLastPathComponent().path == "/out")
        #expect(name.hasSuffix(".7z"))
        #expect(name != ".7z")
    }

    @Test func trimsOverlongNamesToStayUnderTheFilesystemLimit() throws {
        let namer = ArchiveNamer(probe: FakeProbe(existing: []))
        let long = String(repeating: "あ", count: 400)
        let url = try namer.uniqueArchiveURL(baseName: long, format: .sevenZip, in: dir)
        #expect(url.lastPathComponent.utf8.count <= 255)
        #expect(url.lastPathComponent.hasSuffix(".7z"))
    }
}
