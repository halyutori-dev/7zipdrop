import Foundation

public struct ExtractionRequest: Sendable {
    public let archive: URL
    public let settings: ExtractionSettings
    public let password: Password?
    public let executable: URL

    public init(archive: URL, settings: ExtractionSettings, password: Password?, executable: URL) {
        self.archive = archive
        self.settings = settings
        self.password = password
        self.executable = executable
    }
}

public struct ExtractionOutcome: Sendable, Equatable {
    /// The delivered folder, or the single file when the archive held exactly one.
    public let outputURL: URL
    public let fileCount: Int
    public let totalBytes: Int64
    public let status: SevenZipExitStatus
    /// Entry paths that tried to escape and were let through because the user allowed it.
    public let sanitizedPaths: [String]
    /// e.g. "backup.tar" when a .tar.gz was unwrapped twice.
    public let followedInnerArchive: String?
    public let log: [String]

    public var hadWarnings: Bool { status == .warning }
}

public struct ExtractionEngine: Sendable {
    static let stagingPrefix = ".7zx-staging-"
    /// How often an extraction whose size the listing cannot bound is measured. 7zz
    /// decodes a stream of zeros at up to ~1.5 GB/s, so a bomb can overshoot by that much
    /// per interval before SIGTERM lands; the 1 GiB disk headroom absorbs it, and the
    /// ceiling is re-checked once more after exit so nothing over it is ever delivered.
    static let budgetPollInterval: Duration = .milliseconds(100)

    /// `Type` values 7zz reports for single-stream formats (contract #42). Detected from
    /// content, so a renamed file is still recognised.
    static let singleStreamTypes: Set<String> = ["gzip", "bzip2", "xz", "zstd", "lzma", "Z"]

    private let runner: any SevenZipRunning
    private let probe: any FileSystemProbing
    private let mover: any FileMoving
    private let remover: any SourceRemoving
    private let freeSpace: @Sendable (URL) -> Int64

    public init(
        runner: any SevenZipRunning = LiveSevenZipRunner(),
        probe: any FileSystemProbing = LiveFileSystemProbe(),
        mover: any FileMoving = AtomicFileMover(),
        remover: any SourceRemoving = TrashSourceRemover(),
        freeSpace: @escaping @Sendable (URL) -> Int64 = ExtractionEngine.availableBytes
    ) {
        self.runner = runner
        self.probe = probe
        self.mover = mover
        self.remover = remover
        self.freeSpace = freeSpace
    }

