import Foundation
import Testing
@testable import CompressorCore

/// Extraction driven against the real bundled 7zz, including deliberately malicious
/// archives kept as fixtures.
@Suite("Extraction end-to-end", .serialized)
struct ExtractionEndToEndTests {

    private let compressor = CompressionEngine()
    private let extractor = ExtractionEngine()

    private func settings(
        guaranteeFolder: Bool = true,
        allowUnsafe: Bool = false,
        maximumTotalBytes: Int64 = 10 * 1024 * 1024 * 1024,
        follow: Bool = true,
        destination: DestinationMode = .sameAsSource
    ) -> ExtractionSettings {
        var s = ExtractionSettings.default
        s.guaranteeContainingFolder = guaranteeFolder
        s.allowUnsafeEntryPaths = allowUnsafe
        s.maximumTotalBytes = maximumTotalBytes
        s.followSingleStreamArchives = follow
        s.destination = destination
        return s
    }

    private func request(_ archive: URL, _ settings: ExtractionSettings, password: Password? = nil) -> ExtractionRequest {
        ExtractionRequest(archive: archive, settings: settings, password: password,
                          executable: TestSupport.sevenZipURL)
    }

    private func compressionSettings(format: ArchiveFormat = .sevenZip,
                                     split: SplitSize? = nil) -> CompressionSettings {
        var s = CompressionSettings.default
        s.format = format
        s.level = .fastest
        s.splitSize = split
        s.verifyAfterCreate = false
        return s
    }

    private func makeArchive(
        of inputs: [URL], format: ArchiveFormat = .sevenZip,
        split: SplitSize? = nil, password: Password? = nil
    ) async throws -> CompressionOutcome {
        try await compressor.compress(CompressionRequest(
            inputs: inputs, settings: compressionSettings(format: format, split: split),
            password: password, executable: TestSupport.sevenZipURL))
    }

