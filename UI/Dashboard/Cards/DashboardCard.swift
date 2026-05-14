import SwiftUI

/// Container for a dashboard tile. Matches the visual rhythm of Apple Health's摘要 cards:
/// rounded rectangle, colored icon, bold title, content area with metric + sparkline.
struct DashboardCard<Content: View>: View {
    let theme: CardTheme
    let icon: String
    let title: String
    let titleAccessory: String?
    @ViewBuilder var content: () -> Content

    init(theme: CardTheme,
         icon: String,
         title: String,
         titleAccessory: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.theme = theme
        self.icon = icon
        self.title = title
        self.titleAccessory = titleAccessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(theme.primary)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.primary)
                Spacer(minLength: 4)
                if let acc = titleAccessory {
                    Text(acc)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(theme.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

/// Big monospaced number with an optional unit. Reused across cards for the primary metric.
struct CardMetric: View {
    let value: String
    let unit: String?
    let theme: CardTheme?

    init(value: String, unit: String?, theme: CardTheme? = nil) {
        self.value = value
        self.unit = unit
        self.theme = theme
    }

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(theme?.primary ?? .primary)
                .monospacedDigit()
            if let u = unit {
                Text(u)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 1)
            }
        }
    }
}

/// Tiny placeholder used inside a card when its chart area has nothing to show.
struct CardEmptyState: View {
    let text: String
    var body: some View {
        HStack {
            Spacer()
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
    }
}