    public func extract(
        _ request: ExtractionRequest,
        onEvent: @escaping @Sendable (SevenZipOutputParser.Event) -> Void = { _ in }
    ) async throws -> ExtractionOutcome {
        let archive = try resolveArchive(request.archive)
        let destination = try resolveDestination(archive: archive, settings: request.settings)

        // 1. Read the archive before touching anything: the listing is what the safety
        //    gate is built on, and it also tells us whether a password is needed at all.
        let listing = try await readListing(archive: archive, request: request)
        try ExtractionSafety.check(
            listing, settings: request.settings,
            availableBytes: freeSpace(destination))

        let staging = destination.appendingPathComponent(Self.stagingPrefix + UUID().uuidString)
        try createStaging(staging, destination: destination)
        defer { try? FileManager.default.removeItem(at: staging) }

        // 2. Extract into an empty directory, so nothing of the user's can be hit.
        let content = staging.appendingPathComponent("content", isDirectory: true)
        let collector = OutputCollector()
        let status = try await run(
            SevenZipCommandBuilder.extract(
                executable: request.executable, archive: archive,
                into: content, password: request.password,
                overwriteExisting: request.settings.overwriteExisting),
            collector: collector, onEvent: onEvent,
            watching: content,
            budget: outputBudget(for: listing, of: archive, settings: request.settings, destination: destination))

        guard status.isUsableArchive else {
            if let problem = SevenZipDiagnostics.passwordProblem(
                in: collector.rawText, passwordSupplied: request.password != nil) {
                throw problem
            }
            if status == .cancelled { throw CompressorError.cancelled }
            throw CompressorError.extractionFailed(
                status: status, log: collector.collectedMessages.joined(separator: "\n"))
        }
        try assertNoSymlinkEscapes(in: content)

        // 3. `foo.tar.gz` leaves a `foo.tar`; unwrap that one extra layer (contract #32).
        var current = content
        var followed: String?
        if let inner = try singleStreamInnerArchive(in: content, archive: archive, settings: request.settings) {
            let innerListing = try await readListing(archive: inner, request: request)
            try ExtractionSafety.check(
                innerListing, settings: request.settings,
                availableBytes: freeSpace(destination))
            let innerOutput = staging.appendingPathComponent("inner", isDirectory: true)
            let innerStatus = try await run(
                SevenZipCommandBuilder.extract(
                    executable: request.executable, archive: inner,
                    into: innerOutput, password: request.password,
                    overwriteExisting: request.settings.overwriteExisting),
                collector: collector, onEvent: onEvent,
                watching: innerOutput,
                budget: outputBudget(for: innerListing, of: inner, settings: request.settings, destination: destination))
            if innerStatus == .cancelled { throw CompressorError.cancelled }
            guard innerStatus.isUsableArchive else {
                throw CompressorError.extractionFailed(
                    status: innerStatus, log: collector.collectedMessages.joined(separator: "\n"))
            }
            try assertNoSymlinkEscapes(in: innerOutput)
            current = innerOutput
            followed = inner.lastPathComponent
        }

        // 4. Deliver under a name nothing else owns.
        let delivered = try deliver(from: current, archive: archive,
                                    into: destination, settings: request.settings)
        let measurements = measure(delivered)

        return ExtractionOutcome(
            outputURL: delivered,
            fileCount: measurements.fileCount,
            totalBytes: measurements.totalBytes,
            status: status,
            sanitizedPaths: listing.unsafePaths,
            followedInnerArchive: followed,
            log: collector.collectedMessages)
    }

    // MARK: - steps

    /// Contract #31: only `.001` opens a volume set.
    private func resolveArchive(_ url: URL) throws -> URL {
        guard let first = ArchiveDetection.firstVolume(of: url) else { return url }
        guard probe.fileExists(at: first) else {
            throw CompressorError.missingVolumePart(first.lastPathComponent)
        }
        return first
    }

