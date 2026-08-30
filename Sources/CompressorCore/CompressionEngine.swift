import Foundation

public struct CompressionRequest: Sendable {
    public let inputs: [URL]
    public let settings: CompressionSettings
    public let password: Password?
    public let executable: URL

    public init(inputs: [URL], settings: CompressionSettings, password: Password?, executable: URL) {
        self.inputs = inputs
        self.settings = settings
        self.password = password
        self.executable = executable
    }
}

/// What the post-creation integrity check actually did — never inferred from a flag, so
/// the UI can say "verified" only when something really was verified.
public enum VerificationResult: Sendable, Equatable {
    case notRequested
    case passed
    /// Requested, but skipped because verifying would have required putting the password
    /// on the command line (contract #21) and the user has not opted into that.
    case skippedBecauseEncrypted
}

public struct CompressionOutcome: Sendable, Equatable {
    /// The delivered archive, or all of its volume parts in order.
    public let archiveURLs: [URL]
    public let status: SevenZipExitStatus
    public let totalBytes: Int64
    public let log: [String]
    public let verification: VerificationResult
    /// Originals moved to the Trash because the user asked for that.
    public let removedSources: [URL]
    /// Originals that were meant to be removed but could not be.
    public let removalFailures: [String]

    public var primaryURL: URL? { archiveURLs.first }
    public var hadWarnings: Bool { status == .warning }
}

/// Collects parser output from the runner's callback thread.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = SevenZipOutputParser()
    private var messages: [String] = []
    private var raw = Data()
    private var archiveSize: Int64 = 0
    private static let messageLimit = 400

    /// Events are drained under the lock but delivered outside it, so a callback that
    /// re-enters cannot deadlock.
    func consume(_ data: Data) -> [SevenZipOutputParser.Event] {
        lock.lock()
        raw.append(data)
        let events = parser.consume(data)
        record(events)
        lock.unlock()
        return events
    }

    func finish() -> [SevenZipOutputParser.Event] {
        lock.lock()
        let events = parser.finish()
        record(events)
        lock.unlock()
        return events
    }

    /// Caller must hold the lock.
    private func record(_ events: [SevenZipOutputParser.Event]) {
        for event in events {
            switch event {
            case .message(let text):
                if messages.count < Self.messageLimit { messages.append(text) }
            case .archiveSize(let size):
                archiveSize = size
            default:
                break
            }
        }
    }

    var collectedMessages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return messages
    }

    /// The child's output exactly as produced — needed for `l -slt`, whose value is its
    /// structure rather than the event stream.
    var rawText: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: raw, as: UTF8.self)
    }
}

public struct CompressionEngine: Sendable {
    /// Staging directories are created inside the destination so the final step is a
    /// same-filesystem link, and so a crash never leaves debris next to the user's files.
    static let stagingPrefix = ".7zc-staging-"
    static let deliveryAttempts = 5

    private let runner: any SevenZipRunning
    private let probe: any FileSystemProbing
    private let mover: any FileMoving
    private let remover: any SourceRemoving

    public init(
        runner: any SevenZipRunning = LiveSevenZipRunner(),
        probe: any FileSystemProbing = LiveFileSystemProbe(),
        mover: any FileMoving = AtomicFileMover(),
        remover: any SourceRemoving = TrashSourceRemover()
    ) {
        self.runner = runner
        self.probe = probe
        self.mover = mover
        self.remover = remover
    }

    public func compress(
        _ request: CompressionRequest,
        onEvent: @escaping @Sendable (SevenZipOutputParser.Event) -> Void = { _ in }
    ) async throws -> CompressionOutcome {
        let plan = try InputPlan.make(from: request.inputs)
        let destination = try resolveDestination(plan: plan, settings: request.settings)
        let baseName = ArchiveNaming.baseName(for: plan)

        let staging = destination.appendingPathComponent(Self.stagingPrefix + UUID().uuidString)
        try createStagingDirectory(staging, destination: destination)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Clamped exactly like the delivered name, otherwise a very long source name
        // produces a staging file that exceeds the 255-byte filename limit and 7zz fails
        // with an opaque filesystem error.
        let stagedStem = ArchiveNamer.clamp(
            ArchiveNamer.sanitize(baseName),
            extensionLength: request.settings.format.fileExtension.utf8.count)
        let stagedName = "\(stagedStem).\(request.settings.format.fileExtension)"
        let stagedArchive = staging.appendingPathComponent(stagedName)

        let invocation = try SevenZipCommandBuilder.add(
            executable: request.executable,
            archive: stagedArchive,
            plan: plan,
            settings: request.settings,
            password: request.password
        )

        let collector = OutputCollector()
        let code = try await runner.run(invocation) { chunk in
            for event in collector.consume(chunk) { onEvent(event) }
        }
        for event in collector.finish() { onEvent(event) }

        let status = SevenZipExitStatus(code: code)
        if status == .cancelled { throw CompressorError.cancelled }
        guard status.isUsableArchive else {
            throw CompressorError.sevenZipFailed(status: status, log: collector.collectedMessages.joined(separator: "\n"))
        }

        let produced = try stagedOutputs(in: staging, named: stagedName)
        guard !produced.isEmpty else { throw CompressorError.noArchiveProduced }

        let verification = try await runVerification(on: produced[0], request: request)

        let delivered = try deliver(produced, stagedName: stagedName, baseName: baseName,
                                   into: destination, settings: request.settings, staging: staging)

        let cleanup = removeSourcesIfAsked(plan: plan, settings: request.settings, status: status)

        return CompressionOutcome(
            archiveURLs: delivered,
            status: status,
            totalBytes: totalSize(of: delivered),
            log: collector.collectedMessages,
            verification: verification,
            removedSources: cleanup.removed,
            removalFailures: cleanup.failures
        )
    }

