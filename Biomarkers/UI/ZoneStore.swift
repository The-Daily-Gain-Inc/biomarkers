import Foundation

/// HR zones derived from a single editable Max HR. The five zone lower
/// boundaries (Z1…Z5) are computed as fixed percentages of Max HR — the
/// standard %HRmax model — so the user only ever tunes one number and the
/// zones adjust on their own. Persisted in UserDefaults.
@MainActor
final class ZoneStore: ObservableObject {
    @Published var maxHR: Int {
        didSet { UserDefaults.standard.set(maxHR, forKey: Self.key) }
    }
    @Published var isFetchingDefaults = false

    private static let key = "hrMaxHR"

    /// Lower bound of each zone as a fraction of Max HR (Z1…Z5).
    static let zonePercents: [Double] = [0.50, 0.60, 0.70, 0.80, 0.90]

    /// Typical Max HR fallback if we've never fetched from Garmin.
    static let genericMaxHR = 190

    init() {
        let saved = UserDefaults.standard.integer(forKey: Self.key)
        maxHR = saved > 0 ? saved : Self.genericMaxHR
    }

    /// True once the user (or a Garmin fetch) has set a real Max HR.
    var hasCustom: Bool { UserDefaults.standard.object(forKey: Self.key) != nil }

    /// Zone lower boundaries (bpm) for Z1…Z5, computed from Max HR.
    var floors: [Int] {
        Self.zonePercents.map { Int((Double(maxHR) * $0).rounded()) }
    }

    /// Pull Max HR from Garmin: infer it from the highest zone boundary
    /// (Z5 low ≈ 90% of Max HR in Garmin's %HRmax model).
    func resetToGarmin(session: SessionStore) async {
        guard session.isLoggedIn else { return }
        isFetchingDefaults = true
        defer { isFetchingDefaults = false }
        let client = GarminClient(session: session)
        if let g = try? await client.hrZoneBoundaries(), let z5 = g.last, z5 > 0 {
            maxHR = Int((Double(z5) / 0.90).rounded())
        }
    }

    /// "120–139" style label for a zone (open-ended for Z5).
    func rangeLabel(zone: Int) -> String {
        let f = floors
        let i = zone - 1
        guard f.indices.contains(i) else { return "" }
        if zone < 5, f.indices.contains(i + 1) {
            return "\(f[i])–\(f[i + 1] - 1)"
        }
        return "\(f[i])+"
    }
}