    private func resolveDestination(archive: URL, settings: ExtractionSettings) throws -> URL {
        let directory: URL = switch settings.destination {
        case .sameAsSource: archive.deletingLastPathComponent()
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

    private func readListing(archive: URL, request: ExtractionRequest) async throws -> ArchiveListing {
        let collector = OutputCollector()
        let invocation = SevenZipCommandBuilder.list(
            executable: request.executable, archive: archive, password: request.password)
        var text = ""
        let status = try await runner.run(invocation) { chunk in
            _ = collector.consume(chunk)
        }
        _ = collector.finish()
        text = collector.rawText

        let listing = ArchiveListingParser.parse(text)
        if SevenZipExitStatus(code: status) != .success {
            // Contract #28/#35: a header-encrypted archive cannot be listed at all without
            // the password, and 7zz says so in its own words.
            if let problem = SevenZipDiagnostics.passwordProblem(
                in: text, passwordSupplied: request.password != nil) {
                throw problem
            }
            throw CompressorError.listingFailed(
                status: SevenZipExitStatus(code: status),
                log: collector.collectedMessages.joined(separator: "\n"))
        }
        if listing.containsEncryptedEntries, request.password == nil {
            throw CompressorError.passwordRequired
        }
        return listing
    }

    private func run(
        _ invocation: SevenZipInvocation,
        collector: OutputCollector,
        onEvent: @escaping @Sendable (SevenZipOutputParser.Event) -> Void,
        watching output: URL,
        budget: OutputBudget?
    ) async throws -> SevenZipExitStatus {
        let onOutput: @Sendable (Data) -> Void = { chunk in
            for event in collector.consume(chunk) { onEvent(event) }
        }
        let code: Int32
        var violation: CompressorError?
        if let budget {
            (code, violation) = try await runWatched(invocation, onOutput: onOutput, output: output, budget: budget)
        } else {
            code = try await runner.run(invocation, onOutput: onOutput)
        }
        for event in collector.finish() { onEvent(event) }
        // Checked before the exit status: the 255 that follows our own SIGTERM is not a
        // user cancellation.
        if let violation { throw violation }
        return SevenZipExitStatus(code: code)
    }

    /// What an extraction may write before 7zz is stopped.
    struct OutputBudget: Sendable {
        let ceiling: Int64
        /// Free space at the start, less the headroom that must be left alone.
        let diskAllowance: Int64
        let availableBytes: Int64

        func violation(written: Int64) -> CompressorError? {
            if written > ceiling {
                return .extractionTooLarge(totalBytes: written, limitBytes: ceiling)
            }
            if written > diskAllowance {
                return .notEnoughDiskSpace(neededBytes: written, availableBytes: availableBytes)
            }
            return nil
        }
    }

    /// Armed only when the listing cannot bound the output: a size it does not declare
    /// (contract #42), or a single-stream format, whose one declaration may be wrong —
    /// gzip stores the size modulo 2^32. Either way the output is small in entry count,
    /// so measuring it repeatedly is cheap; a fully declared multi-entry archive is
    /// bounded by `ExtractionSafety.check` alone and is never walked mid-extraction.
    func outputBudget(
        for listing: ArchiveListing, of archive: URL, settings: ExtractionSettings, destination: URL
    ) -> OutputBudget? {
        let singleStream = !listing.unnamedStreamSizes.isEmpty
            || listing.format.map(Self.singleStreamTypes.contains) == true
            || ArchiveDetection.isSingleStreamCompressor(archive)
        guard listing.hasUndeclaredSizes || singleStream else { return nil }
        let available = freeSpace(destination)
        return OutputBudget(
            ceiling: settings.maximumTotalBytes,
            diskAllowance: available - ExtractionSafety.diskHeadroomBytes,
            availableBytes: available)
    }

    private enum WatchedEvent: Sendable {
        case exited(Int32)
        case exceeded(CompressorError)
        case stopped
    }

    /// Runs 7zz next to a watchdog that measures what it has written. When the budget is
    /// exceeded the runner is cancelled — SIGTERM, then SIGKILL after the grace period —
    /// and its exit is still awaited, so the staging directory is not removed under a
    /// live process.
    private func runWatched(
        _ invocation: SevenZipInvocation,
        onOutput: @escaping @Sendable (Data) -> Void,
        output: URL,
        budget: OutputBudget
    ) async throws -> (code: Int32, violation: CompressorError?) {
        try await withThrowingTaskGroup(of: WatchedEvent.self) { group in
            group.addTask { .exited(try await runner.run(invocation, onOutput: onOutput)) }
            group.addTask {
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.budgetPollInterval)
                    if Task.isCancelled { break }
                    if let violation = budget.violation(written: measure(output).totalBytes) {
                        return .exceeded(violation)
                    }
                }
                return .stopped
            }
            var violation: CompressorError?
            while let event = try await group.next() {
                switch event {
                case .exited(let code):
                    group.cancelAll()
                    // A stream can finish between two polls; what it left behind counts too.
                    if violation == nil {
                        violation = budget.violation(written: measure(output).totalBytes)
                    }
                    return (code, violation)
                case .exceeded(let found):
                    violation = found
                    group.cancelAll()
                case .stopped:
                    continue
                }
            }
            // The runner task always yields `.exited` or throws, so this is unreachable.
            throw CompressorError.cancelled
        }
    }

