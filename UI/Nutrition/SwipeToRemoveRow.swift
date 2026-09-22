import SwiftUI

/// 轻量左滑移除行：ScrollView+VStack 布局下的可发现移除手势（§3.1）。
/// 左滑露出「移除」按钮，滑过阈值或点按钮触发；不弹确认（操作可逆，由列表撤销横幅兜底）。
struct SwipeToRemoveRow<Content: View>: View {
    let content: () -> Content
    let onRemove: () -> Void
    /// 移除按钮的 VoiceOver 标签，按场景传入（如「移除该食材」「删除该计划」）。
    let removeAccessibilityLabel: String

    @State private var offset: CGFloat = 0
    @State private var isRevealed: Bool = false

    private let revealWidth: CGFloat = 84

    init(
        removeAccessibilityLabel: String = "移除该项",
        @ViewBuilder content: @escaping () -> Content,
        onRemove: @escaping () -> Void
    ) {
        self.content = content
        self.onRemove = onRemove
        self.removeAccessibilityLabel = removeAccessibilityLabel
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            content()
                .background(HMColors.surface)
                .offset(x: offset)
                // simultaneousGesture：外层 ScrollView 的滚动手势优先级更高，普通
                // .gesture 会被其吞掉（拖拽事件根本不到这里）；同时识别则水平拖拽
                // 揭示按钮、垂直滚动不受影响（onChanged 内有方向守卫）。
                .simultaneousGesture(swipeGesture)
                // VoiceOver 无法执行左滑拖拽：提供具名替代动作直接触发移除。
                .accessibilityAction(named: Text(removeAccessibilityLabel)) {
                    onRemove()
                }

            // 揭示前不渲染按钮：opacity(0) 的隐藏按钮仍会进入无障碍树，
            // VoiceOver 与 XCUITest 会命中多个同名元素；条件渲染则同一时刻至多一个。
            // 按钮放在内容之上（ZStack 顶层）：合成触摸/无障碍命中在实现间
            // 对 offset 后的行热区处理不一致，顶层按钮保证揭示区域点击必达。
            if offset < -8 {
                Button {
                    onRemove()
                    reset(animated: true)
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "trash")
                        Text("移除")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: revealWidth - 8, height: 52)
                    .background(HMColors.actionRequired, in: RoundedRectangle(cornerRadius: HMRadius.cell, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(removeAccessibilityLabel)
                .accessibilityIdentifier("swipe-remove-button")
                .transition(.opacity)
            }
        }
        .clipped()
    }

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 22)
            .onChanged { value in
                // 垂直滚动让位：水平位移不占优时不响应。
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                let proposed = (isRevealed ? -revealWidth : 0) + value.translation.width
                offset = min(0, max(-revealWidth, proposed))
            }
            .onEnded { value in
                let shouldReveal = offset < -revealWidth / 2
                    || value.predictedEndTranslation.width < -revealWidth
                withAnimation(.snappy) {
                    isRevealed = shouldReveal
                    offset = shouldReveal ? -revealWidth : 0
                }
            }
    }

    private func reset(animated: Bool) {
        if animated {
            withAnimation(.snappy) {
                isRevealed = false
                offset = 0
            }
        } else {
            isRevealed = false
            offset = 0
        }
    }
}
