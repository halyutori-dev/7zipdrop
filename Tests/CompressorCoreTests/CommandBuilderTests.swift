import Foundation
import Testing
@testable import CompressorCore

private let exe = URL(fileURLWithPath: "/opt/7zz")
private let cwd = URL(fileURLWithPath: "/Users/me/Desktop", isDirectory: true)

private func plan(_ names: [String] = ["a.txt"]) -> InputPlan {
    InputPlan(workingDirectory: cwd, relativeNames: names, commonParentName: "Desktop")
}

private func settings(
    format: ArchiveFormat = .sevenZip,
    level: CompressionLevel = .normal,
    split: SplitSize? = nil,
    encryptFileNames: Bool = false,
    storeSymlinksAsLinks: Bool = true,
    abortOnUnreadableFile: Bool = true,
    excludeMacMetadata: Bool = true,
    multithreaded: Bool = true
) -> CompressionSettings {
    var s = CompressionSettings.default
    s.format = format
    s.level = level
    s.splitSize = split
    s.encryptFileNames = encryptFileNames
    s.storeSymlinksAsLinks = storeSymlinksAsLinks
    s.abortOnUnreadableFile = abortOnUnreadableFile
    s.excludeMacMetadata = excludeMacMetadata
    s.multithreaded = multithreaded
    return s
}

@Suite("7zz argument construction")
struct CommandBuilderTests {

    private func build(
        _ s: CompressionSettings = settings(),
        password: Password? = nil,
        archive: String = "/Users/me/Desktop/out.7z",
        inputs: [String] = ["a.txt"]
    ) throws -> SevenZipInvocation {
        try SevenZipCommandBuilder.add(
            executable: exe,
            archive: URL(fileURLWithPath: archive),
            plan: plan(inputs),
            settings: s,
            password: password
        )
    }

    // MARK: shape

    @Test func firstArgumentIsTheAddCommand() throws {
        #expect(try build().arguments.first == "a")
    }

    @Test func workingDirectoryIsTheInputCommonParent() throws {
        // contract #6/#7: cwd + relative names, never absolute inputs
        #expect(try build().workingDirectory == cwd)
    }

    @Test func archiveIsTheFirstNameAfterTheStopSwitch() throws {
        let args = try build(inputs: ["a.txt", "b/c.txt"]).arguments
        let stops = args.filter { $0 == "--" }
        #expect(stops.count == 1, "-- must appear exactly once")
        let i = try #require(args.firstIndex(of: "--"))
        #expect(args[i + 1] == "/Users/me/Desktop/out.7z")
        #expect(Array(args[(i + 2)...]) == ["a.txt", "b/c.txt"])
    }

    @Test func inputNamesAreRelativeNotAbsolute() throws {
        let args = try build(inputs: ["a.txt", "sub/b.txt"]).arguments
        let i = try #require(args.firstIndex(of: "--"))
        for name in args[(i + 2)...] {
            #expect(!name.hasPrefix("/"), "input \(name) must be relative to the working directory")
        }
    }

    // MARK: always-on switches pinned to the verified contract

    @Test func alwaysDisablesWildcardMatching() throws {
        // contract #9: dropped names containing * ? [ must be literal
        #expect(try build().arguments.contains("-spd"))
    }

    @Test func alwaysPinsOutputStreamsForDeterministicParsing() throws {
        let args = try build().arguments
        #expect(args.contains("-bso1"))
        #expect(args.contains("-bse2"))
        #expect(args.contains("-bsp1"))
        #expect(args.contains("-sccUTF-8"))
    }

    @Test func alwaysAvoidsTouchingSourceAccessTimes() throws {
        #expect(try build().arguments.contains("-ssp"))
    }

    // MARK: level & format

    @Test("compression level maps to -mx=N with only zip-legal values (contract #18)",
          arguments: zip(
            [CompressionLevel.store, .fastest, .fast, .normal, .maximum, .ultra],
            ["-mx=0", "-mx=1", "-mx=3", "-mx=5", "-mx=7", "-mx=9"]))
    func levelSwitch(_ level: CompressionLevel, _ expected: String) throws {
        #expect(try build(settings(level: level)).arguments.contains(expected))
        #expect([0, 1, 3, 5, 7, 9].contains(level.rawValue))
    }

