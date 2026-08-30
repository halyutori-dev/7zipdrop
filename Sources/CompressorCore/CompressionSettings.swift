import Foundation

public enum DestinationMode: Equatable, Sendable {
    /// Save next to the dropped items.
    case sameAsSource
    /// Always save into one fixed folder.
    case fixedDirectory(URL)

    public var fixedURL: URL? {
        if case .fixedDirectory(let url) = self { return url }
        return nil
    }
}

extension DestinationMode: Codable {
    private enum CodingKeys: String, CodingKey { case kind, path }
    private enum Kind: String, Codable { case sameAsSource, fixedDirectory }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .sameAsSource:
            self = .sameAsSource
        case .fixedDirectory:
            let path = try c.decode(String.self, forKey: .path)
            // A persisted folder that no longer exists must not silently become the
            // source folder: keep it and let the engine report it as unwritable.
            self = .fixedDirectory(URL(fileURLWithPath: path, isDirectory: true))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .sameAsSource:
            try c.encode(Kind.sameAsSource, forKey: .kind)
        case .fixedDirectory(let url):
            try c.encode(Kind.fixedDirectory, forKey: .kind)
            try c.encode(url.path, forKey: .path)
        }
    }
}

/// The "conditions decided in advance" that every drop is compressed with.
public struct CompressionSettings: Equatable, Sendable {
    public var format: ArchiveFormat
    public var level: CompressionLevel
    public var splitSize: SplitSize?
    public var destination: DestinationMode

    /// 7z only: also encrypt the file list (contract #5).
    public var encryptFileNames: Bool
    /// Store symlinks as links instead of following them (contract #13).
    public var storeSymlinksAsLinks: Bool
    /// Abort instead of producing an archive that silently omits unreadable files (contract #14).
    public var abortOnUnreadableFile: Bool
    /// Skip `.DS_Store` and friends — literal names only (contract #10).
    public var excludeMacMetadata: Bool
    public var multithreaded: Bool
    /// Run `7zz t` on the result before moving it into place.
    public var verifyAfterCreate: Bool
    /// 7zz's `t` command cannot read a password from stdin (contract #21), so verifying an
    /// encrypted archive means putting the password in `argv`, where other processes of
    /// this user can see it. Off by default: an unverified archive is reported as
    /// unverified rather than silently leaking the secret.
    public var verifyEncryptedArchives: Bool
    public var revealInFinder: Bool
    public var notifyOnCompletion: Bool
    /// Off by default: storing a secret is an explicit choice, never a silent one.
    public var rememberPasswordInKeychain: Bool
    /// Move the dropped originals to the Trash once the archive is safely in place.
    /// Only ever acts on a fully successful run — a warning means files were left out.
    public var deleteSourcesAfterSuccess: Bool

    public static let `default` = CompressionSettings(
        format: .sevenZip,
        level: .normal,
        splitSize: nil,
        destination: .sameAsSource,
        encryptFileNames: true,
        storeSymlinksAsLinks: true,
        abortOnUnreadableFile: true,
        excludeMacMetadata: true,
        multithreaded: true,
        verifyAfterCreate: true,
        verifyEncryptedArchives: false,
        revealInFinder: true,
        notifyOnCompletion: true,
        rememberPasswordInKeychain: false,
        deleteSourcesAfterSuccess: false
    )
}

extension CompressionSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case format, level, splitSize, destination, encryptFileNames, storeSymlinksAsLinks
        case abortOnUnreadableFile, excludeMacMetadata, multithreaded, verifyAfterCreate
        case verifyEncryptedArchives, revealInFinder, notifyOnCompletion, rememberPasswordInKeychain
        case deleteSourcesAfterSuccess
    }

    /// Every key falls back to the default so an older or partially-written settings
    /// file loads instead of throwing the user's whole configuration away.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CompressionSettings.default
        format = try c.decodeIfPresent(ArchiveFormat.self, forKey: .format) ?? d.format
        level = try c.decodeIfPresent(CompressionLevel.self, forKey: .level) ?? d.level
        splitSize = try c.decodeIfPresent(SplitSize.self, forKey: .splitSize)
        destination = try c.decodeIfPresent(DestinationMode.self, forKey: .destination) ?? d.destination
        encryptFileNames = try c.decodeIfPresent(Bool.self, forKey: .encryptFileNames) ?? d.encryptFileNames
        storeSymlinksAsLinks = try c.decodeIfPresent(Bool.self, forKey: .storeSymlinksAsLinks) ?? d.storeSymlinksAsLinks
        abortOnUnreadableFile = try c.decodeIfPresent(Bool.self, forKey: .abortOnUnreadableFile) ?? d.abortOnUnreadableFile
        excludeMacMetadata = try c.decodeIfPresent(Bool.self, forKey: .excludeMacMetadata) ?? d.excludeMacMetadata
        multithreaded = try c.decodeIfPresent(Bool.self, forKey: .multithreaded) ?? d.multithreaded
        verifyAfterCreate = try c.decodeIfPresent(Bool.self, forKey: .verifyAfterCreate) ?? d.verifyAfterCreate
        verifyEncryptedArchives = try c.decodeIfPresent(Bool.self, forKey: .verifyEncryptedArchives) ?? d.verifyEncryptedArchives
        revealInFinder = try c.decodeIfPresent(Bool.self, forKey: .revealInFinder) ?? d.revealInFinder
        notifyOnCompletion = try c.decodeIfPresent(Bool.self, forKey: .notifyOnCompletion) ?? d.notifyOnCompletion
        rememberPasswordInKeychain = try c.decodeIfPresent(Bool.self, forKey: .rememberPasswordInKeychain) ?? d.rememberPasswordInKeychain
        deleteSourcesAfterSuccess = try c.decodeIfPresent(Bool.self, forKey: .deleteSourcesAfterSuccess) ?? d.deleteSourcesAfterSuccess
    }
}
