import SwiftUI

/// Compact single-metric tile. Mirrors `ActivityCard` / `BodyCard` chrome but only
/// shows a name + a big number + (optional) caption. Used for slim-card kinds like
/// BMI / 体脂率 / 心率变异性 that the user can promote into the main grid.
struct SlimMetricCard: View {
    let kind: DashboardCardKind
    let value: Double?
    let unit: String?
    let format: (Double) -> String
    /// Optional second-line text under the metric (e.g. "目标 18 – 24" for BMI).
    let caption: String?

    init(kind: DashboardCardKind,
         value: Double?,
         unit: String?,
         format: @escaping (Double) -> String,
         caption: String? = nil) {
        self.kind = kind
        self.value = value
        self.unit = unit
        self.format = format
        self.caption = caption
    }

    var body: some View {
        DashboardCard(
            theme: kind.theme,
            icon: kind.iconName,
            title: kind.displayName
        ) {
            if let v = value {
                CardMetric(value: format(v), unit: unit, theme: kind.theme)
            } else {
                CardMetric(value: "—", unit: nil)
            }
            if let c = caption {
                Text(c)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                // Reserve baseline height so slim cards sit at the same height as
                // each other in a grid row.
                Color.clear.frame(height: 12)
            }
        }
    }
}