    // MARK: - steps

    private func resolveDestination(plan: InputPlan, settings: CompressionSettings) throws -> URL {
        let directory: URL = switch settings.destination {
        case .sameAsSource: plan.workingDirectory
        case .fixedDirectory(let url): url
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw CompressorError.destinationNotWritable(directory.path)
        }
        guard isDirectory.boolValue else {
            throw CompressorError.destinationIsNotADirectory(directory.path)
        }
        return directory
    }

    private func createStagingDirectory(_ staging: URL, destination: URL) throws {
        do {
            // 0700: the staged archive may be encrypted, and it briefly sits in a
            // directory the user shares with other files.
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            // Creating it is the authoritative writability test; `isWritableFile` lies
            // under some ACL configurations.
            throw CompressorError.destinationNotWritable(destination.path)
        }
    }

    private func stagedOutputs(in staging: URL, named stagedName: String) throws -> [URL] {
        probe.entryNames(inDirectory: staging)
            .filter { $0 == stagedName || $0.hasPrefix(stagedName + ".") }
            .sorted()
            .map { staging.appendingPathComponent($0) }
    }

    private func runVerification(on archive: URL, request: CompressionRequest) async throws -> VerificationResult {
        guard request.settings.verifyAfterCreate else { return .notRequested }
        if request.password != nil && !request.settings.verifyEncryptedArchives {
            return .skippedBecauseEncrypted
        }
        try await verify(archive, request: request)
        return .passed
    }

    private func verify(_ archive: URL, request: CompressionRequest) async throws {
        let collector = OutputCollector()
        let invocation = SevenZipCommandBuilder.test(
            executable: request.executable, archive: archive, password: request.password)
        let code = try await runner.run(invocation) { chunk in _ = collector.consume(chunk) }
        _ = collector.finish()
        let status = SevenZipExitStatus(code: code)
        guard status.isSuccess else {
            throw CompressorError.verificationFailed(
                status: status, log: collector.collectedMessages.joined(separator: "\n"))
        }
    }

    /// Claims final names atomically, rolling the whole set back if a later part loses a race.
    private func deliver(
        _ produced: [URL], stagedName: String, baseName: String,
        into destination: URL, settings: CompressionSettings, staging: URL
    ) throws -> [URL] {
        let namer = ArchiveNamer(probe: probe)
        var lastError: any Error = CompressorError.noArchiveProduced

        for _ in 1...Self.deliveryAttempts {
            let finalBase = try namer.uniqueArchiveURL(
                baseName: baseName, format: settings.format, in: destination)
            var delivered: [URL] = []
            do {
                for source in produced {
                    // "base.7z.003" → suffix ".003", carried over to the final name.
                    let suffix = String(source.lastPathComponent.dropFirst(stagedName.count))
                    let target = destination.appendingPathComponent(finalBase.lastPathComponent + suffix)
                    try mover.claim(from: source, to: target)
                    delivered.append(target)
                }
                return delivered
            } catch {
                rollBack(delivered, into: staging, stagedName: stagedName, finalName: finalBase.lastPathComponent)
                lastError = error
            }
        }
        throw lastError
    }

    private func rollBack(_ delivered: [URL], into staging: URL, stagedName: String, finalName: String) {
        for url in delivered {
            let suffix = String(url.lastPathComponent.dropFirst(finalName.count))
            try? FileManager.default.moveItem(at: url, to: staging.appendingPathComponent(stagedName + suffix))
        }
    }

    /// Runs only after the archive is in place, and only on an unqualified success:
    /// a warning means 7-Zip left something out, and the originals are then the only copy.
    private func removeSourcesIfAsked(
        plan: InputPlan, settings: CompressionSettings, status: SevenZipExitStatus
    ) -> (removed: [URL], failures: [String]) {
        guard settings.deleteSourcesAfterSuccess, status == .success else { return ([], []) }
        var removed: [URL] = []
        var failures: [String] = []
        // Exactly what was archived, so a pruned descendant is not deleted twice.
        for name in plan.relativeNames {
            let source = plan.workingDirectory.appendingPathComponent(name)
            do {
                _ = try remover.remove(source)
                removed.append(source)
            } catch {
                failures.append("\(name): \(error.localizedDescription)")
            }
        }
        return (removed, failures)
    }

    private func totalSize(of urls: [URL]) -> Int64 {
        urls.reduce(into: Int64(0)) { total, url in
            let values = try? url.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
    }
}