    @Test func formatSwitch() throws {
        #expect(try build(settings(format: .sevenZip)).arguments.contains("-t7z"))
        #expect(try build(settings(format: .zip)).arguments.contains("-tzip"))
    }

    // MARK: password — never on the command line (contract #1)

    @Test func withoutPasswordThereIsNoPasswordSwitchAndNoStdin() throws {
        let inv = try build()
        #expect(!inv.arguments.contains { $0.hasPrefix("-p") })
        #expect(inv.stdinPayload == nil)
    }

    @Test func passwordGoesToStdinAndNeverIntoArgv() throws {
        let secret = "Corr3ct!Horse"
        let inv = try build(password: try Password(secret))
        #expect(inv.arguments.contains("-p"), "bare -p makes 7zz prompt, which we answer on stdin")
        #expect(!inv.arguments.contains("-p" + secret))
        for arg in inv.arguments {
            #expect(!arg.contains(secret), "password leaked into argv: \(arg)")
        }
        #expect(inv.stdinPayload == Data((secret + "\n").utf8))
    }

    @Test func stopSwitchComesAfterThePasswordSwitch() throws {
        let args = try build(password: try Password("pw")).arguments
        let p = try #require(args.firstIndex(of: "-p"))
        let stop = try #require(args.firstIndex(of: "--"))
        #expect(p < stop)
    }

    @Test func displayCommandLineRedactsTheSecret() throws {
        let inv = try build(password: try Password("Corr3ct!Horse"))
        #expect(!inv.displayCommandLine.contains("Corr3ct!Horse"))
        #expect(inv.displayCommandLine.contains("-p"))
    }

    // MARK: encryption strength (contract #4/#5)

    @Test func zipWithPasswordForcesAES256InsteadOfZipCrypto() throws {
        let inv = try build(settings(format: .zip), password: try Password("pw"))
        #expect(inv.arguments.contains("-mem=AES256"), "zip defaults to ZipCrypto, which is broken")
    }

    @Test func sevenZipNeverGetsTheZipOnlyEncryptionSwitch() throws {
        let inv = try build(settings(format: .sevenZip, encryptFileNames: true), password: try Password("pw"))
        #expect(!inv.arguments.contains("-mem=AES256"))
    }

