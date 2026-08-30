import Foundation

public struct SevenZipInvocation: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let workingDirectory: URL
    /// Written to the child's stdin, then closed. Carries the password so it never
    /// appears in `argv` (contract #1).
    public let stdinPayload: Data?

    public init(executableURL: URL, arguments: [String], workingDirectory: URL, stdinPayload: Data?) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.stdinPayload = stdinPayload
    }

    /// Human-readable preview. Safe to show and log: the secret is not in `arguments`.
    public var displayCommandLine: String {
        let parts = ([executableURL.path] + arguments.map(Self.redact)).map(Self.quote)
        let command = parts.joined(separator: " ")
        guard stdinPayload != nil else { return command }
        return "# パスワードは stdin 経由で渡します（argv には含まれません）\n" + command
    }

    /// `-p<secret>` is the one argument that can carry a password (the `t` command has no
    /// other channel), so it is masked before the command line is ever shown or logged.
    static func redact(_ argument: String) -> String {
        argument.hasPrefix("-p") && argument.count > 2 ? "-p********" : argument
    }

    private static func quote(_ argument: String) -> String {
        let safe = argument.allSatisfy { $0.isLetter || $0.isNumber || "-_=./+!:@%".contains($0) }
        if safe && !argument.isEmpty { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

public enum SevenZipCommandBuilder {
    /// ARG_MAX is 1 MiB on macOS (contract #20) and the environment shares that budget,
    /// so we stop well short and say so rather than letting exec fail obscurely.
    public static let maximumArgumentBytes = 200_000

    /// Literal names only: `-spd` disables wildcard matching in `-x` patterns too, so a
    /// pattern like `._*` would silently match nothing (contract #10).
    public static let literalExclusions = [
        ".DS_Store", ".localized", ".Spotlight-V100", ".Trashes", ".fseventsd",
        ".TemporaryItems", ".apdisk",
    ]

    public static func add(
        executable: URL,
        archive: URL,
        plan: InputPlan,
        settings: CompressionSettings,
        password: Password?
    ) throws -> SevenZipInvocation {
        var arguments = ["a", settings.format.typeSwitch, settings.level.methodSwitch]

        if password != nil {
            if settings.format.supportsHeaderEncryption && settings.encryptFileNames {
                arguments.append("-mhe=on")
            }
            if settings.format.needsExplicitAESSwitch {
                arguments.append("-mem=AES256")
            }
        }

        arguments.append(settings.multithreaded ? "-mmt=on" : "-mmt=off")
        if let split = settings.splitSize { arguments.append(split.switchArgument) }

        // Always on, for reasons recorded in the contract document.
        arguments += ["-spd", "-ssp", "-sccUTF-8", "-bso1", "-bse2", "-bsp1"]
        if settings.abortOnUnreadableFile { arguments.append("-sse") }
        if settings.storeSymlinksAsLinks { arguments.append("-snl") }
        if settings.excludeMacMetadata {
            arguments += literalExclusions.map { "-xr!\($0)" }
        }
        if password != nil { arguments.append("-p") }

        arguments.append("--")
        arguments.append(archive.path)
        arguments += plan.relativeNames

        try checkArgumentBudget(executable: executable, arguments: arguments)

        return SevenZipInvocation(
            executableURL: executable,
            arguments: arguments,
            workingDirectory: plan.workingDirectory,
            stdinPayload: password?.stdinPayload
        )
    }

    /// Contract #21: unlike `a`, the `t` command never prompts for a password and never
    /// reads one from stdin (verified with a pipe and with a pty). The only channel is
    /// `-p<password>` in `argv`, so callers must decide explicitly whether that exposure
    /// is acceptable — see `CompressionSettings.verifyEncryptedArchives`.
    public static func test(executable: URL, archive: URL, password: Password?) -> SevenZipInvocation {
        var arguments = ["t", "-spd", "-sccUTF-8", "-bso1", "-bse2", "-bsp1"]
        if let password { arguments.append("-p" + password.value) }
        arguments += ["--", archive.path]
        return SevenZipInvocation(
            executableURL: executable,
            arguments: arguments,
            workingDirectory: archive.deletingLastPathComponent(),
            stdinPayload: nil
        )
    }

    /// `l -slt`: the machine-readable listing used for the safety gate (contracts #28-#30).
    public static func list(executable: URL, archive: URL, password: Password?) -> SevenZipInvocation {
        var arguments = ["l", "-slt", "-spd", "-sccUTF-8", "-bso1", "-bse2", "-bsp1"]
        if let password { arguments.append("-p" + password.value) }
        arguments += ["--", archive.path]
        return SevenZipInvocation(
            executableURL: executable, arguments: arguments,
            workingDirectory: archive.deletingLastPathComponent(), stdinPayload: nil)
    }

    /// `x`: extract with full paths into `destination`.
    ///
    /// `-aos` keeps 7zz from ever asking about an existing file — without it a collision
    /// opens an interactive prompt and, with a non-tty stdin, aborts with exit 255
    /// (contract #25). The password has to travel in `argv` because extraction, like
    /// verification, does not read stdin (contract #24).
    public static func extract(
        executable: URL, archive: URL, into destination: URL, password: Password?,
        overwriteExisting: Bool = false
    ) -> SevenZipInvocation {
        // Either way 7zz is answered up front and can never open an overwrite prompt,
        // which with a non-tty stdin would abort the run (contract #25).
        var arguments = ["x", overwriteExisting ? "-aoa" : "-aos",
                         "-spd", "-sccUTF-8", "-bso1", "-bse2", "-bsp1"]
        arguments.append("-o" + destination.path)
        if let password { arguments.append("-p" + password.value) }
        arguments += ["--", archive.path]
        return SevenZipInvocation(
            executableURL: executable, arguments: arguments,
            workingDirectory: archive.deletingLastPathComponent(), stdinPayload: nil)
    }

    private static func checkArgumentBudget(executable: URL, arguments: [String]) throws {
        var bytes = executable.path.utf8.count + 1
        for argument in arguments { bytes += argument.utf8.count + 1 }
        guard bytes <= maximumArgumentBytes else {
            throw CommandBuilderError.argumentListTooLarge(bytes: bytes, limit: maximumArgumentBytes)
        }
    }
}
