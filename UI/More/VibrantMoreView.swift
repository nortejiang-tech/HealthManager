import SwiftUI

/// The "更多" surface: a colourful, low-text grid of navigation tiles.
///
/// The parent owns the `NavigationStack` and the navigation title, so this view
/// deliberately contains neither. Every destination is one of the eight
/// existing routes with its original accessibility identifier.
struct VibrantMoreView: View {
    /// Generous spacing used between tiles and sections.
    @Environment(\.dynamicTypeSize) private var typeSize
    private let tileSpacing: CGFloat = 14

    private var columns: [GridItem] {
        if typeSize.isAccessibilitySize {
            return [GridItem(.flexible(), spacing: tileSpacing, alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: 140), spacing: tileSpacing, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: tileSpacing) {
                Text("工具与记录")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 2)

                // Prominent, full-width entry point at the top.
                NavigationLink {
                    destination(for: settingsTile)
                } label: {
                    prominentLabel(for: settingsTile)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("more-settings")

                LazyVGrid(columns: columns, alignment: .leading, spacing: tileSpacing) {
                    ForEach(tiles.dropFirst()) { tile in
                        NavigationLink {
                            destination(for: tile)
                        } label: {
                            tileLabel(for: tile)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(tile.identifier)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
    }

    // MARK: - Route model

    private struct Tile: Identifiable {
        let id: String
        let identifier: String
        let title: String
        let symbol: String
        let caption: String?
        let accent: HMAccent
    }

    private var tiles: [Tile] { tileValues }

    private var settingsTile: Tile { tileValues[0] }

    private var tileValues: [Tile] {
        [
            Tile(id: "settings", identifier: "more-settings",
                 title: "设置", symbol: "gearshape.fill",
                 caption: "外观 · 设备 · 同步", accent: .sky),
            Tile(id: "sources", identifier: "more-sources",
                 title: "数据来源", symbol: "arrow.triangle.branch",
                 caption: nil, accent: .jade),
            Tile(id: "sync", identifier: "more-sync-center",
                 title: "同步中心", symbol: "arrow.triangle.2.circlepath",
                 caption: nil, accent: .lavender),
            Tile(id: "quality", identifier: "more-data-quality",
                 title: "数据质量", symbol: "checkmark.seal.fill",
                 caption: nil, accent: .amber),
            Tile(id: "alerts", identifier: "more-alerts",
                 title: "告警", symbol: "bell.badge.fill",
                 caption: nil, accent: .coral),
            Tile(id: "summary", identifier: "more-summary",
                 title: "日报/周报", symbol: "doc.text.fill",
                 caption: nil, accent: .sky),
            Tile(id: "workouts", identifier: "more-workouts",
                 title: "运动记录", symbol: "figure.run",
                 caption: nil, accent: .jade),
            Tile(id: "medication", identifier: "more-medication",
                 title: "用药", symbol: "pills.fill",
                 caption: nil, accent: .lavender),
        ]
    }

    // MARK: - Destinations (no AnyView)

    @ViewBuilder
    private func destination(for tile: Tile) -> some View {
        switch tile.id {
        case "settings": SettingsView()
        case "sources": SourcesView()
        case "sync": SyncCenterView()
        case "quality": DataQualityDetailView()
        case "alerts": AlertsView()
        case "summary": SummaryView()
        case "workouts": WorkoutsView()
        default: MedicationView(embeddedInNavigation: true)
        }
    }

    // MARK: - Tile labels

    private func tileLabel(for tile: Tile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            symbolBadge(for: tile)
            Spacer(minLength: 8)
            Text(tile.title)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let caption = tile.caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(tile.accent.color)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(tile.accent.soft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(tile.accent.color.opacity(0.22), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(for: tile))
    }

    private func prominentLabel(for tile: Tile) -> some View {
        HStack(spacing: 14) {
            symbolBadge(for: tile)
            VStack(alignment: .leading, spacing: 3) {
                Text(tile.title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.primary)
                if let caption = tile.caption {
                    Text(caption)
                        .font(.caption2)
                        .foregroundStyle(tile.accent.color)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(.footnote, design: .rounded, weight: .semibold))
                .foregroundStyle(tile.accent.color)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(tile.accent.gradient)
                .opacity(0.55)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(tile.accent.color.opacity(0.35), lineWidth: 1)
        )
        .contentShape(Rectangle())
        .frame(minHeight: 44)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(for: tile))
    }

    private func symbolBadge(for tile: Tile) -> some View {
        Image(systemName: tile.symbol)
            .font(.system(.title3, design: .rounded, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(tile.accent.color)
            )
            .accessibilityHidden(true)
    }

    private func accessibilityText(for tile: Tile) -> String {
        if let caption = tile.caption {
            return "\(tile.title)，\(caption)"
        }
        return tile.title
    }
}

#Preview {
    NavigationStack {
        VibrantMoreView()
    }
}
