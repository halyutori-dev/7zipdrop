import Foundation
import Testing
@testable import CompressorCore

@Suite("Engine delivery, failure handling and staging hygiene")
struct EngineDeliveryTests {

    private func request(
        inputs: [URL],
        settings: CompressionSettings = {
            var s = CompressionSettings.default
            s.verifyAfterCreate = false
            return s
        }(),
        password: Password? = nil
    ) -> CompressionRequest {
        CompressionRequest(
            inputs: inputs, settings: settings, password: password,
            executable: URL(fileURLWithPath: "/does/not/need/to/exist/7zz"))
    }

    private func fixture() throws -> (root: URL, input: URL) {
        let root = try TestSupport.makeTemporaryDirectory()
        let input = root.appendingPathComponent("report.txt")
        try TestSupport.write("hello", to: input)
        return (root, input)
    }

    @Test func deliversTheStagedArchiveNextToTheSource() async throws {
        let (root, input) = try fixture()
        let engine = CompressionEngine(runner: FakeRunner())
        let outcome = try await engine.compress(request(inputs: [input]))

        #expect(outcome.archiveURLs.map(\.lastPathComponent) == ["report.7z"])
        #expect(outcome.status == .success)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("report.7z").path))
    }

    @Test("no staging directory survives a successful run")
    func stagingIsCleanedUpOnSuccess() async throws {
        let (root, input) = try fixture()
        _ = try await CompressionEngine(runner: FakeRunner()).compress(request(inputs: [input]))
        #expect(!TestSupport.entryNames(in: root).contains { $0.hasPrefix(CompressionEngine.stagingPrefix) })
    }

