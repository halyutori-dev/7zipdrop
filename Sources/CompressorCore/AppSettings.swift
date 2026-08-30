import Foundation

/// What to do about an input file that cannot be read.
public enum UnreadableFilePolicy: String, Codable, CaseIterable, Sendable, Identifiable {
    /// 7-Zip leaves the file out and finishes with a warning.
    case skip
    /// 7-Zip aborts and leaves no archive behind (`-sse`).
    case abort

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .skip: "スキップ"
        case .abort: "処理中止"
        }
    }
}

/// How a password is obtained for a compression.
public enum PasswordMode: String, Codable, CaseIterable, Sendable, Identifiable {
    /// No encryption.
    case none
    /// Ask in a dialog every time.
    case askEachTime
    /// Always use one saved password.
    case shared

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "しない"
        case .askEachTime: "都度質問"
        case .shared: "毎回共通"
        }
    }

    public var encrypts: Bool { self != .none }
}

/// Settings that only apply to one archive format.
public struct FormatSettings: Codable, Equatable, Sendable {
    public var level: CompressionLevel
    /// 7z only — zip cannot encrypt its file list (contract #5).
    public var encryptFileNames: Bool
    public var passwordMode: PasswordMode
    /// Raw text so an in-progress edit survives; empty means "do not split".
    public var splitSizeText: String

    public static let defaultSevenZip = FormatSettings(
        level: .normal, encryptFileNames: true, passwordMode: .none, splitSizeText: "")
    public static let defaultZip = FormatSettings(
        level: .normal, encryptFileNames: false, passwordMode: .none, splitSizeText: "")

    /// Throws when the text is present but unparseable, so the UI can say why.
    public func splitSize() throws -> SplitSize? {
        try SplitSize.parse(splitSizeText)
    }

    public init(level: CompressionLevel, encryptFileNames: Bool,
                passwordMode: PasswordMode, splitSizeText: String) {
        self.level = level
        self.encryptFileNames = encryptFileNames
        self.passwordMode = passwordMode
        self.splitSizeText = splitSizeText
    }

    private enum CodingKeys: String, CodingKey { case level, encryptFileNames, passwordMode, splitSizeText }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FormatSettings.defaultSevenZip
        level = try c.decodeIfPresent(CompressionLevel.self, forKey: .level) ?? d.level
        encryptFileNames = try c.decodeIfPresent(Bool.self, forKey: .encryptFileNames) ?? d.encryptFileNames
        passwordMode = try c.decodeIfPresent(PasswordMode.self, forKey: .passwordMode) ?? d.passwordMode
        splitSizeText = try c.decodeIfPresent(String.self, forKey: .splitSizeText) ?? d.splitSizeText
    }
}

/// Settings shared by every format.
public struct GeneralSettings: Codable, Equatable, Sendable {
    // 全般設定
    public var format: ArchiveFormat
    public var destination: DestinationMode
    public var dropMode: DropMode
    public var revealInFinder: Bool
    public var notifyOnCompletion: Bool

    // 圧縮設定
    public var unreadableFilePolicy: UnreadableFilePolicy
    /// On: store symlinks as links. Off: follow them and store what they point at.
    public var includeSymlinks: Bool
    /// On: keep `.DS_Store` and friends. Off: leave them out.
    public var preserveMetadata: Bool
    public var multithreaded: Bool
    public var verifyAfterProcessing: Bool
    /// Moves the dropped originals to the Trash after a fully successful compression.
    public var deleteSourceAfterCompress: Bool

    // 展開設定
    /// Empty means no ceiling; the free-space check still applies.
    public var extractionSizeLimitText: String
    public var overwriteOnExtract: Bool
    /// On: always put the result in a folder. Off: a single root item is delivered as-is.
    public var createContainingFolder: Bool
    public var extractRecursively: Bool

    public static let `default` = GeneralSettings(
        format: .sevenZip,
        destination: .sameAsSource,
        dropMode: .auto,
        revealInFinder: true,
        notifyOnCompletion: true,
        unreadableFilePolicy: .abort,
        includeSymlinks: true,
        preserveMetadata: true,
        multithreaded: true,
        verifyAfterProcessing: true,
        deleteSourceAfterCompress: false,
        extractionSizeLimitText: "",
        overwriteOnExtract: false,
        createContainingFolder: true,
        extractRecursively: true
    )

    public func extractionSizeLimit() throws -> SplitSize? {
        try SplitSize.parse(extractionSizeLimitText)
    }

