import Foundation

public protocol SevenZipRunning: Sendable {
    /// Runs 7zz to completion and returns its exit code.
    ///
    /// Output chunks (stdout and stderr merged) are handed to `onOutput` as they arrive.
    /// Cancelling the surrounding `Task` sends SIGTERM, which makes 7zz clean up its own
    /// partial archive and exit 255 (contract #15).
    func run(
        _ invocation: SevenZipInvocation,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> Int32
}

/// Single source of truth for one child process.
///
/// A completed run needs **two** independent facts: the output pipe has reached EOF (so
/// no trailing bytes are lost) and the process has exited (so the status is known). They
/// arrive on different threads in either order, so the continuation is resumed only once
/// both are in. Tracking the exit here also means a cancellation can never signal a pid
/// that has already been reaped and possibly recycled.
///
/// `Process.waitUntilExit()` is deliberately not used: it is run-loop based and blocks
/// forever when called from a Dispatch worker thread, which deadlocked an earlier
/// version of this file.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var continuation: CheckedContinuation<Int32, any Error>?
    private var outputDrained = false
    private var exitStatus: Int32?
    private var settled = false

    init(process: Process) { self.process = process }

    func attach(_ continuation: CheckedContinuation<Int32, any Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        settle()
    }

    func outputReachedEndOfFile() {
        lock.lock()
        outputDrained = true
        lock.unlock()
        settle()
    }

    func processExited(_ status: Int32) {
        lock.lock()
        exitStatus = status
        lock.unlock()
        settle()
    }

    func failToLaunch(_ error: any Error) {
        lock.lock()
        guard !settled, let continuation else { lock.unlock(); return }
        settled = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(throwing: error)
    }

    private func settle() {
        lock.lock()
        guard !settled, outputDrained, let status = exitStatus, let continuation else {
            lock.unlock()
            return
        }
        settled = true
        self.continuation = nil
        lock.unlock()
        // Resumed outside the lock so a re-entrant caller cannot deadlock.
        continuation.resume(returning: status)
    }

    func requestTermination() {
        lock.lock()
        defer { lock.unlock() }
        guard exitStatus == nil, process.isRunning else { return }
        process.terminate()
    }

    func forceKillIfStillRunning() {
        lock.lock()
        defer { lock.unlock() }
        guard exitStatus == nil, process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }
}

public struct LiveSevenZipRunner: SevenZipRunning {
    /// How long a SIGTERM'd 7zz gets to tidy up before it is killed outright.
    public static let gracefulShutdownSeconds = 5.0

    private static let ioQueue = DispatchQueue(
        label: "com.local.sevenzip-compressor.io", qos: .userInitiated, attributes: .concurrent)

    public init() {}

    /// Reads with `read(2)` rather than `FileHandle.read(upToCount:)`.
    ///
    /// That Foundation call keeps reading until it has the full requested length or hits
    /// EOF, so asking for 64 KiB of a process that only ever writes a couple of KB means
    /// nothing arrives until the process exits. 7zz emits a progress line every ~200 ms,
    /// and the whole point of reading incrementally is to show them as they happen — so
    /// this returns as soon as any bytes are available.
    private static func stream(from descriptor: Int32, to onOutput: @Sendable (Data) -> Void) {
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count > 0 {
                onOutput(Data(buffer[0..<count]))
            } else if count == 0 {
                return                          // EOF
            } else if errno == EINTR {
                continue                        // interrupted by a signal; retry
            } else {
                return                          // real read error
            }
        }
    }

    public func run(
        _ invocation: SevenZipInvocation,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> Int32 {
        let process = Process()
        process.executableURL = invocation.executableURL
        process.arguments = invocation.arguments
        process.currentDirectoryURL = invocation.workingDirectory
        // A minimal environment: 7zz only needs a UTF-8 locale, and this keeps unrelated
        // variables (and their size, which counts against ARG_MAX) out of the child.
        process.environment = ["LC_ALL": "en_US.UTF-8", "PATH": "/usr/bin:/bin"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let input = Pipe()
        process.standardInput = input

        let state = RunState(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                state.attach(continuation)
                process.terminationHandler = { finished in
                    state.processExited(finished.terminationStatus)
                }

                do {
                    try process.run()
                } catch {
                    state.failToLaunch(error)
                    return
                }

                // A cancellation can land between entering this closure and the spawn
                // completing; without this the child would run to completion regardless.
                if Task.isCancelled { state.requestTermination() }

                // Answer the password prompt, then close stdin so 7zz never waits on us.
                let writer = input.fileHandleForWriting
                // If 7zz exits before reading (a bad switch, an early fatal error), writing
                // to the closed pipe raises SIGPIPE, which `try?` cannot catch and which
                // terminates the whole app. With this flag the write fails with EPIPE
                // instead, and the exit status still reports what went wrong.
                _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                if let payload = invocation.stdinPayload {
                    try? writer.write(contentsOf: payload)
                }
                try? writer.close()

                Self.ioQueue.async {
                    let reader = output.fileHandleForReading
                    Self.stream(from: reader.fileDescriptor, to: onOutput)
                    try? reader.close()
                    state.outputReachedEndOfFile()
                }
            }
        } onCancel: {
            state.requestTermination()
            Self.ioQueue.asyncAfter(deadline: .now() + Self.gracefulShutdownSeconds) {
                state.forceKillIfStillRunning()
            }
        }
    }
}
