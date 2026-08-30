import Foundation
import Testing
@testable import CompressorCore

@Suite("Archive detection and drop classification")
struct ArchiveDetectionTests {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    @Test("the archive extensions we auto-extract",
          arguments: ["a.7z", "a.zip", "a.rar", "a.tar", "a.gz", "a.tgz", "a.bz2", "a.tbz2",
                      "a.xz", "a.txz", "a.zst", "a.tzst", "a.lzma", "a.cab", "a.arj",
                      "a.lzh", "a.lha", "a.cpio", "a.wim", "a.Z", "b.TAR.GZ"])
    func recognisesArchives(_ name: String) {
        #expect(ArchiveDetection.looksLikeArchive(u("/x/\(name)")))
    }

    @Test("""
    formats 7-Zip can pry open but that nobody means as an archive stay out of auto mode \
    (contract #33)
    """,
          arguments: ["photo.jpg", "notes.txt", "app.exe", "disk.dmg", "image.iso", "doc.docx",
                      "sheet.xlsx", "book.epub", "app.apk", "app.ipa", "lib.jar", "pkg.msi",
                      "folder", "a.mp4", "movie.mkv"])
    func leavesNonArchivesAlone(_ name: String) {
        #expect(!ArchiveDetection.looksLikeArchive(u("/x/\(name)")))
    }

    @Test("volume parts count as archives (contract #31)")
    func recognisesVolumeParts() {
        #expect(ArchiveDetection.looksLikeArchive(u("/x/big.7z.001")))
        #expect(ArchiveDetection.looksLikeArchive(u("/x/big.7z.017")))
        #expect(ArchiveDetection.looksLikeArchive(u("/x/big.zip.002")))
        #expect(!ArchiveDetection.looksLikeArchive(u("/x/photo.jpg.001")))
        #expect(!ArchiveDetection.looksLikeArchive(u("/x/version.1.2.3")))
    }

    @Test("a dropped part is redirected to .001, which is the only one 7zz accepts")
    func redirectsToFirstVolume() {
        #expect(ArchiveDetection.firstVolume(of: u("/x/big.7z.004"))?.lastPathComponent == "big.7z.001")
        #expect(ArchiveDetection.firstVolume(of: u("/x/big.7z.001")) == nil, "already the first part")
        #expect(ArchiveDetection.firstVolume(of: u("/x/big.7z")) == nil)
    }

    @Test("single-stream compressors are the only ones we follow a second time (contract #32)")
    func identifiesSingleStreamFormats() {
        for name in ["a.gz", "a.tgz", "a.bz2", "a.xz", "a.zst", "a.Z", "a.lzma"] {
            #expect(ArchiveDetection.isSingleStreamCompressor(u("/x/\(name)")), "\(name)")
        }
        for name in ["a.7z", "a.zip", "a.tar", "a.rar", "a.cab"] {
            #expect(!ArchiveDetection.isSingleStreamCompressor(u("/x/\(name)")), "\(name)")
        }
    }

    @Test func baseNameStripsEveryArchiveLayer() {
        #expect(ArchiveDetection.payloadName(for: u("/x/Docs.7z")) == "Docs")
        #expect(ArchiveDetection.payloadName(for: u("/x/Docs.tar.gz")) == "Docs")
        #expect(ArchiveDetection.payloadName(for: u("/x/Docs.tgz")) == "Docs")
        #expect(ArchiveDetection.payloadName(for: u("/x/big.7z.001")) == "big")
        #expect(ArchiveDetection.payloadName(for: u("/x/no-extension")) == "no-extension")
    }

    // MARK: drop classification

    @Test("auto mode extracts only when every dropped item is an archive")
    func autoModeIsAllOrNothing() {
        #expect(DropClassifier.classify([u("/x/a.7z"), u("/x/b.zip")], mode: .auto)
                == .extract([u("/x/a.7z"), u("/x/b.zip")]))
        #expect(DropClassifier.classify([u("/x/a.txt")], mode: .auto)
                == .compress([u("/x/a.txt")]))
        // mixed: compressing is what a compressor does, and wrapping an archive is legitimate
        #expect(DropClassifier.classify([u("/x/a.7z"), u("/x/b.txt")], mode: .auto)
                == .compress([u("/x/a.7z"), u("/x/b.txt")]))
    }

    @Test func explicitModesOverrideDetection() {
        #expect(DropClassifier.classify([u("/x/a.txt")], mode: .extract) == .extract([u("/x/a.txt")]))
        #expect(DropClassifier.classify([u("/x/a.7z")], mode: .compress) == .compress([u("/x/a.7z")]))
    }

    @Test func emptyDropDoesNothing() {
        #expect(DropClassifier.classify([], mode: .auto) == nil)
    }
}

@Suite("Archive entry path safety (contract #26)")
struct EntryPathSafetyTests {

    @Test("""
    ordinary relative entry paths are accepted — including the "./" prefix that a plain \
    `tar cf x.tar .` puts on everything
    """,
          arguments: ["a.txt", "dir/a.txt", "a/b/c/d.txt", "日本語/ファイル.txt",
                      "with space/and 'quote'.txt", "dots...txt", "a..b/c.txt", "...hidden",
                      ".", "./a.txt", "./sub/b.txt", "._.", "./._a.txt", "a/./b.txt"])
    func acceptsSafePaths(_ path: String) {
        #expect(ArchiveEntry.isSafePath(path), "\(path)")
    }

    @Test("anything that could write outside the destination is rejected",
          arguments: ["../escape.txt", "a/../../escape.txt", "/absolute.txt", "/etc/passwd",
                      "..", "a/..", "./../escape.txt", "a//b.txt", "", "a/", "C:/windows/x.txt",
                      "a\\..\\b.txt", "a\u{0}b"])
    func rejectsUnsafePaths(_ path: String) {
        #expect(!ArchiveEntry.isSafePath(path), "\(path)")
    }

    @Test("a '..' that appears inside a component name is not traversal")
    func doesNotOverReject() {
        #expect(ArchiveEntry.isSafePath("my..file.txt"))
        #expect(ArchiveEntry.isSafePath("a/..b/c"))
        #expect(ArchiveEntry.isSafePath("a/b../c"))
    }
}
