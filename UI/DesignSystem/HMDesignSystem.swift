import SwiftUI
import UIKit

/// Cross-page evidence semantics. `CardTheme` remains the owner of metric-family
/// presentation contract.
enum HMSemanticTone: CaseIterable {
    case comparison
    case confirmed
    case actionRequired
    case estimate
    case neutral

    var color: Color {
        switch self {
        case .comparison:
            HMColors.comparison
        case .confirmed:
            HMColors.confirmed
        case .actionRequired:
            HMColors.actionRequired
        case .estimate:
            HMColors.estimate
        case .neutral:
            HMColors.neutral
        }
    }

    var secondaryColor: Color {
        switch self {
        case .comparison:
            HMColors.comparison.opacity(0.15)
        case .confirmed:
            HMColors.confirmed.opacity(0.15)
        case .actionRequired:
            HMColors.actionRequired.opacity(0.15)
        case .estimate:
            HMColors.estimate.opacity(0.15)
        case .neutral:
            HMColors.neutral.opacity(0.15)
        }
    }

    var iconName: String {
        switch self {
        case .comparison:
            "arrow.left.and.right"
        case .confirmed:
            "checkmark.seal.fill"
        case .actionRequired:
            "exclamationmark.circle.fill"
        case .estimate:
            "sparkles"
        case .neutral:
            "waveform.path"
        }
    }
}

enum HMColors {
    static let background = dynamic(light: 0xFCFAF7, dark: 0x121316)
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x1A1C1F)
    static let separator = dynamic(light: 0xE2DFDA, dark: 0x3A3D42)
    static let skeleton = dynamic(light: 0xE6E3DF, dark: 0x303338)

    static let comparison = dynamic(light: 0x0A63E8, dark: 0x69A8FF)
    static let confirmed = dynamic(light: 0x007F7B, dark: 0x4BCAC1)
    static let actionRequired = dynamic(light: 0xC93F16, dark: 0xFF8E6B)
    static let primaryAction = dynamic(light: 0xC93F16, dark: 0xA83212)
    static let estimate = dynamic(light: 0x6444DC, dark: 0xAA98FF)
    static let neutral = dynamic(light: 0x666B73, dark: 0xB7BAC0)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(
            uiColor: UIColor { traits in
                rgb(traits.userInterfaceStyle == .dark ? dark : light)
            }
        )
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

enum HMDateText {
    private static let fullWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.setLocalizedDateFormatFromTemplate("yMMMMdEEEE")
        return formatter
    }()

    static func fullWeekday(_ date: Date = Date()) -> String {
        fullWeekdayFormatter.string(from: date)
    }
}

struct HMEditorialHeader: View {
    let title: String
    let subtitle: String?
    var alignment: HorizontalAlignment = .leading

    init(title: String, subtitle: String?, alignment: HorizontalAlignment = .leading) {
        self.title = title
        self.subtitle = subtitle
        self.alignment = alignment
    }

    init(title: String) {
        self.title = title
        self.subtitle = nil
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 10) {
            Text(title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(subtitle)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
    }
}

struct HMEvidenceTag: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let tone: HMSemanticTone
    let text: String
    var systemImage: String? = nil

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: dynamicTypeSize.isAccessibilitySize ? 12 : 999,
            style: .continuous
        )

        Label(
            title: {
                Text(text)
                    .foregroundStyle(.primary)
            },
            icon: {
                Image(systemName: systemImage ?? tone.iconName)
                    .foregroundStyle(tone.color)
            }
        )
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 10 : 12)
        .padding(.vertical, dynamicTypeSize.isAccessibilitySize ? 7 : 8)
        .background(tone.secondaryColor, in: shape)
        .overlay {
            shape.stroke(tone.color.opacity(0.25), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct HMDecisionLens: View {
    struct SecondaryAction {
        let title: String
        let systemImage: String
        let tone: HMSemanticTone
        let action: () -> Void
        let accessibilityIdentifier: String?
    }

    let title: String
    let text: String
    let tone: HMSemanticTone
    let systemImage: String
    let primaryActionTitle: String?
    let primaryActionIcon: String
    let primaryActionTint: Color
    let primaryAction: (() -> Void)?
    let primaryActionIdentifier: String?
    let secondaryActions: [SecondaryAction]

    init(
        title: String,
        text: String,
        tone: HMSemanticTone,
        systemImage: String = "scope",
        primaryActionTitle: String? = nil,
        primaryActionIcon: String = "sparkles",
        primaryActionTone: HMSemanticTone = .comparison,
        primaryActionTint: Color? = nil,
        primaryActionIdentifier: String? = nil,
        primaryAction: (() -> Void)? = nil,
        secondaryActions: [SecondaryAction] = []
    ) {
        self.title = title
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
        self.primaryActionTitle = primaryActionTitle
        self.primaryActionIcon = primaryActionIcon
        self.primaryActionTint = primaryActionTint ?? primaryActionTone.color
        self.primaryActionIdentifier = primaryActionIdentifier
        self.primaryAction = primaryAction
        self.secondaryActions = secondaryActions
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HMEvidenceTag(
                tone: tone,
                text: title,
                systemImage: systemImage
            )
            Text(text)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            actionStack
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .hmSurface(cornerRadius: 18)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var actionStack: some View {
        let actions = secondaryActions.prefix(2)
        if let primaryActionTitle, let primaryAction {
            if actions.isEmpty {
                primaryButton(title: primaryActionTitle, action: primaryAction)
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        primaryButton(title: primaryActionTitle, action: primaryAction)
                        secondaryButtons(actions)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        primaryButton(title: primaryActionTitle, action: primaryAction)
                        secondaryButtons(actions)
                    }
                }
            }
        } else if !actions.isEmpty {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    secondaryButtons(actions)
                }
                VStack(alignment: .leading, spacing: 8) {
                    secondaryButtons(actions)
                }
            }
        }
    }

    private func primaryButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: primaryActionIcon)
                Text(title)
                    .lineLimit(nil)
            }
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(primaryActionTint)
        .controlSize(.large)
        .hmAccessibilityIdentifier(primaryActionIdentifier)
    }

    @ViewBuilder
    private func secondaryButtons(_ actions: ArraySlice<SecondaryAction>) -> some View {
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            Button {
                action.action()
            } label: {
                Label(action.title, systemImage: action.systemImage)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.bordered)
            .tint(action.tone.color)
            .controlSize(.regular)
            .hmAccessibilityIdentifier(action.accessibilityIdentifier)
        }
    }
}

