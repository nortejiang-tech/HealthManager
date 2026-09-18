import SwiftUI

/// 轻量左滑移除行：ScrollView+VStack 布局下的可发现移除手势（§3.1）。
/// 左滑露出「移除」按钮，滑过阈值或点按钮触发；不弹确认（操作可逆，由列表撤销横幅兜底）。
struct SwipeToRemoveRow<Content: View>: View {
    let content: () -> Content
    let onRemove: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isRevealed: Bool = false

    private let revealWidth: CGFloat = 84

    var body: some View {
        ZStack(alignment: .trailing) {
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
                .background(HMColors.actionRequired, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("移除该食材")
            .opacity(offset < -8 ? 1 : 0)

            content()
                .background(HMColors.surface)
                .offset(x: offset)
                .gesture(swipeGesture)
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
