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
                    HMEditorGuide(
                        title: "只调整趋势首页",
                        message: "拖动可改变顺序；隐藏卡片不会删除任何健康记录。",
                        systemImage: "rectangle.3.group",
                        tone: .comparison
                    )
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(HMColors.background)
                    .listRowSeparator(.hidden)
                }

                Section {
                    if store.visibleCards.isEmpty {
                        editorEmptyRow(
                            systemImage: "rectangle.slash",
                            title: "首页暂不显示卡片",
                            detail: "健康记录仍保留；可从下方“可添加”恢复。"
                        )
                    } else {
                        ForEach(store.visibleCards) { kind in
                            HStack(spacing: 10) {
                                Button {
                                    store.hide(kind)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(HMColors.neutral)
                                        .frame(width: 44, height: 44)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("隐藏\(kind.displayName)卡片")
                                .accessibilityHint("只从趋势首页隐藏，不会删除健康记录")
                                .accessibilityIdentifier("dashboard-card-hide-\(kind.rawValue)")

                                kindLabel(kind)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 52)
                            .accessibilityElement(children: .contain)
                        }
                        .onMove { from, to in
                            store.move(from: from, to: to)
                        }
                    }
                } header: {
                    Text("已显示 · \(store.visibleCards.count)")
                        .accessibilityIdentifier("dashboard-card-editor-visible-count")
                }

                Section {
                    if store.hiddenCards.isEmpty {
                        editorEmptyRow(
                            systemImage: "checkmark.circle",
                            title: "全部卡片都已显示",
                            detail: "隐藏任一卡片后，它会出现在这里。"
                        )
                    } else {
                        ForEach(store.hiddenCards) { kind in
                            Button {
                                store.show(kind)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 22, weight: .semibold))
                                        .foregroundStyle(HMColors.confirmed)
                                        .frame(width: 44, height: 44)
                                    kindLabel(kind)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .frame(minHeight: 52)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("显示\(kind.displayName)卡片")
                            .accessibilityHint("添加到趋势首页已显示卡片的末尾")
                            .accessibilityIdentifier("dashboard-card-show-\(kind.rawValue)")
                        }
                    }
                } header: {
                    Text("可添加 · \(store.hiddenCards.count)")
                        .accessibilityIdentifier("dashboard-card-editor-hidden-count")
                }

                Section {
                    Button {
                        store.resetToDefaults()
                    } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(HMColors.comparison)
                                .frame(width: 28, height: 44)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("恢复默认布局")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text("只恢复默认显示与顺序，不影响健康记录")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("恢复默认布局")
                    .accessibilityHint("恢复默认卡片显示与顺序，不影响健康记录")
                    .accessibilityIdentifier("dashboard-card-reset")
                }
            }
            .scrollContentBackground(.hidden)
            .background(HMColors.background)
            .environment(\.editMode, .constant(.active))
            .navigationTitle("编辑卡片")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("dashboard-card-editor")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                        .accessibilityIdentifier("dashboard-card-done")
                }
            }
        }
    }

    private func kindLabel(_ kind: DashboardCardKind) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.iconName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(kind.theme.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 0) {
                Text(kind.displayName)
                    .font(.body.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text(kind.isRich ? "完整卡片" : "单指标卡片")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func editorEmptyRow(
        systemImage: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            HMIconBadge(systemImage: systemImage, tone: .neutral, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body.weight(.medium))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
