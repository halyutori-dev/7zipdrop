import Foundation
import Testing
@testable import CompressorCore

@Suite("AppSettings → engine settings mapping")
struct AppSettingsMappingTests {

    @Test("the defaults match what the settings sidebar shows")
    func defaults() {
        let d = AppSettings.default
        #expect(d.general.format == .sevenZip)
        #expect(d.general.dropMode == .auto)
        #expect(d.general.unreadableFilePolicy == .abort)
        #expect(d.general.createContainingFolder)
        #expect(d.general.extractRecursively)
        // the two destructive ones are off
        #expect(!d.general.deleteSourceAfterCompress)
        #expect(!d.general.overwriteOnExtract)
        #expect(d.sevenZip.passwordMode == .none)
        #expect(d.zip.passwordMode == .none)
    }

    @Test("the active format decides which per-format group is used")
    func picksTheActiveFormatGroup() throws {
        var settings = AppSettings.default
        settings.sevenZip.level = .ultra
        settings.zip.level = .fastest

        settings.general.format = .sevenZip
        #expect(try settings.compressionSettings().level == .ultra)
        settings.general.format = .zip
        #expect(try settings.compressionSettings().level == .fastest)
    }

    @Test("zip never asks 7-Zip to encrypt file names, even if the flag is set")
    func zipCannotEncryptNames() throws {
        var settings = AppSettings.default
        settings.general.format = .zip
        settings.zip.encryptFileNames = true
        #expect(try !settings.compressionSettings().encryptFileNames)
    }

    @Test("the compression toggles map through with the right polarity")
    func compressionPolarity() throws {
        var settings = AppSettings.default
        settings.general.unreadableFilePolicy = .skip
        settings.general.includeSymlinks = false
        settings.general.preserveMetadata = false
        settings.general.multithreaded = false
        settings.general.verifyAfterProcessing = false
        settings.general.deleteSourceAfterCompress = true

        let compression = try settings.compressionSettings()
        #expect(!compression.abortOnUnreadableFile)
        #expect(!compression.storeSymlinksAsLinks)
        #expect(compression.excludeMacMetadata, "メタデータ保存 off means the exclusions go on")
        #expect(!compression.multithreaded)
        #expect(!compression.verifyAfterCreate)
        #expect(compression.deleteSourcesAfterSuccess)

        settings.general.unreadableFilePolicy = .abort
        settings.general.preserveMetadata = true
        let strict = try settings.compressionSettings()
        #expect(strict.abortOnUnreadableFile)
        #expect(!strict.excludeMacMetadata)
    }

    @Test("split size comes from the active format's own field")
    func splitSizePerFormat() throws {
        var settings = AppSettings.default
        settings.sevenZip.splitSizeText = "100m"
        settings.zip.splitSizeText = ""
        settings.general.format = .sevenZip
        #expect(try settings.compressionSettings().splitSize?.switchArgument == "-v100m")
        settings.general.format = .zip
        #expect(try settings.compressionSettings().splitSize == nil)
    }

    @Test("an unparseable split size surfaces as an error rather than being ignored")
    func malformedSplitSizeThrows() {
        var settings = AppSettings.default
        settings.sevenZip.splitSizeText = "banana"
        #expect(throws: (any Error).self) { try settings.compressionSettings() }
    }

    @Test("フォルダを作成して展開 maps straight onto the guarantee flag")
    func containingFolderPolarity() throws {
        var settings = AppSettings.default
        settings.general.createContainingFolder = true
        #expect(try settings.extractionSettings().guaranteeContainingFolder)
        settings.general.createContainingFolder = false
        #expect(try !settings.extractionSettings().guaranteeContainingFolder)
    }

    @Test("an empty size limit means no ceiling of our own")
    func emptySizeLimitMeansUnlimited() throws {
        var settings = AppSettings.default
        settings.general.extractionSizeLimitText = ""
        #expect(try settings.extractionSettings().maximumTotalBytes == Int64.max)
        settings.general.extractionSizeLimitText = "10g"
        #expect(try settings.extractionSettings().maximumTotalBytes == 10 * 1024 * 1024 * 1024)
    }

    @Test("a malformed size limit is reported, not silently treated as unlimited")
    func malformedSizeLimitThrows() {
        var settings = AppSettings.default
        settings.general.extractionSizeLimitText = "lots"
        #expect(throws: (any Error).self) { try settings.extractionSettings() }
    }

    @Test("escaping entry paths stay refused — the sidebar has no switch for it")
    func unsafePathsRemainRefused() throws {
        #expect(try !AppSettings.default.extractionSettings().allowUnsafeEntryPaths)
        var settings = AppSettings.default
        settings.general.overwriteOnExtract = true
        #expect(try !settings.extractionSettings().allowUnsafeEntryPaths,
                "overwriting is a separate concern from letting a path escape")
    }

    @Test func codableRoundTripAndForwardCompatibility() throws {
        var settings = AppSettings.default
        settings.general.format = .zip
        settings.general.extractionSizeLimitText = "2g"
        settings.zip.splitSizeText = "700m"
        settings.sevenZip.passwordMode = .shared

        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)

        // a payload written by an older build still loads
        let partial = Data("""
            {"general":{"format":"zip"},"zip":{"level":1}}
            """.utf8)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: partial)
        #expect(decoded.general.format == .zip)
        #expect(decoded.zip.level == .fastest)
        #expect(decoded.general.createContainingFolder == GeneralSettings.default.createContainingFolder)
    }

    @Test func passwordModeSaysWhetherItEncrypts() {
        #expect(!PasswordMode.none.encrypts)
        #expect(PasswordMode.askEachTime.encrypts)
        #expect(PasswordMode.shared.encrypts)
    }
}
