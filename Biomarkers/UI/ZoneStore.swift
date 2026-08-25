import Foundation

/// User-editable HR zone lower boundaries (bpm) for Z1…Z5. Defaults to the
/// boundaries read from Garmin; persisted in UserDefaults. These are used as
/// the reference labels in the HR Zones view and for computing zones from
/// raw heart-rate samples (e.g. Oura).
@MainActor
final class ZoneStore: ObservableObject {
    @Published var floors: [Int] {
        didSet { persist() }
    }
    @Published var isFetchingDefaults = false

    private static let key = "hrZoneFloors"

    /// Fallback if we've never fetched Garmin's — typical 5-zone split.
    static let genericDefault = [100, 120, 140, 160, 175]

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Int].self, from: data), saved.count == 5 {
            floors = saved
        } else {
            floors = Self.genericDefault
        }
    }

    /// True once the user (or a Garmin fetch) has set real boundaries.
    var hasCustom: Bool { UserDefaults.standard.data(forKey: Self.key) != nil }

    func set(zone: Int, bpm: Int) {
        guard (1...5).contains(zone) else { return }
        floors[zone - 1] = max(0, bpm)
    }

    /// Pull the boundaries from Garmin and adopt them as the defaults.
    func resetToGarmin(session: SessionStore) async {
        guard session.isLoggedIn else { return }
        isFetchingDefaults = true
        defer { isFetchingDefaults = false }
        let client = GarminClient(session: session)
        if let g = try? await client.hrZoneBoundaries(), g.count == 5 {
            floors = g
        }
    }

    /// "120–139" style label for a zone (open-ended for Z5).
    func rangeLabel(zone: Int) -> String {
        let i = zone - 1
        guard floors.indices.contains(i) else { return "" }
        if zone < 5, floors.indices.contains(i + 1) {
            return "\(floors[i])–\(floors[i + 1] - 1)"
        }
        return "\(floors[i])+"
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(floors) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
