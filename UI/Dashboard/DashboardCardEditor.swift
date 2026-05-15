import SwiftUI

/// Modal sheet for customizing the摘要 grid. Two sections:
/// - "已显示" lets the user drag-reorder visible cards and remove them (− button).
/// - "可添加" lists everything currently hidden; tapping + promotes it back into the grid.
struct DashboardCardEditor: View {
    @ObservedObject var store: DashboardLayoutStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.visibleCards.isEmpty {
                        Text("当前没有任何卡片，从下方「可添加」补回。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.visibleCards) { kind in
                            HStack(spacing: 10) {
                                Button(role: .destructive) {
                                    store.hide(kind)
                                } label: {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundStyle(.red)
                                }
                                .buttonStyle(.plain)
                                kindLabel(kind)
                                Spacer()
                            }
                        }
                        .onMove { from, to in
                            store.move(from: from, to: to)
                        }
                    }
                } header: {
                    Text("已显示（拖动右侧把手调整顺序）")
                }

                Section {
                    if store.hiddenCards.isEmpty {
                        Text("已全部添加。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.hiddenCards) { kind in
                            Button {
                                store.show(kind)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundStyle(.tint)
                                    kindLabel(kind)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text("可添加")
                }

                Section {
                    Button(role: .destructive) {
                        store.resetToDefaults()
                    } label: {
                        Label("恢复默认布局", systemImage: "arrow.uturn.backward")
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("编辑卡片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func kindLabel(_ kind: DashboardCardKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.iconName)
                .font(.callout)
                .foregroundStyle(kind.theme.primary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.displayName).font(.body)
                Text(kind.isRich ? "完整卡片" : "单指标卡片")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
