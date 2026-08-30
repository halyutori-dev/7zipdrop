import Foundation
import Testing
@testable import CompressorCore

/// These drive the **real** 7zz binary end to end. They are the evidence that the
/// verified contract in docs/VERIFIED-7ZIP-CONTRACT.md still holds for the bundled
/// version, and that the pipeline actually produces openable archives.
@Suite("End-to-end against the bundled 7zz", .serialized)
struct EndToEndTests {

    private let engine = CompressionEngine()

    private func settings(
        format: ArchiveFormat = .sevenZip,
        level: CompressionLevel = .fastest,
        split: SplitSize? = nil,
        encryptFileNames: Bool = true,
        abortOnUnreadableFile: Bool = true,
        storeSymlinksAsLinks: Bool = true,
        excludeMacMetadata: Bool = true,
        verify: Bool = true,
        verifyEncrypted: Bool = false,
        destination: DestinationMode = .sameAsSource
    ) -> CompressionSettings {
        var s = CompressionSettings.default
        s.format = format
        s.level = level
        s.splitSize = split
        s.encryptFileNames = encryptFileNames
        s.abortOnUnreadableFile = abortOnUnreadableFile
        s.storeSymlinksAsLinks = storeSymlinksAsLinks
        s.excludeMacMetadata = excludeMacMetadata
        s.verifyAfterCreate = verify
        s.verifyEncryptedArchives = verifyEncrypted
        s.destination = destination
        return s
    }

    private func request(_ inputs: [URL], _ settings: CompressionSettings, password: Password? = nil) -> CompressionRequest {
        CompressionRequest(inputs: inputs, settings: settings, password: password,
                           executable: TestSupport.sevenZipURL)
    }

    @Test("the bundled binary is present, executable and the expected version")
    func bundledBinaryIsUsable() throws {
        #expect(SevenZipLocator().isUsable(TestSupport.sevenZipURL))
        let (output, _) = try TestSupport.runSevenZip(["i"])
        #expect(output.contains("26.02"), "bundled 7zz is not the verified version")
    }

    @Test func compressesAFolderAndKeepsItsStructure() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Trip")
        try TestSupport.write("a", to: folder.appendingPathComponent("a.txt"))
        try TestSupport.write("b", to: folder.appendingPathComponent("sub/b.txt"))

        let outcome = try await engine.compress(request([folder], settings()))

