import Foundation
import Testing
@testable import CompressorCore

@Suite("Archive listing parsing — driven by real `7zz l -slt` output")
struct ArchiveListingTests {

    private func fixture(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
        return try String(decoding: Data(contentsOf: url), as: UTF8.self)
    }

    @Test("entries come from after the separator, so the archive's own header is not an entry")
    func skipsTheArchiveHeaderBlock() throws {
        let listing = ArchiveListingParser.parse(try fixture("listing-7z-with-symlinks"))
        #expect(!listing.entries.contains { $0.path == "links.7z" })
        #expect(listing.entries.map(\.path).sorted()
                == ["lsrc", "lsrc/abs-link", "lsrc/real.txt", "lsrc/rel-link"])
    }

    @Test func readsTypeAndPhysicalSizeFromTheHeader() throws {
        let listing = ArchiveListingParser.parse(try fixture("listing-7z-encrypted"))
        #expect(listing.format == "7z")
        #expect(listing.physicalSize == 249)
    }

    @Test func distinguishesDirectoriesFilesAndSymlinks() throws {
        let listing = ArchiveListingParser.parse(try fixture("listing-7z-with-symlinks"))
        let byPath = Dictionary(uniqueKeysWithValues: listing.entries.map { ($0.path, $0) })
        #expect(try #require(byPath["lsrc"]).isDirectory)
        #expect(try !#require(byPath["lsrc/real.txt"]).isDirectory)
        #expect(try !#require(byPath["lsrc/real.txt"]).isSymlink)
        // contract #30: the l flag in Attributes is the only symlink signal available
        #expect(try #require(byPath["lsrc/abs-link"]).isSymlink)
        #expect(try #require(byPath["lsrc/rel-link"]).isSymlink)
        #expect(listing.symlinkPaths.sorted() == ["lsrc/abs-link", "lsrc/rel-link"])
    }

    @Test("empty values such as 'Packed Size = ' do not break parsing")
    func toleratesEmptyValues() throws {
        let listing = ArchiveListingParser.parse(try fixture("listing-7z-with-symlinks"))
        let real = try #require(listing.entries.first { $0.path == "lsrc/real.txt" })
        #expect(real.size == 5)
        #expect(real.packedSize == 0)
    }

    @Test("encryption is detectable without the password (contract #28)")
    func detectsEncryptedEntries() throws {
        let encrypted = ArchiveListingParser.parse(try fixture("listing-7z-encrypted"))
        #expect(encrypted.containsEncryptedEntries)
        let plain = ArchiveListingParser.parse(try fixture("listing-7z-with-symlinks"))
        #expect(!plain.containsEncryptedEntries)
    }

    @Test("the uncompressed total is known before extracting (contract #29)")
    func computesUncompressedTotal() throws {
        let bomb = ArchiveListingParser.parse(try fixture("listing-7z-bomb"))
        #expect(bomb.totalUncompressedSize == 52_428_800)
        #expect(bomb.physicalSize == 7831)
        #expect(bomb.expansionRatio > 6000)
    }

    @Test("a traversal entry is visible in the listing and flagged (contract #26)")
    func flagsTraversalEntries() throws {
        let listing = ArchiveListingParser.parse(try fixture("listing-zip-traversal"))
        #expect(listing.entries.map(\.path).contains("../../../ESCAPED-REL.txt"))
        #expect(listing.unsafePaths == ["../../../ESCAPED-REL.txt"])
        #expect(!listing.isSafeToExtract)
    }

    @Test func aNormalArchiveIsSafeToExtract() throws {
        #expect(ArchiveListingParser.parse(try fixture("listing-7z-with-symlinks")).isSafeToExtract)
        #expect(ArchiveListingParser.parse(try fixture("listing-7z-bomb")).isSafeToExtract)
    }

    @Test("an ordinary multi-entry archive has no unnamed streams and nothing undeclared")
    func ordinaryArchivesAreFullyDeclared() throws {
        for name in ["listing-7z-with-symlinks", "listing-7z-encrypted", "listing-zip-traversal"] {
            let listing = ArchiveListingParser.parse(try fixture(name))
            #expect(listing.unnamedStreamSizes.isEmpty, "\(name)")
            #expect(!listing.hasUndeclaredSizes, "\(name)")
        }
    }

    @Test func emptyOrGarbageInputYieldsNoEntriesRatherThanCrashing() {
        #expect(ArchiveListingParser.parse("").entries.isEmpty)
        #expect(ArchiveListingParser.parse("total garbage\nwith no separator\n").entries.isEmpty)
        #expect(ArchiveListingParser.parse("----------\n").entries.isEmpty)
        #expect(ArchiveListingParser.parse("----------\nPath = \n").entries.isEmpty)
    }

    @Test("a block without a Path key is counted as a stream, never as a nameless entry")
    func pathlessBlocksCountButAreNotEntries() {
        let text = """
        ----------
        Size = 10
        Attributes = A -rw-r--r--

        Path = real.txt
        Size = 3
        Attributes = A -rw-r--r--
        """
        let listing = ArchiveListingParser.parse(text)
        #expect(listing.entries.map(\.path) == ["real.txt"])
        #expect(listing.unnamedStreamSizes == [10])
        #expect(listing.totalUncompressedSize == 13)
    }

    @Test("a single-stream archive has no Path line, but its declared size still counts")
    func countsTheUnnamedStreamOfASingleStreamArchive() throws {
        // 7,400 bytes of xz that expands to 50,000,000 (measured with 7zz 26.02)
        let listing = ArchiveListingParser.parse(try fixture("listing-xz-unnamed-stream"))
        #expect(listing.entries.isEmpty)
        #expect(listing.totalUncompressedSize == 50_000_000)
        #expect(!listing.hasUndeclaredSizes)
        #expect(listing.isSafeToExtract)
    }

    @Test("bzip2 declares no size at all, which is reported rather than read as zero")
    func reportsAnUndeclaredSize() throws {
        // 178 bytes of bzip2 that expands to 200,000,000; 7zz prints `Size = ` empty
        let listing = ArchiveListingParser.parse(try fixture("listing-bz2-undeclared-size"))
        #expect(listing.hasUndeclaredSizes)
        #expect(listing.isSafeToExtract)
    }

    @Test("declared sizes whose sum passes Int64.max saturate instead of trapping")
    func saturatesAnOverflowingTotal() throws {
        // two zip64 entries of 0x6000000000000000 bytes each
        let listing = ArchiveListingParser.parse(try fixture("listing-zip-sizes-overflow"))
        #expect(listing.fileEntries.count == 2)
        #expect(listing.totalUncompressedSize == Int64.max)
    }

    @Test("a declared size beyond Int64 is taken as the maximum, never as zero")
    func saturatesASizeBeyondInt64() throws {
        // zip64 entry declaring 18446744073709551600 bytes
        let listing = ArchiveListingParser.parse(try fixture("listing-zip-size-beyond-int64"))
        let entry = try #require(listing.fileEntries.first)
        #expect(entry.size == Int64.max)
        #expect(listing.totalUncompressedSize == Int64.max)
        #expect(!listing.hasUndeclaredSizes)
    }
}

