import Foundation

/// A validated `-v` volume size. Units are **1024-based**, matching 7-Zip (contract #12).
public struct SplitSize: Equatable, Hashable, Sendable {
    public enum Unit: String, Codable, CaseIterable, Sendable {
        case bytes = "b"
        case kibibytes = "k"
        case mebibytes = "m"
        case gibibytes = "g"

        var multiplier: Int64 {
            switch self {
            case .bytes: 1
            case .kibibytes: 1024
            case .mebibytes: 1024 * 1024
            case .gibibytes: 1024 * 1024 * 1024
            }
        }
    }

    public static let minimumByteCount: Int64 = 1024
    public static let maximumByteCount: Int64 = 16 * 1024 * 1024 * 1024 * 1024  // 16 TiB

    public let value: Int
    public let unit: Unit

    public init(value: Int, unit: Unit) throws {
        guard value > 0 else { throw SplitSizeError.malformed("\(value)\(unit.rawValue)") }
        let (product, didOverflow) = Int64(value).multipliedReportingOverflow(by: unit.multiplier)
        guard !didOverflow, product <= Self.maximumByteCount else { throw SplitSizeError.overflow }
        guard product >= Self.minimumByteCount else {
            throw SplitSizeError.tooSmall(minimumBytes: Self.minimumByteCount)
        }
        self.value = value
        self.unit = unit
    }

    public var byteCount: Int64 { Int64(value) * unit.multiplier }

    /// e.g. `-v100m`
    public var switchArgument: String { "-v\(value)\(unit.rawValue)" }

    public var displayText: String { "\(value)\(unit.rawValue)" }

    /// Parses user input. Returns `nil` for "no split" (empty or zero), and throws on
    /// anything it cannot interpret — it never silently coerces garbage into a size.
    public static func parse(_ text: String) throws -> SplitSize? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        // ASCII digits only: "١٠m" must be rejected rather than quietly parsed.
        let digits = trimmed.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty else { throw SplitSizeError.malformed(text) }

        let suffix = trimmed
            .dropFirst(digits.count)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()

        // The unit is validated *before* the zero check so that "0x10" is an error
        // rather than being read as "no split".
        let unit: Unit
        switch suffix {
        case "", "b": unit = .bytes
        case "k", "kb", "kib": unit = .kibibytes
        case "m", "mb", "mib": unit = .mebibytes
        case "g", "gb", "gib": unit = .gibibytes
        default: throw SplitSizeError.unknownUnit(suffix)
        }

        guard let value = Int(digits) else { throw SplitSizeError.overflow }
        if value == 0 { return nil }
        return try SplitSize(value: value, unit: unit)
    }

    public static let presets: [(label: String, size: SplitSize)] = {
        let raw: [(String, Int, Unit)] = [
            ("メール添付 (10 MB)", 10, .mebibytes),
            ("メール添付 (25 MB)", 25, .mebibytes),
            ("CD-R (700 MB)", 700, .mebibytes),
            ("FAT32 上限 (4095 MB)", 4095, .mebibytes),
            ("DVD-R (4480 MB)", 4480, .mebibytes),
            ("2 GB", 2, .gibibytes),
        ]
        // A malformed preset is a programming error, so it is filtered out rather
        // than crashing the app at launch; the unit test asserts none are dropped.
        return raw.compactMap { label, value, unit in
            guard let size = try? SplitSize(value: value, unit: unit) else { return nil }
            return (label, size)
        }
    }()
}

extension SplitSize: Codable {
    private enum CodingKeys: String, CodingKey { case value, unit }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Re-validate: persisted settings are external input and may have been edited.
        try self.init(
            value: try c.decode(Int.self, forKey: .value),
            unit: try c.decode(Unit.self, forKey: .unit)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(value, forKey: .value)
        try c.encode(unit, forKey: .unit)
    }
}
