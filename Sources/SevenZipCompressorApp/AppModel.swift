import AppKit
import Foundation
import Observation
@preconcurrency import UserNotifications
import CompressorCore

enum JobWork: Sendable {
    case compress(CompressionRequest)
    case extract(ExtractionRequest)
}

@MainActor
@Observable
final class Job: Identifiable {
    enum Kind: Sendable { case compress, extract }

    enum Outcome: Equatable, Sendable {
        case compressed(CompressionOutcome)
        case extracted(ExtractionOutcome)

        var urls: [URL] {
            switch self {
            case .compressed(let outcome): outcome.archiveURLs
            case .extracted(let outcome): [outcome.outputURL]
            }
        }
    }

    enum State: Equatable {
        case queued
        case running
        case succeeded(Outcome)
        case failed(message: String, needsPassword: Bool)
        case cancelled
    }

    let id = UUID()
    let title: String
    let kind: Kind
    /// Kept so a failed job can be retried once a password is known.
    let sources: [URL]
    let work: JobWork
    var state: State = .queued
    var percent: Int?
    var currentItem: String?
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, kind: Kind, sources: [URL], work: JobWork) {
        self.title = title
        self.kind = kind
        self.sources = sources
        self.work = work
    }

    var isFinished: Bool {
        switch state {
        case .queued, .running: false
        case .succeeded, .failed, .cancelled: true
        }
    }

    var revealsInFinder: Bool {
        switch work {
        case .compress(let request): request.settings.revealInFinder
        case .extract(let request): request.settings.revealInFinder
        }
    }

    var notifiesOnCompletion: Bool {
        switch work {
        case .compress(let request): request.settings.notifyOnCompletion
        case .extract(let request): request.settings.notifyOnCompletion
        }
    }
}

@MainActor
@Observable
final class AppModel {
    // MARK: settings

    var settings: AppSettings {
        didSet {
            validateSettings()
            store.save(settings)
        }
    }

    var settingsTab: SettingsTab {
        didSet { store.saveSettingsTab(settingsTab) }
    }

    var isSettingsOpen: Bool {
        didSet { store.saveSettingsOpen(isSettingsOpen) }
    }

    private(set) var settingsError: String?
    private(set) var jobs: [Job] = []
    private(set) var sevenZipURL: URL?
    private(set) var setupProblem: String?
    /// Read from a plain flag in UserDefaults, never from the keychain: a keychain read
    /// blocks until securityd (and possibly the user) answers, and doing that on the main
    /// thread at launch deadlocks the app before it can even show a window.
    private(set) var hasSharedPassword: Bool
    /// Only one prompt is on screen at a time; the rest wait their turn.
    private(set) var passwordRequest: PasswordRequest?
    private var pendingPasswordRequests: [PasswordRequest] = []

    private let store = SettingsStore()
    private let keychain = KeychainPasswordStore()
    private var cachedSharedPassword: Password?
    private let compressor = CompressionEngine()
    private let extractor = ExtractionEngine()
    private var isRunning = false

    init() {
        settings = store.load()
        settingsTab = store.loadSettingsTab()
        isSettingsOpen = store.loadSettingsOpen()
        hasSharedPassword = store.loadHasSharedPassword()
        validateSettings()
        locateSevenZip()
    }

    // MARK: 7zz discovery

    func locateSevenZip() {
        let bundled = Self.bundledSevenZipCandidates
        if let found = SevenZipLocator().locate(override: store.loadExecutableOverride(), bundled: bundled) {
            sevenZipURL = found
            setupProblem = nil
        } else {
            sevenZipURL = nil
            setupProblem = """
                7-Zip 実行ファイル (7zz) が見つかりません。
                アプリに同梱されているはずの場所: \(bundled.first?.path ?? "-")
                「7zz を選択…」から手動で指定することもできます。
                """
        }
    }

    func useExecutable(at url: URL) {
        guard SevenZipLocator().isUsable(url) else {
            setupProblem = "選択されたファイルは実行可能ではありません: \(url.path)"
            return
        }
        store.saveExecutableOverride(url)
        locateSevenZip()
    }

    static var bundledSevenZipCandidates: [URL] {
        let bundle = Bundle.main.bundleURL
        return [
            bundle.appendingPathComponent("Contents/Helpers/7zz"),
            bundle.appendingPathComponent("Contents/MacOS/7zz"),
            // Running straight from `swift run` during development.
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("vendor/ex/7zz"),
        ]
    }

    var sevenZipVersionSummary: String {
        guard let sevenZipURL else { return "7zz: 見つかりません" }
        return "7zz: \(sevenZipURL.path)"
    }

    // MARK: settings validation & preview

