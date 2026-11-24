import AppKit
import SwiftUI

enum Theme {
    static let bg = Color(red: 0.07, green: 0.075, blue: 0.09)
    static let panel = Color(red: 0.10, green: 0.105, blue: 0.12)
    static let elevated = Color(red: 0.14, green: 0.15, blue: 0.17)
    static let border = Color(red: 0.26, green: 0.27, blue: 0.30)
    static let text = Color(red: 0.93, green: 0.93, blue: 0.91)
    static let muted = Color(red: 0.58, green: 0.59, blue: 0.62)
    static let amber = Color(red: 0.86, green: 0.62, blue: 0.28)
    static let amberBright = Color(red: 0.95, green: 0.76, blue: 0.42)
    static let green = Color(red: 0.45, green: 0.73, blue: 0.52)
    static let danger = Color(red: 0.86, green: 0.40, blue: 0.34)
    static let windowBackground = NSColor(srgbRed: 0.07, green: 0.075, blue: 0.09, alpha: 1)
}

struct ChronicleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, danger }

    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .foregroundStyle(foreground)
            .background(background.opacity(configuration.isPressed ? 0.75 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Color(red: 0.12, green: 0.09, blue: 0.04)
        case .secondary: return Theme.text
        case .danger: return Theme.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Theme.amber
        case .secondary: return Theme.elevated
        case .danger: return Color.clear
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: return Theme.amberBright
        case .secondary: return Theme.border
        case .danger: return Theme.danger.opacity(0.7)
        }
    }
}