    @Test("no staging directory survives a failed run either")
    func stagingIsCleanedUpOnFailure() async throws {
        let (root, input) = try fixture()
        let runner = FakeRunner(script: .init(addExitCode: 2, producedSuffixes: []))
        await #expect(throws: (any Error).self) {
            try await CompressionEngine(runner: runner).compress(self.request(inputs: [input]))
        }
        #expect(!TestSupport.entryNames(in: root).contains { $0.hasPrefix(CompressionEngine.stagingPrefix) })
        #expect(TestSupport.entryNames(in: root) == ["report.txt"], "nothing partial may be left behind")
    }

    @Test("a fatal exit delivers nothing at all")
    func fatalExitDeliversNothing() async throws {
        let (root, input) = try fixture()
        // 7zz would normally clean up itself, but even if it left a file we must not ship it.
        let runner = FakeRunner(script: .init(addExitCode: 2, producedSuffixes: [""]))
        await #expect(throws: (any Error).self) {
            try await CompressionEngine(runner: runner).compress(self.request(inputs: [input]))
        }
        #expect(TestSupport.entryNames(in: root) == ["report.txt"])
    }

    @Test("exit 255 is reported as a cancellation, not a failure")
    func cancellationIsDistinct() async throws {
        let (_, input) = try fixture()
        let runner = FakeRunner(script: .init(addExitCode: 255, producedSuffixes: []))
        await #expect(throws: CompressorError.cancelled) {
            try await CompressionEngine(runner: runner).compress(self.request(inputs: [input]))
        }
    }

    @Test("exit 1 still delivers the archive but is surfaced as a warning (contract #14)")
    func warningIsDeliveredButFlagged() async throws {
        let (_, input) = try fixture()
        let runner = FakeRunner(script: .init(addExitCode: 1, producedSuffixes: [""]))
        let outcome = try await CompressionEngine(runner: runner).compress(request(inputs: [input]))
        #expect(outcome.status == .warning)
        #expect(outcome.hadWarnings)
        #expect(outcome.archiveURLs.count == 1)
    }

    @Test("a success with no archive on disk is an error, not a silent no-op")
    func missingOutputIsAnError() async throws {
        let (_, input) = try fixture()
        let runner = FakeRunner(script: .init(addExitCode: 0, producedSuffixes: []))
        await #expect(throws: CompressorError.noArchiveProduced) {
            try await CompressionEngine(runner: runner).compress(self.request(inputs: [input]))
        }
    }

    @Test("an existing archive is never touched; the new one steps aside (contract #3)")
    func existingArchiveIsPreserved() async throws {
        let (root, input) = try fixture()
        let existing = root.appendingPathComponent("report.7z")
        try TestSupport.write("PRE-EXISTING", to: existing)

        let outcome = try await CompressionEngine(runner: FakeRunner()).compress(request(inputs: [input]))

        #expect(outcome.archiveURLs.map(\.lastPathComponent) == ["report 2.7z"])
        #expect(try String(decoding: Data(contentsOf: existing), as: UTF8.self) == "PRE-EXISTING")
    }

    @Test("every volume part is delivered under one consistent base name")
    func volumePartsAreDeliveredTogether() async throws {
        let (root, input) = try fixture()
        var settings = CompressionSettings.default
        settings.verifyAfterCreate = false
        settings.splitSize = try SplitSize.parse("1k")
        let runner = FakeRunner(script: .init(producedSuffixes: [".001", ".002", ".003"]))

        let outcome = try await CompressionEngine(runner: runner)
            .compress(request(inputs: [input], settings: settings))

        #expect(outcome.archiveURLs.map(\.lastPathComponent) == ["report.7z.001", "report.7z.002", "report.7z.003"])
        #expect(TestSupport.entryNames(in: root) == ["report.7z.001", "report.7z.002", "report.7z.003", "report.txt"])
    }

    @Test("volume parts step aside as a set when the base name is taken")
    func volumePartsRespectCollisions() async throws {
        let (root, input) = try fixture()
        try TestSupport.write("x", to: root.appendingPathComponent("report.7z.001"))
        var settings = CompressionSettings.default
        settings.verifyAfterCreate = false
        settings.splitSize = try SplitSize.parse("1k")
        let runner = FakeRunner(script: .init(producedSuffixes: [".001", ".002"]))

        let outcome = try await CompressionEngine(runner: runner)
            .compress(request(inputs: [input], settings: settings))

        #expect(outcome.archiveURLs.map(\.lastPathComponent) == ["report 2.7z.001", "report 2.7z.002"])
    }

    @Test("a failed verification throws away the archive instead of handing it over")
    func failedVerificationDeliversNothing() async throws {
        let (root, input) = try fixture()
        var settings = CompressionSettings.default
        settings.verifyAfterCreate = true
        let runner = FakeRunner(script: .init(addExitCode: 0, testExitCode: 2, producedSuffixes: [""]))

        await #expect(throws: (any Error).self) {
            try await CompressionEngine(runner: runner)
                .compress(self.request(inputs: [input], settings: settings))
        }
        #expect(TestSupport.entryNames(in: root) == ["report.txt"])
    }

    @Test func verificationRunsTheTestCommandOnTheFirstVolume() async throws {
        let (_, input) = try fixture()
        var settings = CompressionSettings.default
        settings.verifyAfterCreate = true
        settings.splitSize = try SplitSize.parse("1k")
        let runner = FakeRunner(script: .init(producedSuffixes: [".001", ".002"]))

        _ = try await CompressionEngine(runner: runner)
            .compress(request(inputs: [input], settings: settings))

        let testInvocations = runner.invocations.filter { $0.arguments.first == "t" }
        #expect(testInvocations.count == 1)
        #expect(testInvocations[0].arguments.last?.hasSuffix(".7z.001") == true)
    }

    @Test func fixedDestinationDirectoryIsHonoured() async throws {
        let (_, input) = try fixture()
        let elsewhere = try TestSupport.makeTemporaryDirectory()
        var settings = CompressionSettings.default
        settings.verifyAfterCreate = false
        settings.destination = .fixedDirectory(elsewhere)

        let outcome = try await CompressionEngine(runner: FakeRunner())
            .compress(request(inputs: [input], settings: settings))

        #expect(outcome.archiveURLs[0].deletingLastPathComponent().path == elsewhere.path)
        #expect(TestSupport.entryNames(in: elsewhere) == ["report.7z"])
    }

    @Test("a configured destination that no longer exists fails loudly instead of falling back to the source folder")
    func missingFixedDestinationFailsClosed() async throws {
        let (root, input) = try fixture()
        var settings = CompressionSettings.default
        settings.verifyAfterCreate = false
        settings.destination = .fixedDirectory(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))

        await #expect(throws: (any Error).self) {
            try await CompressionEngine(runner: FakeRunner())
                .compress(self.request(inputs: [input], settings: settings))
        }
        #expect(TestSupport.entryNames(in: root) == ["report.txt"])
    }

    @Test func pointingTheDestinationAtAFileIsRejected() async throws {
        let (root, input) = try fixture()
        var settings = CompressionSettings.default
        settings.destination = .fixedDirectory(root.appendingPathComponent("report.txt"))

        await #expect(throws: CompressorError.destinationIsNotADirectory(root.appendingPathComponent("report.txt").path)) {
            try await CompressionEngine(runner: FakeRunner())
                .compress(self.request(inputs: [input], settings: settings))
        }
    }

    @Test func progressEventsReachTheCaller() async throws {
        let (_, input) = try fixture()
        let runner = FakeRunner(script: .init(stdoutText: "  0%\u{08}\u{08}\u{08}\u{08} 50% 1 + report.txt\nEverything is Ok\n"))
        let box = EventBox()
        _ = try await CompressionEngine(runner: runner).compress(request(inputs: [input])) { box.append($0) }
        let percentages = box.events.compactMap { event -> Int? in
            if case .progress(let p, _) = event { return p } else { return nil }
        }
        #expect(percentages == [0, 50])
        #expect(box.events.contains(.finishedOK))
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [SevenZipOutputParser.Event] = []
    func append(_ event: SevenZipOutputParser.Event) { lock.withLock { storage.append(event) } }
    var events: [SevenZipOutputParser.Event] { lock.withLock { storage } }
}
