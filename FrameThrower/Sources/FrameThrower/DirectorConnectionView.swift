import SwiftUI

struct DirectorConnectionView: View {
    @ObservedObject var connections: DirectorConnections
    let isBusy: Bool
    var body: some View {
        if connections.showsChooser || connections.selected == nil {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if connections.isChecking {
                        HStack { ProgressView().controlSize(.small); Text("Checking connections…") }
                    }
                    ForEach(connections.available) { connection in
                        Button { connections.select(connection) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use \(connection.title)")
                                Text(connection.detail).font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(connections.isConnecting || connections.isChecking)
                        .help(connection.executable.map { "Uses the installed provider at \($0)." } ?? "Uses your connected ChatGPT account directly.")
                        .contextMenu {
                            if let accountID = connection.accountID {
                                Button("Sign in again") { connections.connectChatGPT(accountID: accountID) }
                            }
                        }
                    }
                    Divider()
                    Text("Instructions, editing context, and requested frames go to OpenAI. Usage counts against your eligible ChatGPT plan.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Continue with ChatGPT") { connections.connectChatGPT() }
                        .disabled(connections.isConnecting || connections.isChecking)
                        .accessibilityIdentifier("director.connect.chatgpt")
                    if connections.isConnecting {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Connecting…")
                            Button("Cancel") { connections.cancelConnection() }
                        }
                    }
                    if let error = connections.error {
                        Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    HStack {
                        Button("Check again") { connections.checkAgain() }
                            .disabled(connections.isChecking || connections.isConnecting)
                        if connections.selected != nil {
                            Button("Back") { connections.showsChooser = false }
                                .disabled(connections.isConnecting)
                        }
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: 240)
            .disabled(isBusy)
        } else if let selected = connections.selected {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selected.title).font(.callout)
                    Text(selected.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Change provider…") { connections.showsChooser = true }
                    .font(.callout).disabled(isBusy)
            }
        }
    }
}