struct HMProvenanceRail: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    struct Step {
        let title: String
        let detail: String
        let tone: HMSemanticTone
        let systemImage: String
        let accessibilityIdentifier: String?
    }

    let title: String
    let steps: [Step]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        verticalStep(step, isLast: index == steps.count - 1)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        horizontalStep(step, isLast: index == steps.count - 1)
                    }
                }
            }
        }
        .padding(16)
        .hmSurface(cornerRadius: 18)
    }

    private func horizontalStep(_ step: Step, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                HMIconBadge(systemImage: step.systemImage, tone: step.tone, size: 34)
                if !isLast {
                    Rectangle()
                        .fill(step.tone.color.opacity(0.36))
                        .frame(height: 2)
                }
            }
            Text(step.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
            Text(step.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.trailing, isLast ? 0 : 10)
        .accessibilityElement(children: .combine)
        .hmAccessibilityIdentifier(step.accessibilityIdentifier)
    }

    private func verticalStep(_ step: Step, isLast: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                HMIconBadge(systemImage: step.systemImage, tone: step.tone, size: 34)
                if !isLast {
                    Rectangle()
                        .fill(step.tone.color.opacity(0.36))
                        .frame(width: 2, height: 24)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.subheadline.weight(.semibold))
                Text(step.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .hmAccessibilityIdentifier(step.accessibilityIdentifier)
    }
}

struct HMEmptyState: View {
    let title: String
    let message: String
    let icon: String
    let tone: HMSemanticTone
    let primaryActionTitle: String?
    let primaryActionIcon: String
    let primaryAction: (() -> Void)?
    let primaryActionIdentifier: String?
    let secondaryActionTitle: String?
    let secondaryAction: (() -> Void)?
    let secondaryActionIdentifier: String?

    init(
        title: String,
        message: String,
        icon: String = "tray",
        tone: HMSemanticTone = .neutral,
        primaryActionTitle: String? = nil,
        primaryActionIcon: String = "plus",
        primaryAction: (() -> Void)? = nil,
        primaryActionIdentifier: String? = nil,
        secondaryActionTitle: String? = nil,
        secondaryAction: (() -> Void)? = nil,
        secondaryActionIdentifier: String? = nil
    ) {
        self.title = title
        self.message = message
        self.icon = icon
        self.tone = tone
        self.primaryActionTitle = primaryActionTitle
        self.primaryActionIcon = primaryActionIcon
        self.primaryAction = primaryAction
        self.primaryActionIdentifier = primaryActionIdentifier
        self.secondaryActionTitle = secondaryActionTitle
        self.secondaryAction = secondaryAction
        self.secondaryActionIdentifier = secondaryActionIdentifier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HMEvidenceTag(
                tone: tone,
                text: title,
                systemImage: icon
            )
            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let primaryActionTitle, let primaryAction {
                Button {
                    primaryAction()
                } label: {
                    Label(primaryActionTitle, systemImage: primaryActionIcon)
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(HMColors.comparison)
                .hmAccessibilityIdentifier(primaryActionIdentifier)
            }
            if let secondaryActionTitle, let secondaryAction {
                Button(secondaryActionTitle) {
                    secondaryAction()
                }
                .buttonStyle(.bordered)
                .hmAccessibilityIdentifier(secondaryActionIdentifier)
            }
        }
        .padding(18)
        .hmSurface(cornerRadius: 18)
    }
}

