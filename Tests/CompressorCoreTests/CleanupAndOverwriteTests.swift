import Foundation
import Testing
@testable import CompressorCore

@Suite("Removing the originals after compression")
struct SourceRemovalTests {

    private func fixture() throws -> (root: URL, inputs: [URL]) {
        let root = try TestSupport.makeTemporaryDirectory()
        let a = root.appendingPathComponent("a.txt")
        let b = root.appendingPathComponent("b.txt")
        try TestSupport.write("alpha", to: a)
        try TestSupport.write("beta", to: b)
        return (root, [a, b])
    }

    private func request(_ inputs: [URL], delete: Bool) -> CompressionRequest {
        var settings = CompressionSettings.default
        settings.verifyAfterCreate = false
        settings.deleteSourcesAfterSuccess = delete
        return CompressionRequest(inputs: inputs, settings: settings, password: nil,
                                  executable: URL(fileURLWithPath: "/unused/7zz"))
    }

    @Test("off by default: nothing is removed")
    func offByDefault() async throws {
        let (root, inputs) = try fixture()
        let remover = FakeRemover()
        let outcome = try await CompressionEngine(runner: FakeRunner(), remover: remover)
            .compress(request(inputs, delete: false))
        #expect(remover.removed.isEmpty)
        #expect(outcome.removedSources.isEmpty)
        #expect(TestSupport.entryNames(in: root).contains("a.txt"))
    }

    @Test("on, and after a clean run, exactly the archived items are removed")
    func removesExactlyWhatWasArchived() async throws {
        let (root, inputs) = try fixture()
        let remover = FakeRemover()
        let outcome = try await CompressionEngine(runner: FakeRunner(), remover: remover)
            .compress(request(inputs, delete: true))

        #expect(Set(remover.removed.map(\.lastPathComponent)) == ["a.txt", "b.txt"])
        #expect(Set(outcome.removedSources.map(\.lastPathComponent)) == ["a.txt", "b.txt"])
        #expect(outcome.removalFailures.isEmpty)
        // the archive itself is obviously still there
        #expect(TestSupport.entryNames(in: root).contains(where: { $0.hasSuffix(".7z") }))
        #expect(!TestSupport.entryNames(in: root).contains("a.txt"))
    }

    @Test("""
    a warning means 7-Zip left something out, so the originals are kept even though the \
    setting is on
    """)
    func keepsOriginalsOnWarning() async throws {
        let (root, inputs) = try fixture()
        let remover = FakeRemover()
        let runner = FakeRunner(script: .init(addExitCode: 1, producedSuffixes: [""]))
        let outcome = try await CompressionEngine(runner: runner, remover: remover)
            .compress(request(inputs, delete: true))

        #expect(outcome.status == .warning)
        #expect(remover.removed.isEmpty, "the archive may be missing files; the originals are the only copy")
        #expect(TestSupport.entryNames(in: root).contains("a.txt"))
    }

    @Test("a failed run removes nothing")
    func removesNothingOnFailure() async throws {
        let (root, inputs) = try fixture()
        let remover = FakeRemover()
        let runner = FakeRunner(script: .init(addExitCode: 2, producedSuffixes: []))
        await #expect(throws: (any Error).self) {
            try await CompressionEngine(runner: runner, remover: remover)
                .compress(self.request(inputs, delete: true))
        }
        #expect(remover.removed.isEmpty)
        #expect(TestSupport.entryNames(in: root).sorted() == ["a.txt", "b.txt"])
    }

    @Test("a removal that fails is reported instead of being swallowed")
    func reportsRemovalFailures() async throws {
        let (_, inputs) = try fixture()
        let remover = FakeRemover(failOn: { $0.lastPathComponent == "b.txt" })
        let outcome = try await CompressionEngine(runner: FakeRunner(), remover: remover)
            .compress(request(inputs, delete: true))

        #expect(outcome.removedSources.map(\.lastPathComponent) == ["a.txt"])
        #expect(outcome.removalFailures.count == 1)
        #expect(outcome.removalFailures[0].contains("b.txt"))
    }

    @Test("dropping a folder removes the folder, not each file inside it")
    func removesTheDroppedFolderItself() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Docs")
        try TestSupport.write("x", to: folder.appendingPathComponent("inner.txt"))
        let remover = FakeRemover()

        _ = try await CompressionEngine(runner: FakeRunner(), remover: remover)
            .compress(request([folder], delete: true))

        #expect(remover.removed.map(\.lastPathComponent) == ["Docs"])
    }
}

