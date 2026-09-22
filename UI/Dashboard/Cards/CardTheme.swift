import SwiftUI
import UIKit

/// Apple Health–style palette. Each metric family has a primary color and a
/// matching gradient used for chart fills and accent stripes.
/// 浅/深双模：此前只有一组硬编码 RGB，深色下高饱和刺眼；深色变体统一提亮、
/// 略降饱和，保持色相身份（与 HMColors 的 dynamic 工厂同一范式）。
struct CardTheme {
    let primary: Color
    let secondary: Color

    var gradient: LinearGradient {
        LinearGradient(
            colors: [primary, secondary],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double)) -> Color {
        Color(
            uiColor: UIColor { traits in
                let c = traits.userInterfaceStyle == .dark ? dark : light
                return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            }
        )
    }

    static let activity = CardTheme(
        primary: dynamic(light: (1.0, 0.18, 0.33), dark: (1.0, 0.42, 0.52)),   // activity red
        secondary: dynamic(light: (1.0, 0.45, 0.4), dark: (1.0, 0.58, 0.54))
    )
    static let heart = CardTheme(
        primary: dynamic(light: (1.0, 0.35, 0.55), dark: (1.0, 0.55, 0.70)),   // heart pink
        secondary: dynamic(light: (1.0, 0.55, 0.75), dark: (1.0, 0.68, 0.82))
    )
    static let sleep = CardTheme(
        primary: dynamic(light: (0.46, 0.43, 0.95), dark: (0.64, 0.62, 1.0)),  // sleep indigo
        secondary: dynamic(light: (0.66, 0.62, 1.0), dark: (0.76, 0.73, 1.0))
    )
    static let body = CardTheme(
        primary: dynamic(light: (0.16, 0.75, 0.78), dark: (0.38, 0.86, 0.88)), // body teal
        secondary: dynamic(light: (0.35, 0.85, 0.88), dark: (0.52, 0.90, 0.92))
    )
    static let diet = CardTheme(
        primary: dynamic(light: (1.0, 0.6, 0.0), dark: (1.0, 0.70, 0.28)),     // diet orange
        secondary: dynamic(light: (1.0, 0.78, 0.32), dark: (1.0, 0.82, 0.48))
    )
    static let deficit = CardTheme(
        primary: dynamic(light: (0.0, 0.48, 1.0), dark: (0.38, 0.66, 1.0)),    // deficit blue
        secondary: dynamic(light: (0.35, 0.68, 1.0), dark: (0.55, 0.76, 1.0))
    )
}
