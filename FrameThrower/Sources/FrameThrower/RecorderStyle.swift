import SwiftUI

// A small shared palette keeps recording, sharing, and settings visually consistent.
enum RecorderStyle {
    static let accent = Color(red: 0.86, green: 0.24, blue: 0.18)
    static let green = Color(red: 0.22, green: 0.52, blue: 0.37)
}

struct RecorderCard: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(colorScheme == .dark ? Color(white: 0.14) : .white)
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 1)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.08 : 0.025), radius: 12, y: 4)
    }
}

struct RecordButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 48)
            .background(RecorderStyle.accent.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: RecorderStyle.accent.opacity(0.17), radius: 8, y: 3)
            .opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

