import SwiftUI

struct StatusChip: View {
    enum Tone {
        case good
        case warning
        case neutral
    }

    let text: String
    let tone: Tone

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(backgroundColor)
            )
            .accessibilityLabel("Status: \(text)")
    }

    private var backgroundColor: Color {
        switch tone {
        case .good:
            Color.green.opacity(0.15)
        case .warning:
            Color.orange.opacity(0.18)
        case .neutral:
            Color.secondary.opacity(0.15)
        }
    }

    private var foregroundColor: Color {
        switch tone {
        case .good:
            .green
        case .warning:
            .orange
        case .neutral:
            .secondary
        }
    }
}
