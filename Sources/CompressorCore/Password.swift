import Foundation

/// A password that is safe to hand to 7zz **on stdin**.
///
/// Contract #1/#2 (see docs/VERIFIED-7ZIP-CONTRACT.md): `7zz` prompts once for a
/// password when given a bare `-p`, and reads a single newline-terminated line even
/// when stdin is a pipe. Passing the secret in `argv` instead would expose it to
/// every process that can read this user's process list, so we never do that —
/// which is also why a newline can never be part of a password here.
public struct Password: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let value: String

    public init(_ raw: String) throws {
        if raw.isEmpty { throw PasswordError.empty }
        if raw.contains("\n") || raw.contains("\r") { throw PasswordError.containsNewline }
        if raw.contains("\0") { throw PasswordError.containsNUL }
        self.value = raw
    }

    /// Exactly one line, because 7zz asks exactly once.
    public var stdinPayload: Data { Data((value + "\n").utf8) }

    public var description: String { "Password(<redacted, \(value.count) chars>)" }
    public var debugDescription: String { description }
}
