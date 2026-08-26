import SwiftUI

/// Toggle which metrics appear in the Trends grid. Hidden ids are stored as a
/// comma-separated list so it persists and can be edited on the go.
struct MetricVisibilityEditor: View {
    @Binding var hiddenCSV: String
    @Environment(\.dismiss) private var dismiss

    private var hidden: Set<String> {
        Set(hiddenCSV.split(separator: ",").map(String.init))
    }

    private let order: [Metric.Provider] = [.garmin, .oura, .renpho, .manual]

    var body: some View {
        NavigationStack {
            List {
                ForEach(order, id: \.self) { provider in
                    let group = DashboardModel.placeholders.filter { $0.provider == provider }
                    if !group.isEmpty {
                        Section(provider.rawValue) {
                            ForEach(group) { metric in
                                Toggle(isOn: binding(for: metric.id)) {
                                    Text(LocalizedStringKey(metric.titleKey))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(Text("Trends Metrics"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Show All") { hiddenCSV = "" }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func binding(for id: String) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(id) },
            set: { show in
                var set = hidden
                if show { set.remove(id) } else { set.insert(id) }
                hiddenCSV = set.sorted().joined(separator: ",")
            }
        )
    }
}