@Suite("Extraction size limits (zip bomb, contract #29)")
struct ExtractionLimitTests {

    private func listing(totalBytes: Int64) -> ArchiveListing {
        ArchiveListing(
            format: "7z", physicalSize: 1000,
            entries: [ArchiveEntry(path: "big.bin", size: totalBytes, packedSize: 1000,
                                   isDirectory: false, isSymlink: false, isEncrypted: false)])
    }

    @Test func acceptsAnOrdinaryArchive() throws {
        var settings = ExtractionSettings.default
        settings.maximumTotalBytes = 10 * 1024 * 1024 * 1024
        try ExtractionSafety.check(listing(totalBytes: 100 * 1024 * 1024),
                                   settings: settings, availableBytes: 500 * 1024 * 1024 * 1024)
    }

    @Test("refuses an archive that would not fit on the disk") 
    func refusesWhenItWouldNotFit() {
        var settings = ExtractionSettings.default
        settings.maximumTotalBytes = Int64.max
        #expect(throws: (any Error).self) {
            try ExtractionSafety.check(self.listing(totalBytes: 60 * 1024 * 1024 * 1024),
                                       settings: settings, availableBytes: 50 * 1024 * 1024 * 1024)
        }
    }

    @Test("keeps a headroom margin instead of filling the disk to the last byte")
    func keepsHeadroom() {
        var settings = ExtractionSettings.default
        settings.maximumTotalBytes = Int64.max
        let free: Int64 = 2 * 1024 * 1024 * 1024
        #expect(throws: (any Error).self) {
            // fits numerically, but would leave the disk with nothing spare
            try ExtractionSafety.check(self.listing(totalBytes: free - 100),
                                       settings: settings, availableBytes: free)
        }
    }

    @Test func refusesAboveTheConfiguredCeiling() {
        var settings = ExtractionSettings.default
        settings.maximumTotalBytes = 1024 * 1024 * 1024
        #expect(throws: (any Error).self) {
            try ExtractionSafety.check(self.listing(totalBytes: 2 * 1024 * 1024 * 1024),
                                       settings: settings, availableBytes: Int64.max / 2)
        }
    }

    @Test("unsafe entry paths are refused by default and only pass when explicitly allowed")
    func unsafePathsAreGated() throws {
        let unsafe = ArchiveListing(
            format: "zip", physicalSize: 100,
            entries: [ArchiveEntry(path: "../escape.txt", size: 10, packedSize: 10,
                                   isDirectory: false, isSymlink: false, isEncrypted: false)])
        var settings = ExtractionSettings.default
        #expect(!settings.allowUnsafeEntryPaths)
        #expect(throws: (any Error).self) {
            try ExtractionSafety.check(unsafe, settings: settings, availableBytes: Int64.max / 2)
        }
        settings.allowUnsafeEntryPaths = true
        try ExtractionSafety.check(unsafe, settings: settings, availableBytes: Int64.max / 2)
    }

    @Test("an archive declaring an absurd total is refused, not crashed on")
    func refusesAnOverflowingDeclaration() throws {
        let url = try #require(Bundle.module.url(
            forResource: "listing-zip-sizes-overflow", withExtension: "txt", subdirectory: "Fixtures"))
        let listing = ArchiveListingParser.parse(String(decoding: try Data(contentsOf: url), as: UTF8.self))
        let settings = ExtractionSettings.default
        #expect(throws: CompressorError.extractionTooLarge(
            totalBytes: Int64.max, limitBytes: settings.maximumTotalBytes)) {
            try ExtractionSafety.check(listing, settings: settings, availableBytes: Int64.max)
        }
    }

    @Test func anEmptyArchiveIsNotAnError() throws {
        let empty = ArchiveListing(format: "7z", physicalSize: 32, entries: [])
        try ExtractionSafety.check(empty, settings: .default, availableBytes: Int64.max / 2)
    }
}

