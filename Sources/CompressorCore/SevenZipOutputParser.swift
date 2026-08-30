import Foundation

/// Incremental parser for 7zz's stdout.
///
/// Contract #11: progress is redrawn with **backspace (0x08)** runs, not carriage
/// returns, and it does appear even when stdout is a pipe. Tokens are separated by
/// any of `\u{08}`, `\r`, `\n`; the erase padding shows up as whitespace-only tokens.
///
/// Bytes are buffered raw and only decoded at a delimiter, so a multi-byte UTF-8
/// sequence split across two reads is never corrupted.
public struct SevenZipOutputParser: Sendable {
    public enum Event: Equatable, Sendable {
        case progress(percent: Int, currentItem: String?)
        case scanning
        case archiveSize(Int64)
        case finishedOK
        case message(String)
    }

    private var buffer: [UInt8] = []
    private static let delimiters: Set<UInt8> = [0x08, 0x0D, 0x0A]

    public init() {}

    public mutating func consume(_ data: some DataProtocol) -> [Event] {
        var events: [Event] = []
        for byte in data {
            if Self.delimiters.contains(byte) {
                if let event = flushBuffer() { events.append(event) }
            } else {
                buffer.append(byte)
            }
        }
        return events
    }

    /// Emits whatever is still buffered. 7zz's last progress token has no trailing
    /// delimiter, so without this the final update would be lost.
    public mutating func finish() -> [Event] {
        if let event = flushBuffer() { return [event] }
        return []
    }

    private mutating func flushBuffer() -> Event? {
        defer { buffer.removeAll(keepingCapacity: true) }
        guard !buffer.isEmpty else { return nil }
        let text = String(decoding: buffer, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        return Self.classify(text)
    }

    static func classify(_ token: String) -> Event {
        if let progress = parseProgress(token) { return progress }
        if isScanLine(token) { return .scanning }
        if let size = parseArchiveSize(token) { return .archiveSize(size) }
        if token == "Everything is Ok" { return .finishedOK }
        return .message(token)
    }

    /// ` 12% 1 + dir/file.bin` or `  0%`
    private static func parseProgress(_ token: String) -> Event? {
        var rest = Substring(token)
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3, let percent = Int(digits) else { return nil }
        rest = rest.dropFirst(digits.count)
        guard rest.first == "%" else { return nil }
        rest = rest.dropFirst()

        // Optional " <count> + <item>" tail.
        rest = Substring(rest.drop { $0 == " " })
        guard !rest.isEmpty else { return .progress(percent: percent, currentItem: nil) }
        let countDigits = rest.prefix { $0.isASCII && $0.isNumber }
        guard !countDigits.isEmpty else { return .progress(percent: percent, currentItem: nil) }
        rest = Substring(rest.dropFirst(countDigits.count).drop { $0 == " " })
        guard rest.first == "+" else { return .progress(percent: percent, currentItem: nil) }
        let item = rest.dropFirst().drop { $0 == " " }
        return .progress(percent: percent, currentItem: item.isEmpty ? nil : String(item))
    }

    /// `0M Scan` / `123M Scan some/dir`
    private static func isScanLine(_ token: String) -> Bool {
        let digits = token.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return false }
        let rest = token.dropFirst(digits.count)
        guard rest.first == "M" else { return false }
        return rest.dropFirst().trimmingCharacters(in: .whitespaces).hasPrefix("Scan")
    }

    /// `Archive size: 125899483 bytes (121 MiB)`
    private static func parseArchiveSize(_ token: String) -> Int64? {
        let prefix = "Archive size:"
        guard token.hasPrefix(prefix) else { return nil }
        let tail = token.dropFirst(prefix.count).drop { $0 == " " }
        let digits = tail.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int64(digits)
    }
}
