import SwiftUI

/// Appearance settings surface that lets the user pick the presentation mode.
///
/// Persistence is handled exclusively through `@AppStorage` on the key owned by
/// the app root (`HMDisplayMode.storageKey`). No other `UserDefaults` write
/// happens here, and the root view is responsible for publishing the resolved
/// value back into the environment via `hmDisplayMode`.
struct AppearanceSettingsView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(HMDisplayMode.storageKey) private var rawMode: String = HMDisplayMode.cards.rawValue

    private var selectedMode: HMDisplayMode { HMDisplayMode.resolve(rawMode) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HMSectionHeading(
                    "显示模式",
                    subtitle: "选择健康数据的呈现方式，随时可以切换。"
                )

                VStack(spacing: 14) {
                    modeCard(.cards)
                    modeCard(.classic)
                }

                Text("仅改变显示方式，数据与统计口径保持一致。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationTitle("显示模式")
        .accessibilityIdentifier("appearance-settings")
    }

    // MARK: - Mode card

    @ViewBuilder
    private func modeCard(_ mode: HMDisplayMode) -> some View {
        let isSelected = selectedMode == mode

        Button {
            rawMode = mode.rawValue
        } label: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(mode.title)
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mode.subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                if !typeSize.isAccessibilitySize {
                    preview(for: mode).frame(width: 96, height: 64)
                }

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .foregroundStyle(isSelected ? HMAccent.jade.color : Color.secondary.opacity(0.4))
                    .opacity(isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(isSelected ? HMAccent.jade.soft : Color(uiColor: .secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(
                        isSelected ? HMAccent.jade.color.opacity(0.55) : Color.primary.opacity(0.10),
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .minimumHeight44()
        .accessibilityLabel(accessibilityLabel(for: mode))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("display-mode-\(mode.rawValue)")
    }

    private func accessibilityLabel(for mode: HMDisplayMode) -> String {
        if selectedMode == mode {
            return "\(mode.title)，\(mode.subtitle)，当前已选择"
        }
        return "\(mode.title)，\(mode.subtitle)"
    }

    // MARK: - Decorative miniatures

    /// Purely decorative miniature previews. These are coloured rounded
    /// rectangles only: no fake health values are implied.
    @ViewBuilder
    private func preview(for mode: HMDisplayMode) -> some View {
        switch mode {
        case .cards:
            HStack(alignment: .top, spacing: 6) {
                miniatureColumn(colors: [HMAccent.jade.color, HMAccent.coral.color])
                miniatureColumn(colors: [HMAccent.lavender.color, HMAccent.sky.color])
                miniatureColumn(colors: [HMAccent.amber.color, HMAccent.jade.color])
            }
            .accessibilityHidden(true)
        case .classic:
            VStack(alignment: .leading, spacing: 6) {
                classicRow(width: 88)
                classicRow(width: 76)
                classicRow(width: 82)
                classicRow(width: 64)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
        }
    }

    private func miniatureColumn(colors: [Color]) -> some View {
        VStack(spacing: 6) {
            ForEach(Array(colors.enumerated()), id: \.offset) { _, color in
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(color)
                    .frame(maxWidth: .infinity, minHeight: 22, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func classicRow(width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.16))
            .frame(width: width, height: 8)
    }
}

private extension View {
    /// Guarantee at least a 44pt interactive height for the whole card.
    func minimumHeight44() -> some View {
        self.frame(minHeight: 44)
    }
}

#Preview {
    NavigationStack {
        AppearanceSettingsView()
    }
}