@Suite("Password diagnostics pinned to 7-Zip's own wording (contract #35)")
struct PasswordDiagnosticsTests {

    /// Captured verbatim from 7-Zip 26.02.
    private let missingPassword = """
        Listing archive: /tmp/enchdr.7z

        Enter password:
        Break signaled
        """
    private let wrongPasswordHeaders = """
        ERROR: enchdr.7z
        Cannot open encrypted archive. Wrong password?
        """
    private let wrongPasswordData = """
        ERROR: Data Error in encrypted file. Wrong password? : src/a.txt
        Sub items Errors: 2
        """

    @Test func recognisesAMissingPassword() {
        #expect(SevenZipDiagnostics.passwordProblem(in: missingPassword, passwordSupplied: false)
                == .passwordRequired)
    }

    @Test("a wrong password is distinguished from a missing one, in both encryption styles")
    func recognisesAWrongPassword() {
        #expect(SevenZipDiagnostics.passwordProblem(in: wrongPasswordHeaders, passwordSupplied: true)
                == .wrongPassword)
        #expect(SevenZipDiagnostics.passwordProblem(in: wrongPasswordData, passwordSupplied: true)
                == .wrongPassword)
    }

    @Test("ordinary output is not mistaken for a password problem")
    func doesNotOverMatch() {
        #expect(SevenZipDiagnostics.passwordProblem(in: "Everything is Ok", passwordSupplied: false) == nil)
        #expect(SevenZipDiagnostics.passwordProblem(in: "", passwordSupplied: true) == nil)
        #expect(SevenZipDiagnostics.passwordProblem(
            in: "ERROR: Cannot open the file as [7z] archive", passwordSupplied: false) == nil)
    }
}