    private func fixture(_ name: String, extension fileExtension: String = "zip") throws -> URL {
        try #require(Bundle.module.url(
            forResource: name, withExtension: fileExtension, subdirectory: "Fixtures"))
    }

    /// Fixtures live inside the test bundle; copy so extraction happens in a temp folder.
    private func stagedFixture(
        _ name: String, extension fileExtension: String = "zip"
    ) throws -> (root: URL, archive: URL) {
        let root = try TestSupport.makeTemporaryDirectory()
        let source = try fixture(name, extension: fileExtension)
        let archive = root.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: archive)
        return (root, archive)
    }

    private func relativeTree(of root: URL) -> [String] {
        var results: [String] = []
        var queue = [root]
        while let directory = queue.popLast() {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []) {
                let child = directory.appendingPathComponent(name)
                let relative = String(child.path.dropFirst(root.path.count + 1))
                results.append(relative)
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
                let isLink = (try? child.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink ?? false
                if isDirectory.boolValue && !isLink { queue.append(child) }
            }
        }
        return results.sorted()
    }

    // MARK: happy paths

    @Test("a folder survives a compress/extract round trip byte for byte")
    func roundTripPreservesContent() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Docs")
        try TestSupport.write("alpha", to: folder.appendingPathComponent("a.txt"))
        try TestSupport.write("beta", to: folder.appendingPathComponent("sub/b.txt"))
        try TestSupport.write("gamma 日本語", to: folder.appendingPathComponent("sub/deep/c.txt"))

        let archive = try #require(try await makeArchive(of: [folder]).primaryURL)
        try FileManager.default.removeItem(at: folder)

        let outcome = try await extractor.extract(request(archive, settings()))

        #expect(outcome.outputURL.lastPathComponent == "Docs")
        #expect(relativeTree(of: outcome.outputURL) == ["a.txt", "sub", "sub/b.txt", "sub/deep", "sub/deep/c.txt"])
        #expect(try String(decoding: Data(contentsOf: outcome.outputURL.appendingPathComponent("sub/deep/c.txt")),
                           as: UTF8.self) == "gamma 日本語")
        #expect(outcome.fileCount == 3)
        #expect(outcome.status == .success)
    }

    @Test("a single root folder is not buried in a second folder")
    func unwrapsSingleRootFolder() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Trip")
        try TestSupport.write("x", to: folder.appendingPathComponent("a.txt"))
        let archive = try #require(try await makeArchive(of: [folder]).primaryURL)
        try FileManager.default.removeItem(at: folder)

        let outcome = try await extractor.extract(request(archive, settings(guaranteeFolder: true)))
        #expect(outcome.outputURL.lastPathComponent == "Trip")
        #expect(relativeTree(of: outcome.outputURL) == ["a.txt"])
    }

    @Test("turning unwrapping off keeps the containing folder named after the archive")
    func keepsContainerWhenUnwrapDisabled() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Trip")
        try TestSupport.write("x", to: folder.appendingPathComponent("a.txt"))
        let archive = try #require(try await makeArchive(of: [folder]).primaryURL)
        try FileManager.default.removeItem(at: folder)

        let outcome = try await extractor.extract(request(archive, settings(guaranteeFolder: false)))
        #expect(outcome.outputURL.lastPathComponent == "Trip")
        #expect(relativeTree(of: outcome.outputURL) == ["a.txt"])
    }

    @Test("with the guarantee off, an archive of one file gives back that file")
    func deliversASingleFileDirectly() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("notes.txt")
        try TestSupport.write("content", to: file)
        let archive = try #require(try await makeArchive(of: [file]).primaryURL)
        try FileManager.default.removeItem(at: file)

        let outcome = try await extractor.extract(request(archive, settings(guaranteeFolder: false)))
        #expect(outcome.outputURL.lastPathComponent == "notes.txt")
        #expect(try String(decoding: Data(contentsOf: outcome.outputURL), as: UTF8.self) == "content")
    }

    @Test("""
    with the guarantee on, a single root folder is used as the container — it is never \
    wrapped a second time into Docs/Docs
    """)
    func singleRootFolderIsNotDoubleWrapped() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Docs")
        try TestSupport.write("a", to: folder.appendingPathComponent("a.txt"))
        try TestSupport.write("b", to: folder.appendingPathComponent("inner/b.txt"))
        let archive = try #require(try await makeArchive(of: [folder]).primaryURL)
        try FileManager.default.removeItem(at: folder)

        let outcome = try await extractor.extract(request(archive, settings(guaranteeFolder: true)))

        #expect(outcome.outputURL.lastPathComponent == "Docs")
        #expect(relativeTree(of: outcome.outputURL) == ["a.txt", "inner", "inner/b.txt"])
        #expect(!relativeTree(of: outcome.outputURL).contains("Docs"))
    }

    @Test("with the guarantee on, a single root FILE does get a folder around it")
    func singleRootFileIsWrappedWhenAFolderIsRequired() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("notes.txt")
        try TestSupport.write("content", to: file)
        let archive = try #require(try await makeArchive(of: [file]).primaryURL)
        try FileManager.default.removeItem(at: file)

        let outcome = try await extractor.extract(request(archive, settings(guaranteeFolder: true)))

        #expect(outcome.outputURL.lastPathComponent == "notes")
        #expect(relativeTree(of: outcome.outputURL) == ["notes.txt"])
    }

    @Test("several root items land in one folder named after the archive")
    func wrapsMultipleRootItems() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let a = root.appendingPathComponent("Set/a.txt")
        let b = root.appendingPathComponent("Set/b.txt")
        try TestSupport.write("a", to: a)
        try TestSupport.write("b", to: b)
        let archive = try #require(try await makeArchive(of: [a, b]).primaryURL)

        let outcome = try await extractor.extract(request(archive, settings()))
        // "Set.7z" does not reserve the name "Set" for extraction output
        #expect(outcome.outputURL.lastPathComponent == "Set")
        #expect(relativeTree(of: outcome.outputURL) == ["a.txt", "b.txt"])
    }

    @Test("extracting twice never touches the first result")
    func neverOverwritesAnEarlierExtraction() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Docs")
        try TestSupport.write("original", to: folder.appendingPathComponent("a.txt"))
        let archive = try #require(try await makeArchive(of: [folder]).primaryURL)
        try FileManager.default.removeItem(at: folder)

        let first = try await extractor.extract(request(archive, settings()))
        try TestSupport.write("EDITED BY USER", to: first.outputURL.appendingPathComponent("a.txt"))
        let second = try await extractor.extract(request(archive, settings()))

        #expect(first.outputURL.lastPathComponent == "Docs")
        #expect(second.outputURL.lastPathComponent == "Docs 2")
        #expect(try String(decoding: Data(contentsOf: first.outputURL.appendingPathComponent("a.txt")),
                           as: UTF8.self) == "EDITED BY USER")
    }

    @Test("a .tar.gz comes out as a folder, not as a .tar (contract #32)")
    func followsTarGz() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Payload")
        try TestSupport.write("one", to: folder.appendingPathComponent("one.txt"))
        try TestSupport.write("two", to: folder.appendingPathComponent("two.txt"))

        let tarball = root.appendingPathComponent("Payload.tar.gz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", tarball.path, "-C", root.path, "Payload"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        try FileManager.default.removeItem(at: folder)

        let outcome = try await extractor.extract(request(tarball, settings(follow: true)))
        #expect(outcome.followedInnerArchive == "Payload.tar")
        #expect(outcome.outputURL.lastPathComponent == "Payload")
        #expect(relativeTree(of: outcome.outputURL) == ["one.txt", "two.txt"])
    }

    @Test("a volume set opens even when a later part is the one handed over (contract #31)")
    func extractsFromAnyVolumePart() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("payload.bin")
        var payload = Data(count: 300_000)
        payload.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try payload.write(to: file)
        let created = try await makeArchive(of: [file], split: try SplitSize.parse("64k"))
        #expect(created.archiveURLs.count > 2)
        try FileManager.default.removeItem(at: file)

        // hand over .003, not .001
        let laterPart = created.archiveURLs[2]
        #expect(laterPart.pathExtension == "003")
        let outcome = try await extractor.extract(request(laterPart, settings()))
        #expect(outcome.outputURL.lastPathComponent == "payload")
        #expect(TestSupport.fileSize(outcome.outputURL.appendingPathComponent("payload.bin")) == 300_000)
    }

    @Test func honoursAFixedDestination() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let target = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("x.txt")
        try TestSupport.write("x", to: file)
        let archive = try #require(try await makeArchive(of: [file]).primaryURL)

        let outcome = try await extractor.extract(
            request(archive, settings(destination: .fixedDirectory(target))))
        #expect(outcome.outputURL.deletingLastPathComponent().path == target.path)
        #expect(TestSupport.entryNames(in: target) == ["x"])
    }

    // MARK: passwords

    @Test func extractsAnEncryptedArchiveWithTheRightPassword() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Secret")
        try TestSupport.write("classified", to: folder.appendingPathComponent("s.txt"))
        let password = try Password("Corr3ct Horse 日本語")
        let archive = try #require(try await makeArchive(of: [folder], password: password).primaryURL)
        try FileManager.default.removeItem(at: folder)

        let outcome = try await extractor.extract(request(archive, settings(), password: password))
        #expect(try String(decoding: Data(contentsOf: outcome.outputURL.appendingPathComponent("s.txt")),
                           as: UTF8.self) == "classified")
    }

    @Test("a missing password is reported as such, for both encryption styles (contract #28)")
    func reportsMissingPassword() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("s.txt")
        try TestSupport.write("classified", to: file)
        let password = try Password("pw12345")

        var dataOnly = compressionSettings()
        dataOnly.encryptFileNames = false
        let plainHeaders = try #require(try await compressor.compress(CompressionRequest(
            inputs: [file], settings: dataOnly, password: password,
            executable: TestSupport.sevenZipURL)).primaryURL)

        var hidden = compressionSettings()
        hidden.encryptFileNames = true
        let hiddenHeaders = try #require(try await compressor.compress(CompressionRequest(
            inputs: [file], settings: hidden, password: password,
            executable: TestSupport.sevenZipURL)).primaryURL)

        await #expect(throws: CompressorError.passwordRequired) {
            try await self.extractor.extract(self.request(plainHeaders, self.settings()))
        }
        await #expect(throws: CompressorError.passwordRequired) {
            try await self.extractor.extract(self.request(hiddenHeaders, self.settings()))
        }
    }

    @Test func reportsAWrongPassword() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("s.txt")
        try TestSupport.write("classified", to: file)
        let archive = try #require(
            try await makeArchive(of: [file], password: try Password("right-one")).primaryURL)

        await #expect(throws: (any Error).self) {
            try await self.extractor.extract(
                self.request(archive, self.settings(), password: try Password("wrong-one")))
        }
        #expect(TestSupport.entryNames(in: root).sorted() == ["s.7z", "s.txt"],
                "a failed extraction leaves nothing behind")
    }

    @Test("""
    a plain `tar cf x.tar .` archive extracts — every entry in it is "./"-prefixed, which \
    an over-strict path check refuses
    """)
    func dotPrefixedTarExtracts() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let source = try #require(Bundle.module.url(
            forResource: "dot-prefixed", withExtension: "tar", subdirectory: "Fixtures"))
        let archive = root.appendingPathComponent("dot-prefixed.tar")
        try FileManager.default.copyItem(at: source, to: archive)

        let listing = ArchiveListingParser.parse(
            try TestSupport.technicalListing(archive))
        #expect(listing.entries.map(\.path).contains("./a.txt"), "fixture is not the shape we mean to test")
        #expect(listing.isSafeToExtract, "an ordinary tar must not be treated as dangerous")

        let outcome = try await extractor.extract(request(archive, settings()))
        #expect(relativeTree(of: outcome.outputURL).sorted() == ["a.txt", "sub", "sub/b.txt"])
        #expect(outcome.sanitizedPaths.isEmpty)
    }

    // MARK: adversarial archives

    @Test("a Zip Slip archive is refused, not silently rewritten (contract #26)")
    func refusesRelativeTraversal() async throws {
        let (root, archive) = try stagedFixture("slip-rel")
        await #expect(throws: (any Error).self) {
            try await self.extractor.extract(self.request(archive, self.settings()))
        }
        #expect(TestSupport.entryNames(in: root) == ["slip-rel.zip"])
        #expect(!FileManager.default.fileExists(
            atPath: root.deletingLastPathComponent().appendingPathComponent("ESCAPED-REL.txt").path))
    }

    @Test("an absolute-path entry is refused (contract #26)")
    func refusesAbsolutePathEntry() async throws {
        let (root, archive) = try stagedFixture("slip-abs")
        await #expect(throws: (any Error).self) {
            try await self.extractor.extract(self.request(archive, self.settings()))
        }
        #expect(TestSupport.entryNames(in: root) == ["slip-abs.zip"])
        #expect(!FileManager.default.fileExists(atPath: "/tmp/ESCAPED-ABS.txt"))
    }

    @Test("a symlink-escape archive delivers nothing (contract #27/#30)")
    func refusesSymlinkEscape() async throws {
        let (root, archive) = try stagedFixture("slip-link")
        let outside = root.appendingPathComponent("OUTSIDE")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        await #expect(throws: (any Error).self) {
            try await self.extractor.extract(self.request(archive, self.settings()))
        }
        #expect(TestSupport.entryNames(in: outside).isEmpty, "nothing may be written through the link")
        #expect(TestSupport.entryNames(in: root).sorted() == ["OUTSIDE", "slip-link.zip"])
    }

    @Test("""
    an inner '..' component is refused too — the check accepts only the shape a \
    legitimate entry has, rather than guessing which traversals are harmless
    """)
    func refusesInnerDotDot() async throws {
        let (root, archive) = try stagedFixture("inner-dotdot")
        await #expect(throws: (any Error).self) {
            try await self.extractor.extract(self.request(archive, self.settings()))
        }
        #expect(TestSupport.entryNames(in: root) == ["inner-dotdot.zip"])
    }

    @Test("explicitly allowing unsafe paths extracts and reports them")
    func allowsUnsafePathsOnlyWhenAsked() async throws {
        let (root, archive) = try stagedFixture("slip-rel")
        let outcome = try await extractor.extract(request(archive, settings(allowUnsafe: true)))
        #expect(outcome.sanitizedPaths == ["../../../ESCAPED-REL.txt"])
        // 7-Zip flattens the traversal, so everything still lands inside the output
        #expect(relativeTree(of: outcome.outputURL).contains("good.txt"))
        #expect(TestSupport.entryNames(in: root).sorted() == ["slip-rel", "slip-rel.zip"])
    }

    @Test("an archive that claims to expand past the ceiling is refused (contract #29)")
    func refusesOversizedArchive() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("zeros.bin")
        try Data(repeating: 0, count: 4 * 1024 * 1024).write(to: file)
        let archive = try #require(try await makeArchive(of: [file]).primaryURL)
        try FileManager.default.removeItem(at: file)

        await #expect(throws: (any Error).self) {
            try await self.extractor.extract(
                self.request(archive, self.settings(maximumTotalBytes: 1024 * 1024)))
        }
        #expect(TestSupport.entryNames(in: root) == ["zeros.7z"])
    }

    // MARK: hygiene

    @Test("no staging directory is left behind, on success or failure")
    func stagingIsAlwaysCleanedUp() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("a.txt")
        try TestSupport.write("a", to: file)
        let archive = try #require(try await makeArchive(of: [file]).primaryURL)
        try FileManager.default.removeItem(at: file)

        _ = try await extractor.extract(request(archive, settings()))
        #expect(!TestSupport.entryNames(in: root).contains { $0.hasPrefix(ExtractionEngine.stagingPrefix) })

        let (badRoot, badArchive) = try stagedFixture("slip-rel")
        _ = try? await extractor.extract(request(badArchive, settings()))
        #expect(!TestSupport.entryNames(in: badRoot).contains { $0.hasPrefix(ExtractionEngine.stagingPrefix) })
    }

    @Test("the archive itself is never modified or removed")
    func leavesTheArchiveAlone() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("a.txt")
        try TestSupport.write("a", to: file)
        let archive = try #require(try await makeArchive(of: [file]).primaryURL)
        let before = try Data(contentsOf: archive)

        _ = try await extractor.extract(request(archive, settings()))
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(try Data(contentsOf: archive) == before)
    }

    // MARK: - sizes the archive does not declare (contract #42)

    /// 178 bytes of bzip2 that expand to 200,000,000 zero bytes. `7zz l -slt` prints
    /// `Size = ` for it, so nothing before extraction can tell how big it is.
    private let bzip2Bomb = "bomb-200m"

    @Test("an undeclared-size stream is stopped once it passes the configured ceiling")
    func stopsAnUndeclaredStreamAtTheCeiling() async throws {
        let (root, archive) = try stagedFixture(bzip2Bomb, extension: "bz2")
        defer { try? FileManager.default.removeItem(at: root) }
        let ceiling: Int64 = 10 * 1024 * 1024

        await #expect {
            try await extractor.extract(request(archive, settings(maximumTotalBytes: ceiling)))
        } throws: { error in
            guard case .extractionTooLarge(let written, let limit)? = error as? CompressorError else { return false }
            return limit == ceiling && written > ceiling
        }
        #expect(TestSupport.entryNames(in: root) == [archive.lastPathComponent])
    }

    @Test("an undeclared-size stream is stopped before it eats the disk's headroom")
    func stopsAnUndeclaredStreamBeforeTheDiskFills() async throws {
        let (root, archive) = try stagedFixture(bzip2Bomb, extension: "bz2")
        defer { try? FileManager.default.removeItem(at: root) }
        // The disk claims 10 MiB beyond the headroom; the size ceiling is off.
        let tightDisk = ExtractionEngine(
            freeSpace: { _ in ExtractionSafety.diskHeadroomBytes + 10 * 1024 * 1024 })

        await #expect {
            try await tightDisk.extract(request(archive, settings(maximumTotalBytes: Int64.max)))
        } throws: { error in
            guard case .notEnoughDiskSpace? = error as? CompressorError else { return false }
            return true
        }
        #expect(TestSupport.entryNames(in: root) == [archive.lastPathComponent])
    }

    @Test("an undeclared-size stream within every limit is extracted in full")
    func extractsAnUndeclaredStreamThatFits() async throws {
        let (root, archive) = try stagedFixture(bzip2Bomb, extension: "bz2")
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = try await extractor.extract(request(archive, settings()))
        #expect(outcome.totalBytes == 200_000_000)
    }

    @Test("a stream that finishes between two measurements is still held to the ceiling")
    func measuresOnceMoreAfterSevenZipExits() async throws {
        // bzip2 → 12,000,000 bytes: just over the ceiling, and decoded by 7zz in far less
        // than one poll interval, so only a measurement after exit can catch it
        let (root, archive) = try stagedFixture("bomb-12m", extension: "bz2")
        defer { try? FileManager.default.removeItem(at: root) }
        let ceiling: Int64 = 10 * 1024 * 1024

        await #expect {
            try await extractor.extract(request(archive, settings(maximumTotalBytes: ceiling)))
        } throws: { error in
            guard case .extractionTooLarge? = error as? CompressorError else { return false }
            return true
        }
        #expect(TestSupport.entryNames(in: root) == [archive.lastPathComponent])
    }

    @Test("a gzip is watched by what 7zz detects, not by its name — its declared size can lie")
    func watchesAGzipWhateverItIsCalled() async throws {
        // 20,000,000 zero bytes whose ISIZE trailer was rewritten to claim 1,024. (7zz also
        // reports a CRC error for this one at the very end; a real gzip over 4 GiB has an
        // ISIZE that is correct modulo 2^32 and would not — and cannot be a fixture.)
        let (root, archive) = try stagedFixture("gzip-lying-isize", extension: "bin")
        defer { try? FileManager.default.removeItem(at: root) }
        let ceiling: Int64 = 10 * 1024 * 1024

        await #expect {
            try await extractor.extract(request(archive, settings(maximumTotalBytes: ceiling)))
        } throws: { error in
            guard case .extractionTooLarge? = error as? CompressorError else { return false }
            return true
        }
        #expect(TestSupport.entryNames(in: root) == [archive.lastPathComponent])
    }

    @Test("the watchdog arms exactly when the listing cannot bound the output")
    func armsOnlyWhenTheListingCannotBoundTheOutput() {
        func listing(format: String, sizes: [Int64?] = [], unnamed: [Int64?] = []) -> ArchiveListing {
            ArchiveListing(format: format, physicalSize: 100, entries: sizes.enumerated().map {
                ArchiveEntry(path: "f\($0.offset)", size: $0.element, packedSize: 1,
                             isDirectory: false, isSymlink: false, isEncrypted: false)
            }, unnamedStreamSizes: unnamed)
        }
        let plain = URL(fileURLWithPath: "/tmp/data.bin")
        func armed(_ listing: ArchiveListing, _ archive: URL = plain) -> Bool {
            extractor.outputBudget(for: listing, of: archive, settings: .default,
                                   destination: URL(fileURLWithPath: "/tmp")) != nil
        }
        #expect(!armed(listing(format: "7z", sizes: [10, 20])))
        #expect(armed(listing(format: "zip", sizes: [10, nil])))
        #expect(armed(listing(format: "unknown", unnamed: [10])))
        for type in ["gzip", "bzip2", "xz", "zstd", "lzma", "Z"] {
            #expect(armed(listing(format: type, sizes: [10])), "\(type)")
        }
        #expect(armed(listing(format: "tar", sizes: [10]), URL(fileURLWithPath: "/tmp/x.tar.gz")))
    }
}