    private enum CodingKeys: String, CodingKey {
        case format, destination, dropMode, revealInFinder, notifyOnCompletion
        case unreadableFilePolicy, includeSymlinks, preserveMetadata, multithreaded
        case verifyAfterProcessing, deleteSourceAfterCompress
        case extractionSizeLimitText, overwriteOnExtract, createContainingFolder, extractRecursively
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralSettings.default
        format = try c.decodeIfPresent(ArchiveFormat.self, forKey: .format) ?? d.format
        destination = try c.decodeIfPresent(DestinationMode.self, forKey: .destination) ?? d.destination
        dropMode = try c.decodeIfPresent(DropMode.self, forKey: .dropMode) ?? d.dropMode
        revealInFinder = try c.decodeIfPresent(Bool.self, forKey: .revealInFinder) ?? d.revealInFinder
        notifyOnCompletion = try c.decodeIfPresent(Bool.self, forKey: .notifyOnCompletion) ?? d.notifyOnCompletion
        unreadableFilePolicy = try c.decodeIfPresent(UnreadableFilePolicy.self, forKey: .unreadableFilePolicy) ?? d.unreadableFilePolicy
        includeSymlinks = try c.decodeIfPresent(Bool.self, forKey: .includeSymlinks) ?? d.includeSymlinks
        preserveMetadata = try c.decodeIfPresent(Bool.self, forKey: .preserveMetadata) ?? d.preserveMetadata
        multithreaded = try c.decodeIfPresent(Bool.self, forKey: .multithreaded) ?? d.multithreaded
        verifyAfterProcessing = try c.decodeIfPresent(Bool.self, forKey: .verifyAfterProcessing) ?? d.verifyAfterProcessing
        deleteSourceAfterCompress = try c.decodeIfPresent(Bool.self, forKey: .deleteSourceAfterCompress) ?? d.deleteSourceAfterCompress
        extractionSizeLimitText = try c.decodeIfPresent(String.self, forKey: .extractionSizeLimitText) ?? d.extractionSizeLimitText
        overwriteOnExtract = try c.decodeIfPresent(Bool.self, forKey: .overwriteOnExtract) ?? d.overwriteOnExtract
        createContainingFolder = try c.decodeIfPresent(Bool.self, forKey: .createContainingFolder) ?? d.createContainingFolder
        extractRecursively = try c.decodeIfPresent(Bool.self, forKey: .extractRecursively) ?? d.extractRecursively
    }

    public init(
        format: ArchiveFormat, destination: DestinationMode, dropMode: DropMode,
        revealInFinder: Bool, notifyOnCompletion: Bool,
        unreadableFilePolicy: UnreadableFilePolicy, includeSymlinks: Bool,
        preserveMetadata: Bool, multithreaded: Bool, verifyAfterProcessing: Bool,
        deleteSourceAfterCompress: Bool, extractionSizeLimitText: String,
        overwriteOnExtract: Bool, createContainingFolder: Bool, extractRecursively: Bool
    ) {
        self.format = format
        self.destination = destination
        self.dropMode = dropMode
        self.revealInFinder = revealInFinder
        self.notifyOnCompletion = notifyOnCompletion
        self.unreadableFilePolicy = unreadableFilePolicy
        self.includeSymlinks = includeSymlinks
        self.preserveMetadata = preserveMetadata
        self.multithreaded = multithreaded
        self.verifyAfterProcessing = verifyAfterProcessing
        self.deleteSourceAfterCompress = deleteSourceAfterCompress
        self.extractionSizeLimitText = extractionSizeLimitText
        self.overwriteOnExtract = overwriteOnExtract
        self.createContainingFolder = createContainingFolder
        self.extractRecursively = extractRecursively
    }
}

/// Everything the settings sidebar edits: one shared group plus one group per format.
///
/// This is the type the UI binds to. The engines keep their own narrower
/// `CompressionSettings` / `ExtractionSettings`, and this maps onto them — so a UI change
/// cannot quietly alter what the engines were tested against.
public struct AppSettings: Codable, Equatable, Sendable {
    public var general: GeneralSettings
    public var sevenZip: FormatSettings
    public var zip: FormatSettings

    public static let `default` = AppSettings(
        general: .default, sevenZip: .defaultSevenZip, zip: .defaultZip)

    public init(general: GeneralSettings, sevenZip: FormatSettings, zip: FormatSettings) {
        self.general = general
        self.sevenZip = sevenZip
        self.zip = zip
    }

    public func formatSettings(for format: ArchiveFormat) -> FormatSettings {
        switch format {
        case .sevenZip: sevenZip
        case .zip: zip
        }
    }

    public var activeFormatSettings: FormatSettings { formatSettings(for: general.format) }

    /// The password mode that applies to the format currently selected for compression.
    public var activePasswordMode: PasswordMode { activeFormatSettings.passwordMode }

    private enum CodingKeys: String, CodingKey { case general, sevenZip, zip }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        general = try c.decodeIfPresent(GeneralSettings.self, forKey: .general) ?? .default
        sevenZip = try c.decodeIfPresent(FormatSettings.self, forKey: .sevenZip) ?? .defaultSevenZip
        zip = try c.decodeIfPresent(FormatSettings.self, forKey: .zip) ?? .defaultZip
    }

    // MARK: mapping onto the engine settings

    public func compressionSettings() throws -> CompressionSettings {
        let format = general.format
        let formatSettings = formatSettings(for: format)
        var settings = CompressionSettings.default
        settings.format = format
        settings.level = formatSettings.level
        settings.splitSize = try formatSettings.splitSize()
        settings.destination = general.destination
        settings.encryptFileNames = format.supportsHeaderEncryption && formatSettings.encryptFileNames
        settings.storeSymlinksAsLinks = general.includeSymlinks
        settings.abortOnUnreadableFile = general.unreadableFilePolicy == .abort
        settings.excludeMacMetadata = !general.preserveMetadata
        settings.multithreaded = general.multithreaded
        settings.verifyAfterCreate = general.verifyAfterProcessing
        settings.revealInFinder = general.revealInFinder
        settings.notifyOnCompletion = general.notifyOnCompletion
        settings.deleteSourcesAfterSuccess = general.deleteSourceAfterCompress
        return settings
    }

    public func extractionSettings() throws -> ExtractionSettings {
        var settings = ExtractionSettings.default
        settings.destination = general.destination
        settings.guaranteeContainingFolder = general.createContainingFolder
        settings.followSingleStreamArchives = general.extractRecursively
        settings.overwriteExisting = general.overwriteOnExtract
        settings.revealInFinder = general.revealInFinder
        settings.notifyOnCompletion = general.notifyOnCompletion
        // Empty means no ceiling of our own; the free-space check still stops a bomb.
        settings.maximumTotalBytes = try general.extractionSizeLimit()?.byteCount ?? Int64.max
        return settings
    }
}