        #expect(outcome.status == .success)
        let archive = try #require(outcome.primaryURL)
        #expect(archive.lastPathComponent == "Trip.7z")
        #expect(try TestSupport.listEntries(archive) == ["Trip", "Trip/a.txt", "Trip/sub", "Trip/sub/b.txt"])
        #expect(outcome.totalBytes > 0)
    }

    @Test func singleFileArchiveIsNamedAfterTheFile() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("report.pdf")
        try TestSupport.write("pdf-ish", to: file)

        let outcome = try await engine.compress(request([file], settings()))
        let archive = try #require(outcome.primaryURL)
        #expect(archive.lastPathComponent == "report.7z")
        #expect(try TestSupport.listEntries(archive) == ["report.pdf"])
    }

    @Test("running twice never appends to the first archive (contract #3, end to end)")
    func secondRunDoesNotTouchTheFirstArchive() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let first = root.appendingPathComponent("data/one.txt")
        let second = root.appendingPathComponent("data/two.txt")
        try TestSupport.write("one", to: first)
        try TestSupport.write("two", to: second)

        let a = try await engine.compress(request([first], settings()))
        let b = try await engine.compress(request([second], settings()))

        let archiveA = try #require(a.primaryURL)
        let archiveB = try #require(b.primaryURL)
        #expect(archiveA.lastPathComponent == "one.7z")
        #expect(archiveB.lastPathComponent == "two.7z")
        // The important part: A still contains only its own file.
        #expect(try TestSupport.listEntries(archiveA) == ["one.txt"])
        #expect(try TestSupport.listEntries(archiveB) == ["two.txt"])
    }

    @Test("compressing the same file twice produces a second, separate archive")
    func repeatedRunsStepAside() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("note.txt")
        try TestSupport.write("hello", to: file)

        let first = try await engine.compress(request([file], settings()))
        let second = try await engine.compress(request([file], settings()))

        #expect(first.primaryURL?.lastPathComponent == "note.7z")
        #expect(second.primaryURL?.lastPathComponent == "note 2.7z")
        #expect(try TestSupport.listEntries(#require(first.primaryURL)) == ["note.txt"])
    }

    // MARK: encryption

    @Test func passwordProtectsTheArchive() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("secret.txt")
        try TestSupport.write("classified", to: file)

        let outcome = try await engine.compress(
            request([file], settings(encryptFileNames: false, verifyEncrypted: true),
                    password: try Password("Corr3ct Horse 日本語")))
        let archive = try #require(outcome.primaryURL)

        #expect(try TestSupport.testArchive(archive, password: "Corr3ct Horse 日本語") == 0)
        #expect(try TestSupport.testArchive(archive, password: "wrong") != 0)
        // header not encrypted → names still listable without a password
        #expect(try TestSupport.listEntries(archive) == ["secret.txt"])
    }

    @Test("header encryption hides the file names themselves (contract #5)")
    func headerEncryptionHidesNames() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("payroll.csv")
        try TestSupport.write("names,salaries", to: file)

        let outcome = try await engine.compress(
            request([file], settings(encryptFileNames: true, verifyEncrypted: true),
                    password: try Password("pw12345")))
        let archive = try #require(outcome.primaryURL)

        #expect(try TestSupport.listEntries(archive).isEmpty, "names must not be readable without the password")
        #expect(try TestSupport.listEntries(archive, password: "pw12345") == ["payroll.csv"])
    }

    @Test("zip archives get AES-256, not the breakable ZipCrypto default (contract #4)")
    func zipUsesAES256() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("doc.txt")
        try TestSupport.write("content", to: file)

        let outcome = try await engine.compress(
            request([file], settings(format: .zip, verifyEncrypted: true),
                    password: try Password("pw12345")))
        let archive = try #require(outcome.primaryURL)

        #expect(archive.lastPathComponent == "doc.zip")
        let listing = try TestSupport.technicalListing(archive, password: "pw12345")
        #expect(listing.contains("AES-256"))
        #expect(!listing.contains("ZipCrypto"))
    }

    // MARK: split

    @Test func splitProducesNumberedVolumes() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("big.bin")
        try Data(repeating: 0x41, count: 300_000).write(to: file)

        let outcome = try await engine.compress(
            request([file], settings(level: .store, split: try SplitSize.parse("64k"))))

        #expect(outcome.archiveURLs.count > 1)
        #expect(outcome.archiveURLs.map(\.lastPathComponent).first == "big.7z.001")
        for url in outcome.archiveURLs.dropLast() {
            #expect(TestSupport.fileSize(url) == 65536, "volumes are 1024-based (contract #12)")
        }
        // the whole set still opens as one archive
        #expect(try TestSupport.testArchive(#require(outcome.primaryURL)) == 0)
    }

    // MARK: fail-closed behaviour

    @Test("an unreadable input aborts the whole archive rather than silently omitting it (contract #14)")
    func unreadableInputAborts() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Docs")
        try TestSupport.write("fine", to: folder.appendingPathComponent("good.txt"))
        let locked = folder.appendingPathComponent("locked.txt")
        try TestSupport.write("secret", to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        await #expect(throws: (any Error).self) {
            try await self.engine.compress(self.request([folder], self.settings(abortOnUnreadableFile: true)))
        }
        #expect(TestSupport.entryNames(in: root) == ["Docs"], "no partial archive may be delivered")
    }

    @Test("with the guard turned off the archive is delivered but flagged as incomplete")
    func unreadableInputWithoutGuardIsFlagged() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Docs")
        try TestSupport.write("fine", to: folder.appendingPathComponent("good.txt"))
        let locked = folder.appendingPathComponent("locked.txt")
        try TestSupport.write("secret", to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }

        let outcome = try await engine.compress(
            request([folder], settings(abortOnUnreadableFile: false, verify: false)))
        #expect(outcome.status == .warning)
        #expect(outcome.hadWarnings)
        let entries = try TestSupport.listEntries(#require(outcome.primaryURL))
        #expect(entries.contains("Docs/good.txt"))
        #expect(!entries.contains("Docs/locked.txt"), "this is exactly the silent omission we warn about")
    }

    // MARK: awkward inputs

    @Test("names containing wildcard characters, leading dashes and @ are taken literally (contract #9)")
    func awkwardFileNamesRoundTrip() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Odd")
        for name in ["star[1]*name.txt", "-dash.txt", "@at.txt", "spaces and 'quotes'.txt", "日本語.txt"] {
            try TestSupport.write("x", to: folder.appendingPathComponent(name))
        }

        let outcome = try await engine.compress(request([folder], settings()))
        let entries = try TestSupport.listEntries(#require(outcome.primaryURL))

        #expect(entries.contains("Odd/star[1]*name.txt"))
        #expect(entries.contains("Odd/-dash.txt"))
        #expect(entries.contains("Odd/@at.txt"))
        #expect(entries.contains("Odd/spaces and 'quotes'.txt"))
        #expect(entries.contains("Odd/日本語.txt"))
    }

    @Test("two same-named files from different folders both make it in (contract #6)")
    func sameNamedFilesFromDifferentFoldersBothLand() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let a = root.appendingPathComponent("A/same.txt")
        let b = root.appendingPathComponent("B/same.txt")
        try TestSupport.write("aaa", to: a)
        try TestSupport.write("bbb", to: b)

        let outcome = try await engine.compress(request([a, b], settings()))
        let entries = try TestSupport.listEntries(#require(outcome.primaryURL))
        // 7zz records explicitly-named files without separate directory entries; the
        // folders are recreated from the stored paths on extraction.
        #expect(entries == ["A/same.txt", "B/same.txt"])
    }

    @Test("dropping a folder and a file inside it does not make 7zz choke on a duplicate")
    func folderPlusInnerFileIsDeduplicated() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Pics")
        let inner = folder.appendingPathComponent("one.jpg")
        try TestSupport.write("jpg", to: inner)

        let outcome = try await engine.compress(request([folder, inner], settings()))
        #expect(try TestSupport.listEntries(#require(outcome.primaryURL)) == ["Pics", "Pics/one.jpg"])
    }

    @Test("literal .DS_Store exclusion works even with wildcard matching disabled (contract #10)")
    func dsStoreIsExcluded() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("WithJunk")
        try TestSupport.write("real", to: folder.appendingPathComponent("keep.txt"))
        try TestSupport.write("junk", to: folder.appendingPathComponent(".DS_Store"))
        try TestSupport.write("junk", to: folder.appendingPathComponent("nested/.DS_Store"))
        try TestSupport.write("real", to: folder.appendingPathComponent("nested/keep2.txt"))

        let outcome = try await engine.compress(request([folder], settings(excludeMacMetadata: true)))
        let entries = try TestSupport.listEntries(#require(outcome.primaryURL))
        #expect(!entries.contains { $0.hasSuffix(".DS_Store") })
        #expect(entries.contains("WithJunk/keep.txt"))
        #expect(entries.contains("WithJunk/nested/keep2.txt"))
    }

    @Test("a symlink is stored as a link, so an archive cannot smuggle in its target (contract #13)")
    func symlinkStoredAsLink() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Links")
        try TestSupport.write("real content", to: folder.appendingPathComponent("real.txt"))
        try FileManager.default.createSymbolicLink(
            atPath: folder.appendingPathComponent("outside.txt").path, withDestinationPath: "/etc/hosts")

        let outcome = try await engine.compress(request([folder], settings(storeSymlinksAsLinks: true)))
        let listing = try TestSupport.technicalListing(#require(outcome.primaryURL))
        #expect(listing.contains("lrw"), "symlink should be recorded with link attributes")
        // the archive must not contain the contents of /etc/hosts
        let hosts = try String(decoding: Data(contentsOf: URL(fileURLWithPath: "/etc/hosts")), as: UTF8.self)
        if let firstLine = hosts.split(separator: "\n").first(where: { $0.count > 10 }) {
            let raw = try Data(contentsOf: #require(outcome.primaryURL))
            #expect(!String(decoding: raw, as: UTF8.self).contains(firstLine))
        }
    }

    @Test("verification really runs and really passes for an unencrypted archive")
    func unencryptedArchivesAreVerified() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("v.txt")
        try TestSupport.write("verify me", to: file)

        let outcome = try await engine.compress(request([file], settings(verify: true)))
        #expect(outcome.verification == .passed)
    }

    @Test("by default an encrypted archive is reported as NOT verified rather than being silently claimed (contract #21)")
    func encryptedArchivesAreNotSilentlyClaimedVerified() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("v.txt")
        try TestSupport.write("verify me", to: file)

        let outcome = try await engine.compress(
            request([file], settings(verify: true, verifyEncrypted: false), password: try Password("pw12345")))
        #expect(outcome.verification == .skippedBecauseEncrypted)
        #expect(try TestSupport.testArchive(#require(outcome.primaryURL), password: "pw12345") == 0)
    }

    @Test("opting in verifies the encrypted archive for real")
    func encryptedVerificationOptInWorks() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("v.txt")
        try TestSupport.write("verify me", to: file)

        let outcome = try await engine.compress(
            request([file], settings(verify: true, verifyEncrypted: true), password: try Password("pw12345")))
        #expect(outcome.verification == .passed)
    }

    @Test func verificationIsReportedAsNotRequestedWhenTurnedOff() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("v.txt")
        try TestSupport.write("x", to: file)
        let outcome = try await engine.compress(request([file], settings(verify: false)))
        #expect(outcome.verification == .notRequested)
    }

    // MARK: destination handling

    @Test func fixedDestinationPutsArchivesInOnePlace() async throws {
        let source = try TestSupport.makeTemporaryDirectory()
        let target = try TestSupport.makeTemporaryDirectory()
        let file = source.appendingPathComponent("x.txt")
        try TestSupport.write("x", to: file)

        let outcome = try await engine.compress(
            request([file], settings(destination: .fixedDirectory(target))))

        #expect(outcome.primaryURL?.deletingLastPathComponent().path == target.path)
        #expect(TestSupport.entryNames(in: source) == ["x.txt"], "source folder stays untouched")
        #expect(TestSupport.entryNames(in: target) == ["x.7z"])
    }

    @Test("""
    a legal-but-maximal source name whose derived archive name would overflow the \
    255-byte limit is clamped instead of failing
    """)
    func maximalNamesAreClampedForTheArchive() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        // 85 Japanese characters = 255 UTF-8 bytes: the longest name macOS will create.
        // Appending ".7z" to it would be 258 bytes, so the archive name must be shortened.
        let longName = String(repeating: "あ", count: 85)
        #expect(longName.utf8.count == 255)
        let file = root.appendingPathComponent(longName)
        try TestSupport.write("content", to: file)

        let outcome = try await engine.compress(request([file], settings()))
        let archive = try #require(outcome.primaryURL)

        #expect(archive.lastPathComponent.utf8.count <= 255)
        #expect(archive.pathExtension == "7z")
        #expect(FileManager.default.fileExists(atPath: archive.path))
        #expect(try TestSupport.listEntries(archive) == [longName])
        #expect(outcome.verification == .passed)
    }

    // MARK: cancellation

    @Test("cancelling leaves no archive and no staging directory behind (contract #15/#16)")
    func cancellationLeavesNothingBehind() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("incompressible.bin")
        var random = Data(count: 24 * 1024 * 1024)
        random.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try random.write(to: file)

        let task = Task {
            try await self.engine.compress(self.request([file], self.settings(level: .ultra, verify: false)))
        }
        try await Task.sleep(for: .milliseconds(700))
        task.cancel()
        let result = await task.result

        #expect(throws: (any Error).self) { try result.get() }
        // Give the child a moment to unwind, then confirm the folder is pristine.
        try await Task.sleep(for: .milliseconds(300))
        #expect(TestSupport.entryNames(in: root) == ["incompressible.bin"])
    }

    // MARK: progress

    @Test func realRunEmitsProgressAndCompletion() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let file = root.appendingPathComponent("payload.bin")
        var random = Data(count: 8 * 1024 * 1024)
        random.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try random.write(to: file)

        let box = EventRecorder()
        _ = try await engine.compress(request([file], settings(level: .normal, verify: false))) { box.append($0) }

        #expect(box.events.contains(.finishedOK))
        let percentages = box.events.compactMap { event -> Int? in
            if case .progress(let p, _) = event { return p } else { return nil }
        }
        #expect(!percentages.isEmpty, "no progress was parsed from a real run")
        #expect(percentages.allSatisfy { (0...100).contains($0) })
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SevenZipOutputParser.Event] = []
    func append(_ event: SevenZipOutputParser.Event) { lock.withLock { storage.append(event) } }
    var events: [SevenZipOutputParser.Event] { lock.withLock { storage } }
}
