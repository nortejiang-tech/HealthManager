import SwiftUI

/// Container for a dashboard tile. Matches the visual rhythm of Apple Health's摘要 cards:
/// rounded rectangle, colored icon, bold title, content area with metric + sparkline.
struct DashboardCard<Accessory: View, Content: View>: View {
    let theme: CardTheme
    let icon: String
    let title: String
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(theme: CardTheme,
         icon: String,
         title: String,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.theme = theme
        self.icon = icon
        self.title = title
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(theme.primary)
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.primary)
                Spacer(minLength: 4)
                accessory()
            }

            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HMColors.surface, in: RoundedRectangle(cornerRadius: HMRadius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HMRadius.card, style: .continuous)
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
                // 语义字号跟随 Dynamic Type（此前固定 26pt，辅助字号下会撑破双列网格）；
                // minimumScaleFactor 兜底保证长数值（如五位数步数）不换行。
                .font(.system(.title, design: .rounded).weight(.bold))
                .foregroundStyle(theme?.primary ?? .primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let u = unit {
                Text(u)
                    .font(.caption.weight(.semibold))
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