    private func validateSettings() {
        do {
            _ = try settings.compressionSettings()
            _ = try settings.extractionSettings()
            settingsError = nil
        } catch {
            settingsError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    func commandPreview(for format: ArchiveFormat) -> String {
        guard let sevenZipURL else { return "（7zz が未設定のためプレビューできません）" }
        var preview = settings
        preview.general.format = format
        guard var compression = try? preview.compressionSettings() else {
            return "（設定を修正するとプレビューが表示されます）"
        }
        // The preview must not imply an encrypted command when nothing is configured.
        let password: Password? = preview.formatSettings(for: format).passwordMode.encrypts
            ? try? Password("********") : nil
        if password == nil { compression.encryptFileNames = false }

        let sample = [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Desktop/example.txt")]
        guard let plan = try? InputPlan.make(from: sample) else { return "（プレビュー不可）" }
        let archive = plan.workingDirectory.appendingPathComponent(
            "\(ArchiveNaming.baseName(for: plan)).\(format.fileExtension)")
        guard let invocation = try? SevenZipCommandBuilder.add(
            executable: sevenZipURL, archive: archive, plan: plan,
            settings: compression, password: password) else { return "（プレビュー不可）" }
        return invocation.displayCommandLine
    }

    // MARK: shared password

    func requestSharedPasswordChange() {
        enqueuePasswordRequest(PasswordRequest(
            purpose: .setShared,
            prefill: "",
            completion: { [weak self] password in
                guard let self else { return }
                self.finishPasswordRequest()
                guard let password else { return }
                self.storeSharedPassword(password)
            }))
    }

    func clearSharedPassword() {
        cachedSharedPassword = nil
        hasSharedPassword = false
        store.saveHasSharedPassword(false)
        let keychain = self.keychain
        Task.detached(priority: .utility) { try? keychain.delete() }
    }

    private func storeSharedPassword(_ password: Password) {
        cachedSharedPassword = password
        hasSharedPassword = true
        store.saveHasSharedPassword(true)
        let keychain = self.keychain
        Task.detached(priority: .userInitiated) { try? keychain.save(password) }
    }

    /// Reads off the main thread, so securityd's approval dialog can appear without
    /// freezing the UI. The result is cached for the rest of the session.
    private func sharedPassword() async -> Password? {
        if let cachedSharedPassword { return cachedSharedPassword }
        guard hasSharedPassword else { return nil }
        let keychain = self.keychain
        let loaded = await Task.detached(priority: .userInitiated) {
            (try? keychain.load()) ?? nil
        }.value
        cachedSharedPassword = loaded
        if loaded == nil {
            // The entry is gone or unreadable; stop claiming we have one.
            hasSharedPassword = false
            store.saveHasSharedPassword(false)
        }
        return loaded
    }

    // MARK: password prompt plumbing

    private func enqueuePasswordRequest(_ request: PasswordRequest) {
        if passwordRequest == nil {
            passwordRequest = request
        } else {
            pendingPasswordRequests.append(request)
        }
    }

    private func finishPasswordRequest() {
        passwordRequest = pendingPasswordRequests.isEmpty ? nil : pendingPasswordRequests.removeFirst()
    }

    /// Dismissed without answering (Esc, or the sheet being closed some other way):
    /// tell the waiting caller it was cancelled so nothing is left half-started.
    func cancelPasswordRequest() {
        guard let request = passwordRequest else { return }
        request.completion(nil)
        // The completion calls finishPasswordRequest itself; guard against a stuck sheet
        // if some future caller forgets to.
        if passwordRequest?.id == request.id { finishPasswordRequest() }
    }

    // MARK: queue

    func enqueue(_ urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard sevenZipURL != nil,
              let action = DropClassifier.classify(files, mode: settings.general.dropMode) else { return }

        switch action {
        case .compress(let inputs):
            resolveCompressionPassword(for: inputs) { [weak self] password in
                self?.startCompression(inputs, password: password)
            }
        case .extract(let archives):
            // Try the shared password first; the engine says if one is actually needed.
            Task { [weak self] in
                guard let self else { return }
                let stored = await self.sharedPassword()
                for archive in archives { self.startExtraction(archive, password: stored) }
            }
        }
    }

    /// Applies the 「しない / 都度質問 / 毎回共通」 setting of the active format.
    private func resolveCompressionPassword(
        for inputs: [URL], then continuation: @escaping (Password?) -> Void
    ) {
        let name = Self.title(for: inputs)
        switch settings.activePasswordMode {
        case .none:
            continuation(nil)
        case .shared:
            Task { [weak self] in
                guard let self else { return }
                if let stored = await self.sharedPassword() {
                    continuation(stored)
                    return
                }
                // Nothing saved yet: ask once, keep it, and carry on.
                self.enqueuePasswordRequest(PasswordRequest(
                    purpose: .setShared, prefill: "",
                    completion: { password in
                        self.finishPasswordRequest()
                        guard let password else { return }
                        self.storeSharedPassword(password)
                        continuation(password)
                    }))
            }
        case .askEachTime:
            enqueuePasswordRequest(PasswordRequest(
                purpose: .compress(itemName: name), prefill: "",
                completion: { [weak self] password in
                    self?.finishPasswordRequest()
                    guard let password else { return }   // cancelled: nothing is compressed
                    continuation(password)
                }))
        }
    }

    private func startCompression(_ inputs: [URL], password: Password?) {
        guard let executable = sevenZipURL,
              let compression = try? settings.compressionSettings() else { return }
        jobs.append(Job(
            title: Self.title(for: inputs),
            kind: .compress,
            sources: inputs,
            work: .compress(CompressionRequest(
                inputs: inputs, settings: compression,
                password: password, executable: executable))))
        startNextIfIdle()
    }

    private func startExtraction(_ archive: URL, password: Password?) {
        guard let executable = sevenZipURL,
              let extraction = try? settings.extractionSettings() else { return }
        jobs.append(Job(
            title: archive.lastPathComponent,
            kind: .extract,
            sources: [archive],
            work: .extract(ExtractionRequest(
                archive: archive, settings: extraction,
                password: password, executable: executable))))
        startNextIfIdle()
    }

    /// Asks for the password and runs the job again with it.
    func retryWithPassword(_ job: Job) {
        // Only an already-cached value is used for the prefill; reading the keychain here
        // would block the main thread.
        let prefill = cachedSharedPassword?.value ?? ""
        enqueuePasswordRequest(PasswordRequest(
            purpose: job.kind == .extract
                ? .extract(archiveName: job.title)
                : .compress(itemName: job.title),
            prefill: prefill,
            completion: { [weak self] password in
                guard let self else { return }
                self.finishPasswordRequest()
                guard let password else { return }
                self.jobs.removeAll { $0.id == job.id }
                switch job.kind {
                case .extract:
                    for archive in job.sources { self.startExtraction(archive, password: password) }
                case .compress:
                    self.startCompression(job.sources, password: password)
                }
            }))
    }

    func retry(_ job: Job) {
        jobs.removeAll { $0.id == job.id }
        enqueue(job.sources)
    }

    func cancel(_ job: Job) {
        if job.state == .queued {
            job.state = .cancelled
            return
        }
        job.task?.cancel()
    }

    func clearFinished() {
        jobs.removeAll(where: \.isFinished)
    }

    func reveal(_ urls: [URL]) {
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    private static func title(for urls: [URL]) -> String {
        guard let first = urls.first else { return "（空）" }
        return urls.count == 1
            ? first.lastPathComponent
            : "\(first.lastPathComponent) ほか \(urls.count - 1) 項目"
    }

    /// One archive at a time: 7zz already uses every core, so running jobs in parallel
    /// only makes each one slower.
    private func startNextIfIdle() {
        guard !isRunning, let job = jobs.first(where: { $0.state == .queued }) else { return }
        isRunning = true
        job.state = .running

        let compressor = self.compressor
        let extractor = self.extractor
        let work = job.work

        job.task = Task { [weak self] in
            let result: Result<Job.Outcome, any Error>
            do {
                switch work {
                case .compress(let request):
                    let outcome = try await compressor.compress(request) { event in
                        Self.report(event, to: job)
                    }
                    result = .success(.compressed(outcome))
                case .extract(let request):
                    let outcome = try await extractor.extract(request) { event in
                        Self.report(event, to: job)
                    }
                    result = .success(.extracted(outcome))
                }
            } catch {
                result = .failure(error)
            }
            self?.finish(job, with: result)
        }
    }

    private nonisolated static func report(
        _ event: SevenZipOutputParser.Event, to job: Job
    ) {
        Task { @MainActor [weak job] in
            guard let job, case .progress(let percent, let item) = event else { return }
            job.percent = percent
            if let item { job.currentItem = item }
        }
    }

    private func finish(_ job: Job, with result: Result<Job.Outcome, any Error>) {
        switch result {
        case .success(let outcome):
            job.state = .succeeded(outcome)
            job.percent = 100
            if job.revealsInFinder { reveal(outcome.urls) }
            if job.notifiesOnCompletion { notify(job, outcome: outcome) }
        case .failure(let error):
            let compressorError = error as? CompressorError
            if error is CancellationError || compressorError == .cancelled {
                job.state = .cancelled
            } else {
                let needsPassword = compressorError == .passwordRequired || compressorError == .wrongPassword
                job.state = .failed(
                    message: (error as? LocalizedError)?.errorDescription ?? "\(error)",
                    needsPassword: needsPassword)
                // Extraction cannot know it needs a password until it looks inside, so
                // asking now is the natural moment rather than making the user retry.
                if needsPassword, job.kind == .extract { retryWithPassword(job) }
            }
        }
        isRunning = false
        startNextIfIdle()
    }

    private func notify(_ job: Job, outcome: Job.Outcome) {
        let content = UNMutableNotificationContent()
        content.title = job.kind == .compress ? "圧縮が完了しました" : "展開が完了しました"
        var body = outcome.urls.first?.lastPathComponent ?? job.title
        if case .compressed(let compressed) = outcome, compressed.hadWarnings { body += "（警告あり）" }
        content.body = body
        let request = UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil)
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            center.add(request, withCompletionHandler: nil)
        }
    }
}

/// Settings live in UserDefaults; passwords never do.
struct SettingsStore {
    private let key = "appSettingsV2"
    private let legacyKey = "appSettings"
    private let legacyCompressionKey = "compressionSettings"
    private let tabKey = "settingsTab"
    private let sidebarKey = "isSettingsOpen"
    private let hasSharedPasswordKey = "hasSharedPassword"
    private let overrideKey = "sevenZipExecutableOverride"
    private let defaults = UserDefaults.standard

    func load() -> AppSettings {
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return stored
        }
        return migratedFromEarlierVersions()
    }

    /// Carries over what the pre-sidebar versions saved, so upgrading does not silently
    /// reset someone's configuration.
    private func migratedFromEarlierVersions() -> AppSettings {
        var settings = AppSettings.default
        struct LegacyBundle: Decodable {
            var dropMode: DropMode?
            var compression: CompressionSettings?
            var extraction: ExtractionSettings?
        }
        let legacyCompression: CompressionSettings?
        let legacyExtraction: ExtractionSettings?
        if let data = defaults.data(forKey: legacyKey),
           let bundle = try? JSONDecoder().decode(LegacyBundle.self, from: data) {
            if let mode = bundle.dropMode { settings.general.dropMode = mode }
            legacyCompression = bundle.compression
            legacyExtraction = bundle.extraction
        } else if let data = defaults.data(forKey: legacyCompressionKey) {
            legacyCompression = try? JSONDecoder().decode(CompressionSettings.self, from: data)
            legacyExtraction = nil
        } else {
            return settings
        }

        if let compression = legacyCompression {
            settings.general.format = compression.format
            settings.general.destination = compression.destination
            settings.general.revealInFinder = compression.revealInFinder
            settings.general.notifyOnCompletion = compression.notifyOnCompletion
            settings.general.unreadableFilePolicy = compression.abortOnUnreadableFile ? .abort : .skip
            settings.general.includeSymlinks = compression.storeSymlinksAsLinks
            settings.general.preserveMetadata = !compression.excludeMacMetadata
            settings.general.multithreaded = compression.multithreaded
            settings.general.verifyAfterProcessing = compression.verifyAfterCreate
            let formatSettings = FormatSettings(
                level: compression.level,
                encryptFileNames: compression.encryptFileNames,
                passwordMode: .none,
                splitSizeText: compression.splitSize?.displayText ?? "")
            switch compression.format {
            case .sevenZip: settings.sevenZip = formatSettings
            case .zip: settings.zip = formatSettings
            }
        }
        if let extraction = legacyExtraction {
            settings.general.createContainingFolder = extraction.guaranteeContainingFolder
            settings.general.extractRecursively = extraction.followSingleStreamArchives
            settings.general.extractionSizeLimitText = extraction.maximumTotalBytes == Int64.max
                ? "" : "\(extraction.maximumTotalBytes / (1024 * 1024 * 1024))g"
        }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }

    func loadSettingsTab() -> SettingsTab {
        guard let raw = defaults.string(forKey: tabKey),
              let tab = SettingsTab(rawValue: raw) else { return .general }
        return tab
    }

    func saveSettingsTab(_ tab: SettingsTab) {
        defaults.set(tab.rawValue, forKey: tabKey)
    }

    func loadSettingsOpen() -> Bool { defaults.bool(forKey: sidebarKey) }

    /// Whether a shared password exists — a plain boolean, never the password itself.
    func loadHasSharedPassword() -> Bool { defaults.bool(forKey: hasSharedPasswordKey) }

    func saveHasSharedPassword(_ hasPassword: Bool) {
        defaults.set(hasPassword, forKey: hasSharedPasswordKey)
    }

    func saveSettingsOpen(_ isOpen: Bool) { defaults.set(isOpen, forKey: sidebarKey) }

    func loadExecutableOverride() -> URL? {
        guard let path = defaults.string(forKey: overrideKey) else { return nil }
        return URL(fileURLWithPath: path)
    }

    func saveExecutableOverride(_ url: URL) {
        defaults.set(url.path, forKey: overrideKey)
    }
}