struct HMInformationRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let systemImage: String
    let tone: HMSemanticTone
    let title: String
    let detail: String
    var trailingText: String? = nil
    var trailingTone: HMSemanticTone = .neutral

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    leadingContent
                    if let trailingText {
                        Text(trailingText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(trailingTone.color)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 58)
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 14) {
                    leadingContent

                    if let trailingText {
                        Spacer(minLength: 8)
                        Text(trailingText)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(trailingTone.color)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var leadingContent: some View {
        HStack(alignment: .top, spacing: 14) {
            HMIconBadge(systemImage: systemImage, tone: tone)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct HMIconBadge: View {
    let systemImage: String
    let tone: HMSemanticTone
    var size: CGFloat = 44

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tone.color)
            .frame(width: size, height: size)
            .background(tone.secondaryColor, in: Circle())
            .accessibilityHidden(true)
    }
}

struct HMEditorGuide: View {
    let title: String
    let message: String
    let systemImage: String
    let tone: HMSemanticTone

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HMIconBadge(systemImage: systemImage, tone: tone, size: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

struct HMEditorCallout: View {
    let title: String
    let message: String
    let tone: HMSemanticTone
    var systemImage: String? = nil
    var detail: String? = nil
    var accessibilityIdentifier: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage ?? tone.iconName)
                .font(.body.weight(.semibold))
                .foregroundStyle(tone.color)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    DisclosureGroup("技术信息") {
                        Text(detail)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .font(.footnote)
                    .tint(tone.color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(tone.secondaryColor, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tone.color.opacity(0.28), lineWidth: 1)
        }
        .hmAccessibilityIdentifier(accessibilityIdentifier)
    }
}

struct HMInlineRecovery: View {
    let title: String
    let message: String
    var technicalDetails: String? = nil
    let actionTitle: String
    let onAction: () -> Void
    var titleAccessibilityIdentifier: String? = nil
    var actionAccessibilityIdentifier: String? = nil
    var copyAccessibilityLabel = "复制技术信息"

    @State private var isTechnicalOpen = false
    @State private var copiedDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                HMIconBadge(
                    systemImage: "exclamationmark.triangle.fill",
                    tone: .actionRequired,
                    size: 42
                )

                VStack(alignment: .leading, spacing: 6) {
                    titleView
                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let technicalDetails, !technicalDetails.isEmpty {
                DisclosureGroup(isExpanded: $isTechnicalOpen) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(technicalDetails)
                            .font(.footnote.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            UIPasteboard.general.string = technicalDetails
                            copiedDetails = true
                        } label: {
                            Label(
                                copiedDetails ? "已复制" : "复制技术信息",
                                systemImage: copiedDetails ? "checkmark" : "doc.on.doc"
                            )
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: 44)
                        }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .accessibilityLabel(copyAccessibilityLabel)
                    }
                    .padding(.top, 4)
                } label: {
                    Text(isTechnicalOpen ? "收起技术信息" : "展开技术信息")
                }
                .font(.subheadline.weight(.medium))
                .tint(HMColors.comparison)
                .accessibilityHint("可展开或收起错误细节")
            }

            actionButton
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hmSurface()
    }

    @ViewBuilder
    private var titleView: some View {
        if let titleAccessibilityIdentifier {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(titleAccessibilityIdentifier)
        } else {
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        if let actionAccessibilityIdentifier {
            retryButton
                .accessibilityIdentifier(actionAccessibilityIdentifier)
        } else {
            retryButton
        }
    }

    private var retryButton: some View {
        Button(action: onAction) {
            Label(actionTitle, systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(HMColors.comparison)
        .accessibilityHint("重新发起该动作")
    }
}

struct HMLoadingSkeleton: View {
    var width: CGFloat? = nil
    var height: CGFloat = 14
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let width {
                skeletonShape(width: width)
            } else {
                skeletonShape()
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func skeletonShape(width: CGFloat? = nil) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(HMColors.skeleton)
            .frame(width: width)
    }
}

extension View {
    func hmSurface(cornerRadius: CGFloat = 18) -> some View {
        background(HMColors.surface, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(HMColors.separator, lineWidth: 1)
            }
    }

    @ViewBuilder
    func hmAccessibilityIdentifier(_ identifier: String?) -> some View {
        if let identifier, !identifier.isEmpty {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}