@Suite("TrashSourceRemover against the real Trash")
struct TrashSourceRemoverTests {

    @Test("an item really goes to the Trash and can be found there")
    func movesToTrash() throws {
        // Uniquely named so the cleanup below can only ever touch this one file.
        let root = try TestSupport.makeTemporaryDirectory()
        let name = "7zdrop-trash-test-\(UUID().uuidString).txt"
        let file = root.appendingPathComponent(name)
        try TestSupport.write("disposable", to: file)

        let trashed = try TrashSourceRemover().remove(file)

        #expect(!FileManager.default.fileExists(atPath: file.path), "the original is gone")
        let landed = try #require(trashed, "the Trash location should be reported")
        #expect(FileManager.default.fileExists(atPath: landed.path), "and it is in the Trash")
        // put the test's own litter back out again
        try? FileManager.default.removeItem(at: landed)
    }

    @Test("removing something that is not there throws rather than reporting success")
    func missingItemThrows() throws {
        let root = try TestSupport.makeTemporaryDirectory()
        #expect(throws: (any Error).self) {
            _ = try TrashSourceRemover().remove(root.appendingPathComponent("nope.txt"))
        }
    }
}

@Suite("Overwriting on extraction", .serialized)
struct ExtractionOverwriteTests {

    private let compressor = CompressionEngine()

    private func settings(overwrite: Bool) -> ExtractionSettings {
        var s = ExtractionSettings.default
        s.overwriteExisting = overwrite
        // The archive has one root folder, so the result is "Docs" either way — exactly
        // the name that is already taken.
        s.guaranteeContainingFolder = true
        return s
    }

    private func makeArchive(of inputs: [URL]) async throws -> URL {
        var compression = CompressionSettings.default
        compression.level = .fastest
        compression.verifyAfterCreate = false
        let outcome = try await compressor.compress(CompressionRequest(
            inputs: inputs, settings: compression, password: nil,
            executable: TestSupport.sevenZipURL))
        return try #require(outcome.primaryURL)
    }

    @Test("off: an existing folder is left alone and the new one steps aside")
    func offKeepsBoth() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Docs")
        try TestSupport.write("fresh", to: folder.appendingPathComponent("a.txt"))
        let archive = try await makeArchive(of: [folder])
        try TestSupport.write("MINE", to: folder.appendingPathComponent("a.txt"))

        let remover = FakeRemover()
        let outcome = try await ExtractionEngine(remover: remover).extract(
            ExtractionRequest(archive: archive, settings: settings(overwrite: false),
                              password: nil, executable: TestSupport.sevenZipURL))

