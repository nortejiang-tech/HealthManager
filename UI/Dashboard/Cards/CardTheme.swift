import SwiftUI

/// Apple Health–style palette. Each metric family has a primary color and a
/// matching gradient used for chart fills and accent stripes.
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

    static let activity = CardTheme(
        primary: Color(red: 1.0, green: 0.18, blue: 0.33),     // activity red
        secondary: Color(red: 1.0, green: 0.45, blue: 0.4)
    )
    static let heart = CardTheme(
        primary: Color(red: 1.0, green: 0.35, blue: 0.55),     // heart pink
        secondary: Color(red: 1.0, green: 0.55, blue: 0.75)
    )
    static let sleep = CardTheme(
        primary: Color(red: 0.46, green: 0.43, blue: 0.95),    // sleep indigo
        secondary: Color(red: 0.66, green: 0.62, blue: 1.0)
    )
    static let body = CardTheme(
        primary: Color(red: 0.16, green: 0.75, blue: 0.78),    // body teal
        secondary: Color(red: 0.35, green: 0.85, blue: 0.88)
    )
    static let diet = CardTheme(
        primary: Color(red: 1.0, green: 0.6, blue: 0.0),       // diet orange
        secondary: Color(red: 1.0, green: 0.78, blue: 0.32)
    )
    static let deficit = CardTheme(
        primary: Color(red: 0.0, green: 0.48, blue: 1.0),      // deficit blue
        secondary: Color(red: 0.35, green: 0.68, blue: 1.0)
    )
}
