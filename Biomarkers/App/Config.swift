import Foundation

/// Read-only personal reference constants (shown in the Retro tab).
/// Min protein = weight(lbs) × 0.55; target = min + 40.
enum ProfileConstants {
    static let age = 33
    static let heightCm = 176
    static let weightLbs = 156.53
    static let minProteinG = 86.09
    static let targetProteinG = 126.09
    static let baselineCalories = 2400
}

enum Config {
    /// Oura OAuth application client ID (not secret). Unused while Oura auth
    /// is via personal access token; kept for a future OAuth implicit flow.
    static let ouraClientId = "05b941d4-f3a7-4ac1-a9ec-ebd98526c1b1"
}
