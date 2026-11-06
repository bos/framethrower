import SwiftUI

struct AccountsSettingsView: View {
    @ObservedObject var model: CaptureViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Accounts")
                .font(.system(size: 23, weight: .semibold))
                .tracking(-0.5)
            VStack(spacing: 0) {
                account(
                    "Google Drive", symbol: "externaldrive", color: RecorderStyle.green,
                    connected: model.isAuthorized
                ) {
                    if model.isAuthorized {
                        Button("Disconnect") { model.signOut() }
                    } else {
                        Button("Connect") { Task { await model.authorize() } }
                    }
                }
                Divider().padding(.leading, 64)
                account(
                    "Slack", symbol: "number", color: Color(red: 0.45, green: 0.30, blue: 0.53),
                    connected: model.isSlackAuthorized
                ) {
                    if model.isSlackAuthorized {
                        Button("Disconnect") { model.signOutSlack() }
                    } else {
                        Button("Connect") { Task { await model.connectSlack() } }
                    }
                }
            }
            .modifier(RecorderCard())
            if model.latestLogEntry?.level == .error {
                Text(model.latestStatusLine)
                    .font(.system(size: 11))
                    .foregroundStyle(RecorderStyle.accent)
                    .textSelection(.enabled)
            }
        }
        .padding(28)
        .frame(width: 490)
        .tint(RecorderStyle.accent)
        .onAppear {
            model.loadTokens()
            model.loadSlackTokens()
        }
    }

    private func account<Action: View>(
        _ name: String, symbol: String, color: Color, connected: Bool,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 36, height: 36)
                .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(name).font(.system(size: 13, weight: .semibold))
                    if connected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(RecorderStyle.green)
                            .accessibilityLabel("Connected")
                    }
                }
            }
            Spacer(minLength: 12)
            action().controlSize(.small)
        }
        .padding(18)
    }
}
