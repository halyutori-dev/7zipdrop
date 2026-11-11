import Foundation
import Testing
@testable import CompressorCore

/// Regression tests for the process plumbing itself. An earlier version used
/// `Process.waitUntilExit()` on a Dispatch worker thread and deadlocked after the child
/// had already exited, so these assert that a run actually *returns*.
@Suite("LiveSevenZipRunner", .timeLimit(.minutes(1)))
struct RunnerTests {

    private func invocation(_ arguments: [String]) -> SevenZipInvocation {
        SevenZipInvocation(
            executableURL: TestSupport.sevenZipURL,
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            stdinPayload: nil)
    }

    @Test func returnsPromptlyWithTheExitCode() async throws {
        let code = try await LiveSevenZipRunner().run(invocation(["i"])) { _ in }
        #expect(code == 0)
    }

    @Test func capturesTheChildOutput() async throws {
        let collected = OutputBox()
        _ = try await LiveSevenZipRunner().run(invocation(["i"])) { collected.append($0) }
        #expect(collected.text.contains("7-Zip"))
        #expect(collected.text.contains("26.02"))
    }

    @Test("a bad command line comes back as 7-Zip's own error code, not a hang")
    func reportsCommandLineErrors() async throws {
        let code = try await LiveSevenZipRunner().run(invocation(["a", "-mx=nonsense", "--", "/dev/null/nope.7z"])) { _ in }
        #expect(code != 0)
        #expect(SevenZipExitStatus(code: code) != .success)
    }

    @Test("a child that exits without reading the password does not take the app down with SIGPIPE")
    func survivesAChildThatNeverReadsStdin() async throws {
        // `true` never reads stdin; 1 MiB outlives the pipe buffer, so the write is
        // guaranteed to hit a closed pipe. Unhandled, SIGPIPE kills this whole process.
        let invocation = SevenZipInvocation(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: [],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            stdinPayload: Data(count: 1024 * 1024))
        let code = try await LiveSevenZipRunner().run(invocation) { _ in }
        #expect(code == 0)
    }

    @Test func launchingAMissingBinaryThrowsInsteadOfHanging() async throws {
        let bad = SevenZipInvocation(
            executableURL: URL(fileURLWithPath: "/nonexistent/7zz-\(UUID().uuidString)"),
            arguments: ["i"],
            workingDirectory: URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
            stdinPayload: nil)
        await #expect(throws: (any Error).self) {
            try await LiveSevenZipRunner().run(bad) { _ in }
        }
    }

    @Test("the whole output is delivered even though the child exits immediately after writing it")
    func noTrailingOutputIsLost() async throws {
        // 7zz's own listing is several KB; a termination race would truncate it.
        let collected = OutputBox()
        _ = try await LiveSevenZipRunner().run(invocation(["i"])) { collected.append($0) }
        #expect(collected.text.contains("Codecs:") || collected.text.contains("Formats:"))
        #expect(collected.text.count > 500)
    }

    @Test("progress arrives WHILE the work happens, not in one burst at the end")
    func progressArrivesIncrementally() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let payload = directory.appendingPathComponent("random.bin")
        // Incompressible, and big enough that the run lasts a couple of seconds.
        var bytes = Data(count: 96 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try bytes.write(to: payload)

        let work = SevenZipInvocation(
            executableURL: TestSupport.sevenZipURL,
            arguments: ["a", "-t7z", "-mx=5", "-spd", "-bso1", "-bse2", "-bsp1", "--",
                        directory.appendingPathComponent("out.7z").path, "random.bin"],
            workingDirectory: directory,
            stdinPayload: nil)

        let timeline = Timeline()
        let parserBox = ParserBox()
        let started = ProcessInfo.processInfo.systemUptime
        _ = try await LiveSevenZipRunner().run(work) { chunk in
            for event in parserBox.consume(chunk) {
                if case .progress = event { timeline.record() }
            }
        }
        let finished = ProcessInfo.processInfo.systemUptime
        let stamps = timeline.stamps

        #expect(!stamps.isEmpty, "no progress at all")
        #expect(finished - started > 1.0, "the workload was too short to be a meaningful check")

        // 7zz emits a progress line roughly every 200 ms, so a run this long must produce
        // updates at several distinct moments. Reading the pipe in a way that only yields
        // at EOF collapses them all into one, which is invisible to the user.
        let buckets = Set(stamps.map { Int(($0 - started) * 10) })   // 100 ms buckets
        #expect(buckets.count >= 5, "progress landed in only \(buckets.count) moment(s) — not streaming")

        let firstProgress = try #require(stamps.min())
        #expect(finished - firstProgress > 0.4,
                "the first update arrived only \(finished - firstProgress)s before the end")
    }

    @Test("cancellation ends the run with 7-Zip's user-stopped code (contract #15)")
    func cancellationIsHonoured() async throws {
        let directory = try TestSupport.makeTemporaryDirectory()
        let payload = directory.appendingPathComponent("random.bin")
        var bytes = Data(count: 24 * 1024 * 1024)
        bytes.withUnsafeMutableBytes { _ = SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        try bytes.write(to: payload)

        let work = SevenZipInvocation(
            executableURL: TestSupport.sevenZipURL,
            arguments: ["a", "-t7z", "-mx=9", "-spd", "-bsp1", "--",
                        directory.appendingPathComponent("out.7z").path, "random.bin"],
            workingDirectory: directory,
            stdinPayload: nil)

        let task = Task { try await LiveSevenZipRunner().run(work) { _ in } }
        try await Task.sleep(for: .milliseconds(600))
        task.cancel()
        let code = try await task.value
        #expect(SevenZipExitStatus(code: code) == .cancelled)
    }
}

/// Records when each progress event was observed.
private final class Timeline: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func record() { lock.withLock { storage.append(ProcessInfo.processInfo.systemUptime) } }
    var stamps: [Double] { lock.withLock { storage } }
}

private final class ParserBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = SevenZipOutputParser()
    func consume(_ data: Data) -> [SevenZipOutputParser.Event] {
        lock.withLock { parser.consume(data) }
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
}
