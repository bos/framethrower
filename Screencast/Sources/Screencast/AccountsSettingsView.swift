import SwiftUI

struct AccountsSettingsView: View {
    @ObservedObject var model: CaptureViewModel

    var body: some View {
        Form {
            Section("Google Drive") {
                HStack(spacing: 10) {
                    Text("Status")
                        .foregroundStyle(.secondary)
                    StatusChip(
                        text: model.driveAccountStatusText,
                        tone: model.isAuthorized ? .good : .warning
                    )
                }

                HStack(spacing: 10) {
                    if model.isAuthorized {
                        Button("Sign Out") {
                            model.signOut()
                        }
                    } else {
                        Button("Connect Google Drive") {
                            Task { await model.authorize() }
                        }
                    }
                }
            }

            Section("Slack") {
                HStack(spacing: 10) {
                    Text("Status")
                        .foregroundStyle(.secondary)
                    StatusChip(
                        text: model.slackAccountStatusText,
                        tone: model.isSlackAuthorized ? .good : .warning
                    )
                }

                Text(model.slackAccountDetailText)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    if model.isSlackAuthorized {
                        Button("Sign Out") {
                            model.signOutSlack()
                        }
                    } else {
                        Button("Connect Slack") {
                            Task { await model.connectSlack() }
                        }
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 460, minHeight: 260)
        .onAppear {
            model.loadTokens()
            model.loadSlackTokens()
        }
    }
}
