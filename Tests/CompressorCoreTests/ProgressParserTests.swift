import Foundation
import Testing
@testable import CompressorCore

@Suite("7zz output parsing — driven by real captured bytes (contract #11)")
struct ProgressParserTests {

    /// The actual stdout of `7zz a -t7z -mx=5 -bsp1 -spd -- q.7z big` captured on
    /// macOS 26.5.1 with 7-Zip 26.02. Not hand-written: parsing is pinned to reality.
    private static func goldenBytes() throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: "progress-7z-mx5-pipe", withExtension: "raw", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func percentages(_ events: [SevenZipOutputParser.Event]) -> [Int] {
        events.compactMap { if case .progress(let pct, _) = $0 { return pct } else { return nil } }
    }

    @Test func fixtureIsPresentAndNonTrivial() throws {
        let data = try Self.goldenBytes()
        #expect(data.count > 1000, "golden fixture must not be empty or truncated")
        #expect(data.contains(0x08), "the real output is backspace-delimited, not CR-delimited")
        #expect(!data.contains(0x0D), "7zz 26.02 emits no CR; if this fires the format changed")
    }

    @Test func extractsTheFullAscendingPercentageSequence() throws {
        var parser = SevenZipOutputParser()
        let events = parser.consume(try Self.goldenBytes()) + parser.finish()
        let pcts = percentages(events)
        #expect(pcts.first == 0)
        #expect(pcts.last == 98)
        #expect(pcts.count == 26)
        #expect(pcts == pcts.sorted(), "progress must be monotonic")
        #expect(pcts.allSatisfy { (0...100).contains($0) })
    }

    @Test func reportsTheItemBeingCompressed() throws {
        var parser = SevenZipOutputParser()
        let events = parser.consume(try Self.goldenBytes()) + parser.finish()
        let items = events.compactMap { if case .progress(_, let item) = $0 { return item } else { return nil } }
        #expect(items.contains("big/huge.bin"))
    }

    @Test func detectsSuccessAndArchiveSize() throws {
        var parser = SevenZipOutputParser()
        let events = parser.consume(try Self.goldenBytes()) + parser.finish()
        #expect(events.contains(.finishedOK))
        #expect(events.contains(.archiveSize(125_899_483)))
    }

    @Test("scanning noise like '  0M Scan' never becomes a bogus percentage")
    func scanLinesAreNotProgress() throws {
        var parser = SevenZipOutputParser()
        let events = parser.consume(try Self.goldenBytes()) + parser.finish()
        #expect(events.contains(.scanning))
        #expect(!percentages(events).contains(where: { $0 > 100 }))
    }

    // MARK: incremental correctness — where naive parsers break

    @Test("chunking the stream anywhere yields the same events",
          arguments: [1, 2, 3, 7, 13, 64, 256, 1024])
    func chunkSizeInvariance(_ chunk: Int) throws {
        let data = try Self.goldenBytes()

        var whole = SevenZipOutputParser()
        let expected = whole.consume(data) + whole.finish()

        var incremental = SevenZipOutputParser()
        var got: [SevenZipOutputParser.Event] = []
        var i = data.startIndex
        while i < data.endIndex {
            let j = data.index(i, offsetBy: chunk, limitedBy: data.endIndex) ?? data.endIndex
            got += incremental.consume(data[i..<j])
            i = j
        }
        got += incremental.finish()

        #expect(got == expected, "parser is not chunk-boundary safe at chunk size \(chunk)")
    }

    @Test func splitsOnBackspaceCarriageReturnAndNewlineAlike() {
        var parser = SevenZipOutputParser()
        let raw = Data("  1%\u{08}\u{08}\u{08}\u{08}  2%\r  3%\n  4%".utf8)
        let events = parser.consume(raw) + parser.finish()
        #expect(percentages(events) == [1, 2, 3, 4])
    }

    @Test func ignoresThePaddingSpacesUsedToEraseOldText() {
        var parser = SevenZipOutputParser()
        let raw = Data("  5%\u{08}\u{08}\u{08}\u{08}    \u{08}\u{08}\u{08}\u{08} 12% 1 + f.bin".utf8)
        let events = parser.consume(raw) + parser.finish()
        #expect(percentages(events) == [5, 12])
    }

    @Test("a percent sign inside a file name does not fake a progress event")
    func percentInFileNameIsNotProgress() {
        var parser = SevenZipOutputParser()
        let raw = Data(" 42% 1 + weird%name%.txt\n".utf8)
        let events = parser.consume(raw) + parser.finish()
        #expect(percentages(events) == [42])
        let items = events.compactMap { if case .progress(_, let i) = $0 { return i } else { return nil } }
        #expect(items == ["weird%name%.txt"])
    }

    @Test("multi-byte UTF-8 split across chunk boundaries is not corrupted")
    func utf8AcrossChunkBoundary() {
        var parser = SevenZipOutputParser()
        let raw = Array(Data(" 50% 1 + 日本語のファイル.txt\n".utf8))
        var events: [SevenZipOutputParser.Event] = []
        for byte in raw { events += parser.consume(Data([byte])) }
        events += parser.finish()
        let items = events.compactMap { if case .progress(_, let i) = $0 { return i } else { return nil } }
        #expect(items == ["日本語のファイル.txt"])
    }

    @Test func surfacesErrorLinesAsMessages() {
        var parser = SevenZipOutputParser()
        let raw = Data("ERROR: Cannot open the file as [7z] archive\nERRORS:\n".utf8)
        let events = parser.consume(raw) + parser.finish()
        let messages = events.compactMap { if case .message(let m) = $0 { return m } else { return nil } }
        #expect(messages.contains { $0.contains("Cannot open the file as [7z] archive") })
    }

    @Test func emptyInputProducesNoEvents() {
        var parser = SevenZipOutputParser()
        #expect(parser.consume(Data()).isEmpty)
        #expect(parser.finish().isEmpty)
    }

    @Test("a trailing partial token is only emitted at finish()")
    func trailingTokenFlushedOnFinish() {
        var parser = SevenZipOutputParser()
        #expect(percentages(parser.consume(Data(" 77%".utf8))).isEmpty)
        #expect(percentages(parser.finish()) == [77])
    }
}