    private func createStaging(_ staging: URL, destination: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: staging, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700])
        } catch {
            throw CompressorError.destinationNotWritable(destination.path)
        }
    }

    private func singleStreamInnerArchive(
        in content: URL, archive: URL, settings: ExtractionSettings
    ) throws -> URL? {
        guard settings.followSingleStreamArchives,
              ArchiveDetection.isSingleStreamCompressor(archive) else { return nil }
        let children = probe.entryNames(inDirectory: content)
        guard children.count == 1 else { return nil }
        let inner = content.appendingPathComponent(children[0])
        guard !Self.isDirectory(inner), ArchiveDetection.looksLikeArchive(inner) else { return nil }
        return inner
    }

    /// Contract #30: link targets are absent from the listing, so containment has to be
    /// checked against the real tree once it exists. Walked iteratively, and never through
    /// a symlink, so a malicious link cannot steer the walk out of the staging directory.
    func assertNoSymlinkEscapes(in root: URL) throws {
        let bases = [root.path, root.resolvingSymlinksInPath().path]
        var queue = [root]
        while let directory = queue.popLast() {
            for name in probe.entryNames(inDirectory: directory) {
                let url = directory.appendingPathComponent(name)
                let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                let isSymlink = values?.isSymbolicLink ?? false
                if isSymlink {
                    let target = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                    let resolved = PathContainment.resolve(
                        target: target, relativeTo: url.deletingLastPathComponent().path)
                    let contained = bases.contains { PathContainment.isContained(resolved, within: $0) }
                    guard contained else {
                        throw CompressorError.symlinkEscapesDestination(
                            entry: url.lastPathComponent, target: target)
                    }
                } else if values?.isDirectory == true {
                    queue.append(url)
                }
            }
        }
    }

    private func deliver(
        from content: URL, archive: URL, into destination: URL, settings: ExtractionSettings
    ) throws -> URL {
        let children = probe.entryNames(inDirectory: content).sorted()
        guard !children.isEmpty else { throw CompressorError.nothingExtracted }

        let payload: URL
        let stem: String
        let fileExtension: String

        // A single root folder already is the container, so wrapping it again would only
        // produce Docs/Docs. A single root file is wrapped only when a folder is required.
        let onlyChild = children.count == 1 ? content.appendingPathComponent(children[0]) : nil
        let deliverChildDirectly = onlyChild.map { child in
            Self.isDirectory(child) || !settings.guaranteeContainingFolder
        } ?? false

        if let onlyChild, deliverChildDirectly {
            payload = onlyChild
            if Self.isDirectory(onlyChild) {
                stem = children[0]
                fileExtension = ""
            } else {
                let name = URL(fileURLWithPath: children[0])
                fileExtension = name.pathExtension
                stem = fileExtension.isEmpty ? children[0] : name.deletingPathExtension().lastPathComponent
            }
        } else {
            payload = content
            stem = ArchiveDetection.payloadName(for: archive)
            fileExtension = ""
        }

        let target: URL
        if settings.overwriteExisting {
            // Replace what is there, but move it to the Trash first so it is recoverable.
            let name = fileExtension.isEmpty ? stem : "\(stem).\(fileExtension)"
            target = destination.appendingPathComponent(name)
            if probe.fileExists(at: target) {
                _ = try remover.remove(target)
            }
        } else {
            target = try UniqueName.pick(
                stem: stem, extension: fileExtension, in: destination, probe: probe)
        }
        if Self.isDirectory(payload) {
            try mover.claimDirectory(from: payload, to: target)
        } else {
            try mover.claim(from: payload, to: target)
        }
        return target
    }

    private func measure(_ url: URL) -> (fileCount: Int, totalBytes: Int64) {
        guard Self.isDirectory(url) else {
            return (1, Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
        }
        var files = 0
        var bytes: Int64 = 0
        var queue = [url]
        while let directory = queue.popLast() {
            for name in probe.entryNames(inDirectory: directory) {
                let child = directory.appendingPathComponent(name)
                let values = try? child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .fileSizeKey])
                if values?.isSymbolicLink == true {
                    files += 1
                } else if values?.isDirectory == true {
                    queue.append(child)
                } else {
                    files += 1
                    bytes += Int64(values?.fileSize ?? 0)
                }
            }
        }
        return (files, bytes)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    /// Unknown capacity does not block extraction — the absolute ceiling in
    /// `ExtractionSettings.maximumTotalBytes` still applies.
    public static func availableBytes(at url: URL) -> Int64 {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity)
        }
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]),
           let capacity = values.volumeAvailableCapacity {
            return Int64(capacity)
        }
        return Int64.max
    }
}