    @Test func headerEncryptionOnlyForSevenZipAndOnlyWithAPassword() throws {
        #expect(try build(settings(format: .sevenZip, encryptFileNames: true), password: try Password("pw"))
            .arguments.contains("-mhe=on"))
        // no password → nothing to encrypt headers with
        #expect(!(try build(settings(format: .sevenZip, encryptFileNames: true)).arguments.contains("-mhe=on")))
        // zip cannot encrypt file names at all
        #expect(!(try build(settings(format: .zip, encryptFileNames: true), password: try Password("pw"))
            .arguments.contains("-mhe=on")))
    }

    @Test func noEncryptionSwitchesWhenNoPassword() throws {
        let args = try build(settings(format: .zip, encryptFileNames: true)).arguments
        #expect(!args.contains("-mem=AES256"))
        #expect(!args.contains("-mhe=on"))
    }

    // MARK: split (contract #12)

    @Test func splitSwitchPresentOnlyWhenConfigured() throws {
        let with = try build(settings(split: try SplitSize.parse("100m")))
        #expect(with.arguments.contains("-v100m"))
        let without = try build(settings(split: nil))
        #expect(!without.arguments.contains { $0.hasPrefix("-v") })
    }

    // MARK: fail-closed & safety toggles

    @Test func abortOnUnreadableFileMapsToSse() throws {
        // contract #14: without -sse a locked file is silently dropped with exit 1
        #expect(try build(settings(abortOnUnreadableFile: true)).arguments.contains("-sse"))
        #expect(!(try build(settings(abortOnUnreadableFile: false)).arguments.contains("-sse")))
    }

    @Test func symlinkStorageMapsToSnl() throws {
        // contract #13: default 7zz behaviour dereferences links and can pull in outside files
        #expect(try build(settings(storeSymlinksAsLinks: true)).arguments.contains("-snl"))
        #expect(!(try build(settings(storeSymlinksAsLinks: false)).arguments.contains("-snl")))
    }

    @Test func multithreadSwitchIsExplicitInBothDirections() throws {
        #expect(try build(settings(multithreaded: true)).arguments.contains("-mmt=on"))
        #expect(try build(settings(multithreaded: false)).arguments.contains("-mmt=off"))
    }

    // MARK: exclusions — literal only (contract #10)

    @Test func macMetadataExclusionsUseLiteralNamesOnly() throws {
        let args = try build(settings(excludeMacMetadata: true)).arguments
        let exclusions = args.filter { $0.hasPrefix("-xr!") }
        #expect(!exclusions.isEmpty)
        #expect(exclusions.contains("-xr!.DS_Store"))
        for e in exclusions {
            #expect(!e.contains("*"), "-spd disables wildcard exclusions, so \(e) would silently not match")
            #expect(!e.contains("?"), "-spd disables wildcard exclusions, so \(e) would silently not match")
        }
    }

    @Test func exclusionListIsPinnedToTheVerifiedLiteralSet() throws {
        #expect(SevenZipCommandBuilder.literalExclusions == [".DS_Store", ".localized", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".apdisk"])
    }

    @Test func noExclusionsWhenDisabled() throws {
        #expect(!(try build(settings(excludeMacMetadata: false)).arguments.contains { $0.hasPrefix("-xr!") }))
    }

    // MARK: argv budget (contract #20)

    @Test func rejectsAnArgumentListThatWouldExceedArgMax() {
        let many = (0..<40_000).map { "a-fairly-long-file-name-number-\($0).bin" }
        #expect(throws: (any Error).self) {
            try SevenZipCommandBuilder.add(
                executable: exe, archive: URL(fileURLWithPath: "/tmp/o.7z"),
                plan: plan(many), settings: settings(), password: nil)
        }
    }

    @Test func acceptsALargeButSafeArgumentList() throws {
        let many = (0..<500).map { "file-\($0).bin" }
        let inv = try SevenZipCommandBuilder.add(
            executable: exe, archive: URL(fileURLWithPath: "/tmp/o.7z"),
            plan: plan(many), settings: settings(), password: nil)
        #expect(inv.arguments.count > 500)
    }

    // MARK: the test/verify command

    @Test func testCommandVerifiesAnArchive() throws {
        let inv = SevenZipCommandBuilder.test(
            executable: exe, archive: URL(fileURLWithPath: "/tmp/o.7z.001"), password: nil)
        #expect(inv.arguments.first == "t")
        let i = try #require(inv.arguments.firstIndex(of: "--"))
        #expect(inv.arguments[i + 1] == "/tmp/o.7z.001")
        #expect(!inv.arguments.contains { $0.hasPrefix("-p") })
        #expect(inv.stdinPayload == nil)
    }

    @Test("""
    the t command has no stdin password channel (contract #21), so the secret must go in \
    argv — and callers opt into that explicitly
    """)
    func testCommandCarriesThePasswordInArgvBecauseItHasNoChoice() throws {
        let inv = SevenZipCommandBuilder.test(
            executable: exe, archive: URL(fileURLWithPath: "/tmp/o.7z"), password: try Password("pw12345"))
        #expect(inv.arguments.contains("-ppw12345"))
        #expect(inv.stdinPayload == nil, "7zz t never reads stdin, so sending it there would be a silent no-op")
    }

    @Test("even then, the shown and logged command line masks it")
    func testCommandDisplayLineIsRedacted() throws {
        let inv = SevenZipCommandBuilder.test(
            executable: exe, archive: URL(fileURLWithPath: "/tmp/o.7z"), password: try Password("pw12345"))
        #expect(!inv.displayCommandLine.contains("pw12345"))
        #expect(inv.displayCommandLine.contains("-p********"))
    }
}
