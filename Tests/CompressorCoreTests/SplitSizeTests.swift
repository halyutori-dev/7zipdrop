import Foundation
import Testing
@testable import CompressorCore

@Suite("SplitSize parsing")
struct SplitSizeTests {

    // MARK: no-split forms

    @Test("empty / whitespace / zero mean no split", arguments: ["", "   ", "\t", "0", "0m", "0 MB", "00"])
    func noSplit(_ input: String) throws {
        #expect(try SplitSize.parse(input) == nil)
    }

    // MARK: units are 1024-based (contract #12)

    @Test func bareNumberIsBytes() throws {
        let s = try #require(try SplitSize.parse("2048"))
        #expect(s.unit == .bytes)
        #expect(s.byteCount == 2048)
        #expect(s.switchArgument == "-v2048b")
    }

    @Test("k/m/g are binary multiples, matching 7-Zip's -v switch")
    func binaryUnits() throws {
        #expect(try SplitSize.parse("1k")?.byteCount == 1024)
        #expect(try SplitSize.parse("1m")?.byteCount == 1_048_576)
        #expect(try SplitSize.parse("1g")?.byteCount == 1_073_741_824)
        #expect(try SplitSize.parse("100m")?.byteCount == 104_857_600)
    }

    @Test("unit spelling is forgiving but always binary",
          arguments: ["100m", "100M", "100 m", "100mb", "100MB", "100 MB", "100mib", "100MiB"])
    func unitAliases(_ input: String) throws {
        let s = try #require(try SplitSize.parse(input))
        #expect(s.unit == .mebibytes)
        #expect(s.value == 100)
        #expect(s.byteCount == 104_857_600)
    }

    @Test func switchArgumentUsesSevenZipSyntax() throws {
        #expect(try SplitSize.parse("100m")?.switchArgument == "-v100m")
        #expect(try SplitSize.parse("4480MB")?.switchArgument == "-v4480m")
        #expect(try SplitSize.parse("2g")?.switchArgument == "-v2g")
    }

    // MARK: rejections

    @Test("garbage is rejected, never silently coerced",
          arguments: ["abc", "m100", "1.5m", "-5m", "5 5m", "100x", "100 mbb", "1,5m", "١٠m", "0x10"])
    func rejectsMalformed(_ input: String) {
        #expect(throws: (any Error).self) { try SplitSize.parse(input) }
    }

    @Test func rejectsBelowMinimum() {
        #expect(throws: SplitSizeError.tooSmall(minimumBytes: SplitSize.minimumByteCount)) {
            try SplitSize.parse("512")
        }
    }

    @Test func acceptsExactlyMinimum() throws {
        #expect(try SplitSize.parse("1024")?.byteCount == SplitSize.minimumByteCount)
        #expect(try SplitSize.parse("1k")?.byteCount == SplitSize.minimumByteCount)
    }

    @Test func rejectsOverflow() {
        #expect(throws: SplitSizeError.overflow) { try SplitSize.parse("99999999999999999999m") }
        #expect(throws: SplitSizeError.overflow) { try SplitSize.parse("999999999g") }
    }

    // MARK: presets

    @Test func presetsAreAllValidAndBinary() throws {
        #expect(!SplitSize.presets.isEmpty)
        for preset in SplitSize.presets {
            #expect(preset.size.byteCount >= SplitSize.minimumByteCount)
            // every preset must survive a parse round-trip through its own switch text
            let text = "\(preset.size.value)\(preset.size.unit.rawValue)"
            #expect(try SplitSize.parse(text) == preset.size)
        }
    }

    @Test func codableRoundTrip() throws {
        let original = try #require(try SplitSize.parse("700m"))
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(SplitSize.self, from: data) == original)
    }
}

@Suite("Password validation")
struct PasswordTests {
    @Test func acceptsUnicodeAndSymbols() throws {
        // contract #2: verified to round-trip through 7zz stdin
        let p = try Password(#"pa ss"w#o$rd-日本語€"#)
        #expect(p.value == #"pa ss"w#o$rd-日本語€"#)
    }

    @Test("newlines cannot survive the stdin channel, so they are rejected up front",
          arguments: ["a\nb", "a\rb", "trailing\n", "\n"])
    func rejectsNewlines(_ raw: String) {
        #expect(throws: PasswordError.containsNewline) { try Password(raw) }
    }

    @Test func rejectsNUL() {
        #expect(throws: PasswordError.containsNUL) { try Password("a\0b") }
    }

    @Test func rejectsEmpty() {
        #expect(throws: PasswordError.empty) { try Password("") }
    }

    @Test func stdinPayloadIsSingleNewlineTerminatedLine() throws {
        // contract #1: exactly one prompt, one line
        let p = try Password("Secret123")
        #expect(p.stdinPayload == Data("Secret123\n".utf8))
    }

    @Test func descriptionNeverLeaksTheSecret() throws {
        let p = try Password("TopSecret")
        #expect(!"\(p)".contains("TopSecret"))
        #expect(!p.debugDescription.contains("TopSecret"))
    }
}

@Suite("SevenZipExitStatus (contract #17)")
struct ExitStatusTests {
    @Test func mapsDocumentedCodes() {
        #expect(SevenZipExitStatus(code: 0) == .success)
        #expect(SevenZipExitStatus(code: 1) == .warning)
        #expect(SevenZipExitStatus(code: 2) == .fatal)
        #expect(SevenZipExitStatus(code: 7) == .commandLineError)
        #expect(SevenZipExitStatus(code: 8) == .outOfMemory)
        #expect(SevenZipExitStatus(code: 255) == .cancelled)
        #expect(SevenZipExitStatus(code: 42) == .unknown(42))
    }

    @Test("exit 1 is a warning and must NOT count as success (contract #14)")
    func warningIsNotSuccess() {
        #expect(SevenZipExitStatus(code: 0).isSuccess)
        #expect(!SevenZipExitStatus(code: 1).isSuccess)
        #expect(SevenZipExitStatus(code: 1).isUsableArchive)   // archive exists but is incomplete
        #expect(!SevenZipExitStatus(code: 2).isUsableArchive)
        #expect(!SevenZipExitStatus(code: 255).isUsableArchive)
    }

    @Test func everyCaseHasNonEmptyJapaneseDescription() {
        let all: [SevenZipExitStatus] = [.success, .warning, .fatal, .commandLineError, .outOfMemory, .cancelled, .unknown(3)]
        for s in all { #expect(!s.message.isEmpty) }
    }
}
