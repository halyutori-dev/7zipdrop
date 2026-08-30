import Foundation

/// Turns 7zz's own wording into a specific error.
///
/// Pinned to the exact strings 7-Zip 26.02 produces (contract #35), which were captured
/// from all four combinations of command (`l` / `x`) and password state (missing / wrong).
/// The distinction matters to the user: "enter a password" and "that password is wrong"
/// call for different next actions.
public enum SevenZipDiagnostics {
    public static func passwordProblem(in output: String, passwordSupplied: Bool) -> CompressorError? {
        let lowercased = output.lowercased()
        if lowercased.contains("wrong password") {
            return passwordSupplied ? .wrongPassword : .passwordRequired
        }
        if lowercased.contains("enter password") {
            // 7zz only prompts when it has none, so this always means "one is needed".
            return .passwordRequired
        }
        return nil
    }
}
