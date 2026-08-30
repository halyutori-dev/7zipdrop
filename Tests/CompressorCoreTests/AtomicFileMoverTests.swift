import Foundation
import Testing
@testable import CompressorCore

/// The final delivery step. Both methods must refuse an occupied destination rather than
/// replacing it — that refusal is the whole reason they exist instead of `FileManager`'s
/// check-then-move, which has a window in between.
@Suite("AtomicFileMover")
struct AtomicFileMoverTests {

    private let mover = AtomicFileMover()

    private func sandbox() throws -> URL { try TestSupport.makeTemporaryDirectory() }

    private func makeFile(_ url: URL, _ contents: String = "payload") throws {
        try TestSupport.write(contents, to: url)
    }

    private func makeDirectory(_ url: URL, withChild child: String? = nil) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let child { try makeFile(url.appendingPathComponent(child)) }
    }

    // MARK: files

    @Test func movesAFileToAFreeName() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("src.bin")
        let target = root.appendingPathComponent("dst.bin")
        try makeFile(source, "hello")

        try mover.claim(from: source, to: target)

        #expect(try String(decoding: Data(contentsOf: target), as: UTF8.self) == "hello")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("an occupied file name is refused and the existing file is untouched")
    func refusesAnOccupiedFileName() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("src.bin")
        let target = root.appendingPathComponent("dst.bin")
        try makeFile(source, "new")
        try makeFile(target, "ORIGINAL")

        #expect(throws: CompressorError.destinationExists(target.path)) {
            try self.mover.claim(from: source, to: target)
        }
        #expect(try String(decoding: Data(contentsOf: target), as: UTF8.self) == "ORIGINAL")
        #expect(FileManager.default.fileExists(atPath: source.path), "the source is left for cleanup")
    }

    // MARK: directories

    @Test func movesADirectoryToAFreeName() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("src", isDirectory: true)
        let target = root.appendingPathComponent("dst", isDirectory: true)
        try makeDirectory(source, withChild: "inner.txt")

        try mover.claimDirectory(from: source, to: target)

        #expect(FileManager.default.fileExists(atPath: target.appendingPathComponent("inner.txt").path))
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test("""
    an existing EMPTY directory is refused — plain rename(2) would silently replace it, \
    which is exactly what RENAME_EXCL prevents
    """)
    func refusesAnExistingEmptyDirectory() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("src", isDirectory: true)
        let target = root.appendingPathComponent("dst", isDirectory: true)
        try makeDirectory(source, withChild: "inner.txt")
        try makeDirectory(target)

        #expect(throws: CompressorError.destinationExists(target.path)) {
            try self.mover.claimDirectory(from: source, to: target)
        }
        #expect(TestSupport.entryNames(in: target).isEmpty, "the existing directory is left as it was")
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("inner.txt").path))
    }

    @Test func refusesAnExistingNonEmptyDirectory() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("src", isDirectory: true)
        let target = root.appendingPathComponent("dst", isDirectory: true)
        try makeDirectory(source, withChild: "new.txt")
        try makeDirectory(target, withChild: "ORIGINAL.txt")

        #expect(throws: (any Error).self) {
            try self.mover.claimDirectory(from: source, to: target)
        }
        #expect(TestSupport.entryNames(in: target) == ["ORIGINAL.txt"])
    }

    @Test func refusesADirectoryNameTakenByAFile() throws {
        let root = try sandbox()
        let source = root.appendingPathComponent("src", isDirectory: true)
        let target = root.appendingPathComponent("dst")
        try makeDirectory(source, withChild: "inner.txt")
        try makeFile(target, "I AM A FILE")

        #expect(throws: (any Error).self) {
            try self.mover.claimDirectory(from: source, to: target)
        }
        #expect(try String(decoding: Data(contentsOf: target), as: UTF8.self) == "I AM A FILE")
    }

    @Test("""
    delivery works into a protected user folder — macOS refuses `link(2)` there, and every \
    other test in this suite runs in /tmp where it is allowed
    """)
    func claimsIntoAProtectedUserFolder() throws {
        // Downloads is the folder the bug was actually hit in. Everything created here is
        // uniquely named and removed again.
        let downloads = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: downloads.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            Issue.record("~/Downloads is missing, so the protected-folder path went unchecked")
            return
        }
        let staging = downloads.appendingPathComponent(".7zdrop-movertest-\(UUID().uuidString)",
                                                       isDirectory: true)
        guard (try? FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false)) != nil else {
            Issue.record("cannot stage inside ~/Downloads, so the protected-folder path went unchecked")
            return
        }
        defer { try? FileManager.default.removeItem(at: staging) }

        let source = staging.appendingPathComponent("payload.bin")
        try TestSupport.write("delivered", to: source)
        let target = downloads.appendingPathComponent("7zdrop-movertest-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: target) }

        try mover.claim(from: source, to: target)

        #expect(FileManager.default.fileExists(atPath: target.path))
        #expect(try String(decoding: Data(contentsOf: target), as: UTF8.self) == "delivered")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func reportsAMissingSourceRatherThanSucceeding() throws {
        let root = try sandbox()
        #expect(throws: (any Error).self) {
            try self.mover.claimDirectory(from: root.appendingPathComponent("nope"),
                                          to: root.appendingPathComponent("dst"))
        }
        #expect(throws: (any Error).self) {
            try self.mover.claim(from: root.appendingPathComponent("nope.bin"),
                                 to: root.appendingPathComponent("dst.bin"))
        }
    }
}