        #expect(outcome.outputURL.lastPathComponent == "Docs 2")
        #expect(remover.removed.isEmpty)
        #expect(try String(decoding: Data(contentsOf: folder.appendingPathComponent("a.txt")),
                           as: UTF8.self) == "MINE")
    }

    @Test("on: the existing folder is replaced, and the old one goes to the Trash")
    func onReplacesViaTrash() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Docs")
        try TestSupport.write("fresh", to: folder.appendingPathComponent("a.txt"))
        let archive = try await makeArchive(of: [folder])
        try TestSupport.write("MINE", to: folder.appendingPathComponent("a.txt"))

        let remover = FakeRemover()
        let outcome = try await ExtractionEngine(remover: remover).extract(
            ExtractionRequest(archive: archive, settings: settings(overwrite: true),
                              password: nil, executable: TestSupport.sevenZipURL))

        #expect(outcome.outputURL.lastPathComponent == "Docs")
        #expect(remover.removed.map(\.lastPathComponent) == ["Docs"],
                "the replaced folder must be recoverable, not unlinked")
        #expect(try String(decoding: Data(contentsOf: outcome.outputURL.appendingPathComponent("a.txt")),
                           as: UTF8.self) == "fresh")
    }

    @Test("on, with nothing in the way: no removal happens at all")
    func onWithoutCollisionRemovesNothing() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let folder = root.appendingPathComponent("Docs")
        try TestSupport.write("fresh", to: folder.appendingPathComponent("a.txt"))
        let archive = try await makeArchive(of: [folder])
        try FileManager.default.removeItem(at: folder)

        let remover = FakeRemover()
        let outcome = try await ExtractionEngine(remover: remover).extract(
            ExtractionRequest(archive: archive, settings: settings(overwrite: true),
                              password: nil, executable: TestSupport.sevenZipURL))
        #expect(outcome.outputURL.lastPathComponent == "Docs")
        #expect(remover.removed.isEmpty)
    }
}

@Suite("Split zip", .serialized)
struct SplitZipTests {

    /// The user expected zip not to be splittable. 7-Zip 26.02 does split it — verified
    /// here, including that the parts rejoin into a zip other tools can open.
    @Test("a zip can be split, and the parts round-trip through 7-Zip")
    func zipSplitsAndRestores() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let payload = root.appendingPathComponent("payload.bin")
        var bytes = Data(count: 300_000)
        bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try bytes.write(to: payload)

        var compression = CompressionSettings.default
        compression.format = .zip
        compression.level = .store
        compression.splitSize = try SplitSize.parse("64k")
        compression.verifyAfterCreate = false

        let created = try await CompressionEngine().compress(CompressionRequest(
            inputs: [payload], settings: compression, password: nil,
            executable: TestSupport.sevenZipURL))

        #expect(created.archiveURLs.count > 1)
        #expect(created.archiveURLs[0].lastPathComponent == "payload.zip.001")
        try FileManager.default.removeItem(at: payload)

        let outcome = try await ExtractionEngine().extract(ExtractionRequest(
            archive: created.archiveURLs[2], settings: ExtractionSettings.default,
            password: nil, executable: TestSupport.sevenZipURL))
        // The default guarantees a folder, so a single file lands inside one.
        #expect(outcome.outputURL.lastPathComponent == "payload")
        #expect(try Data(contentsOf: outcome.outputURL.appendingPathComponent("payload.bin")) == bytes)
    }

    @Test("""
    the parts are a plain byte split: concatenating them gives a zip the system tools \
    open, while a single part on its own is not a valid zip
    """)
    func partsConcatenateIntoAStandardZip() async throws {
        let root = try TestSupport.makeTemporaryDirectory()
        let payload = root.appendingPathComponent("payload.bin")
        try Data(repeating: 0x37, count: 200_000).write(to: payload)

        var compression = CompressionSettings.default
        compression.format = .zip
        compression.level = .store
        compression.splitSize = try SplitSize.parse("64k")
        compression.verifyAfterCreate = false
        let created = try await CompressionEngine().compress(CompressionRequest(
            inputs: [payload], settings: compression, password: nil,
            executable: TestSupport.sevenZipURL))
        #expect(created.archiveURLs.count > 1)

        var joined = Data()
        for part in created.archiveURLs { joined.append(try Data(contentsOf: part)) }
        let joinedURL = root.appendingPathComponent("joined.zip")
        try joined.write(to: joinedURL)

        #expect(try TestSupport.systemUnzipTest(joinedURL) == 0, "rejoined parts should be a normal zip")
        #expect(try TestSupport.systemUnzipTest(created.archiveURLs[0]) != 0,
                "a lone .001 is not a zip on its own")
    }
}
