import Foundation
import Testing
@testable import CompressorCore

enum TestSupport {
    /// The vendored 7zz, located relative to this source file so the tests do not
    /// depend on anything being installed on the machine.
    static var sevenZipURL: URL {
        packageRoot.appendingPathComponent("vendor/ex/7zz")
    }

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)          // Tests/CompressorCoreTests/TestSupport.swift
            .deletingLastPathComponent()        // Tests/CompressorCoreTests
            .deletingLastPathComponent()        // Tests
            .deletingLastPathComponent()        // <package root>
    }

    static func makeTemporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("7zc-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// Lists archive entry paths using 7zz's own technical listing, which is robust for
    /// names containing spaces (column-splitting `l -ba` is not).
    static func listEntries(_ archive: URL, password: String? = nil) throws -> [String] {
        var arguments = ["l", "-slt", "-spd", "-sccUTF-8"]
        if let password { arguments.append("-p" + password) }
        arguments += ["--", archive.path]
        let (output, code) = try runSevenZip(arguments)
        guard code == 0 else { return [] }
        // Everything before the "----------" separator describes the archive itself.
        guard let separator = output.range(of: "----------") else { return [] }
        return output[separator.upperBound...]
            .split(separator: "\n")
            .compactMap { line in
                line.hasPrefix("Path = ") ? String(line.dropFirst("Path = ".count)) : nil
            }
            .sorted()
    }

    static func technicalListing(_ archive: URL, password: String? = nil) throws -> String {
        var arguments = ["l", "-slt", "-spd", "-sccUTF-8"]
        if let password { arguments.append("-p" + password) }
        arguments += ["--", archive.path]
        return try runSevenZip(arguments).output
    }

    static func testArchive(_ archive: URL, password: String? = nil) throws -> Int32 {
        var arguments = ["t", "-spd", "-sccUTF-8"]
        if let password { arguments.append("-p" + password) }
        arguments += ["--", archive.path]
        return try runSevenZip(arguments).code
    }

    /// Direct 7zz call used only by the test oracle, so assertions do not go through
    /// the same code path they are checking.
    static func runSevenZip(_ arguments: [String]) throws -> (output: String, code: Int32) {
        let process = Process()
        process.executableURL = sevenZipURL
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
    }

    static func entryNames(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}

/// A runner that fabricates 7zz's side effects, so delivery, verification and failure
/// handling can be tested without depending on real compression timing.
final class FakeRunner: SevenZipRunning, @unchecked Sendable {
    struct Script: Sendable {
        var addExitCode: Int32 = 0
        var testExitCode: Int32 = 0
        /// Suffixes to create next to the staged archive: `[""]` for a single archive,
        /// `[".001", ".002"]` for volumes, `[]` to produce nothing at all.
        var producedSuffixes: [String] = [""]
        var stdoutText: String = "Everything is Ok\n"
    }

    private let script: Script
    private let lock = NSLock()
    private var _invocations: [SevenZipInvocation] = []
    var invocations: [SevenZipInvocation] { lock.withLock { _invocations } }

    init(script: Script = Script()) { self.script = script }

    func run(_ invocation: SevenZipInvocation, onOutput: @escaping @Sendable (Data) -> Void) async throws -> Int32 {
        lock.withLock { _invocations.append(invocation) }

        let isTest = invocation.arguments.first == "t"
        onOutput(Data(script.stdoutText.utf8))
        guard !isTest else { return script.testExitCode }

        guard let stopIndex = invocation.arguments.firstIndex(of: "--") else { return 7 }
        let archivePath = invocation.arguments[stopIndex + 1]
        for suffix in script.producedSuffixes {
            let url = URL(fileURLWithPath: archivePath + suffix)
            try? Data("staged-\(suffix)".utf8).write(to: url)
        }
        return script.addExitCode
    }
}

/// Records what the engine asked to be removed, without touching the real Trash.
final class FakeRemover: SourceRemoving, @unchecked Sendable {
    private let lock = NSLock()
    private var _removed: [URL] = []
    private let failOn: (URL) -> Bool

    init(failOn: @escaping (URL) -> Bool = { _ in false }) { self.failOn = failOn }

    var removed: [URL] { lock.withLock { _removed } }

    func remove(_ url: URL) throws -> URL? {
        if failOn(url) { throw CocoaError(.fileNoSuchFile) }
        lock.withLock { _removed.append(url) }
        // simulate the move so callers that check the filesystem see it gone
        try? FileManager.default.removeItem(at: url)
        return URL(fileURLWithPath: "/fake-trash/" + url.lastPathComponent)
    }
}

extension TestSupport {
    /// Runs the system `unzip -t`, as an oracle independent of 7-Zip.
    static func systemUnzipTest(_ url: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tq", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
