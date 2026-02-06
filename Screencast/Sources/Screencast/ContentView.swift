import SwiftUI

struct ContentView: View {
    @StateObject private var model = CaptureViewModel()

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            sourceSection
            Divider()
            driveSection
            Divider()
            slackSection
            Divider()
            controls
            status
            versionLabel
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 560)
        .onAppear {
            model.loadTokens()
            model.loadSlackTokens()
            Task { await model.refreshSources() }
        }
        .onOpenURL { url in
            SlackCallbackRouter.shared.handle(url: url)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Screencast")
                .font(.largeTitle.bold())
            Text("Record a window, display, or area and upload to Google Drive.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceSection: some View {
        GroupBox("Capture Source") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Source", selection: $model.captureKind) {
                    ForEach(CaptureSourceKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                if model.captureKind == .window {
                    Picker("Window", selection: $model.selectedWindowID) {
                        ForEach(model.windows) { window in
                            Text(window.displayName)
                                .tag(Optional(window.id))
                        }
                    }
                    Text("Only on-screen windows are shown. Bring the window forward and")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("click Refresh Sources if you do not see it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if model.captureKind == .display || model.captureKind == .area {
                    Picker("Display", selection: $model.selectedDisplayID) {
                        ForEach(model.displays) { display in
                            Text(display.name).tag(Optional(display.id))
                        }
                    }
                }

                if model.captureKind == .area {
                    HStack(spacing: 12) {
                        LabeledField(title: "X", value: $model.area.x)
                        LabeledField(title: "Y", value: $model.area.y)
                        LabeledField(title: "Width", value: $model.area.width)
                        LabeledField(title: "Height", value: $model.area.height)
                    }
                }

                HStack {
                    Button("Refresh Sources") {
                        Task { await model.refreshSources() }
                    }
                    Spacer()
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var driveSection: some View {
        GroupBox("Google Drive") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button(model.isAuthorized ? "Re-authorize" : "Authorize") {
                        Task { await model.authorize() }
                    }

                    Button("Sign Out") {
                        model.signOut()
                    }
                    .disabled(!model.isAuthorized)

                    Spacer()
                    Text(model.isAuthorized ? "Signed in" : "Not signed in")
                        .foregroundStyle(model.isAuthorized ? .green : .secondary)
                }

            }
            .padding(.vertical, 4)
        }
    }

    private var slackSection: some View {
        GroupBox("Slack") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Button(model.isSlackAuthorized ? "Reconnect" : "Connect Slack") {
                        Task { await model.connectSlack() }
                    }

                    Button("Sign Out") {
                        model.signOutSlack()
                    }
                    .disabled(!model.isSlackAuthorized)

                    Button("Refresh Targets") {
                        Task { await model.refreshSlackTargets() }
                    }
                    .disabled(!model.isSlackAuthorized)

                    Spacer()
                    Text(model.isSlackAuthorized ? "Connected" : "Not connected")
                        .foregroundStyle(model.isSlackAuthorized ? .green : .secondary)
                }

                Picker("Target", selection: $model.slackTargetKind) {
                    ForEach(SlackTargetKind.allCases) { kind in
                        Text(kind.rawValue).tag(kind)
                    }
                }
                .pickerStyle(.segmented)

                if model.slackTargetKind == .channel {
                    let isEmpty = model.slackChannels.isEmpty
                    Picker("Channel", selection: $model.selectedSlackChannelID) {
                        ForEach(model.slackChannels) { channel in
                            let label = channel.isPrivate
                                ? "[private] #\(channel.name)"
                                : "#\(channel.name)"
                            Text(label).tag(Optional(channel.id))
                        }
                    }
                    .disabled(isEmpty || model.isSlackRefreshing)
                    .opacity(isEmpty || model.isSlackRefreshing ? 0.5 : 1.0)
                }

                if model.slackTargetKind == .person {
                    let isEmpty = model.slackUsers.isEmpty
                    Picker("Person", selection: $model.selectedSlackUserID) {
                        ForEach(model.slackUsers) { user in
                            Text(user.label).tag(Optional(user.id))
                        }
                    }
                    .disabled(isEmpty || model.isSlackRefreshing)
                    .opacity(isEmpty || model.isSlackRefreshing ? 0.5 : 1.0)
                }

            }
            .padding(.vertical, 4)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button(model.isRecording ? "Recording…" : "Start Recording") {
                Task { await model.startRecording() }
            }
            .disabled(model.isRecording)

            Button("Stop Recording") {
                Task { await model.stopRecording() }
            }
            .disabled(!model.isRecording)

            Button("Upload Last Recording") {
                Task { await model.uploadLastRecording() }
            }
            .disabled(model.isUploading || !model.isAuthorized)

            Button("Upload to Slack") {
                Task { await model.uploadLastRecordingToSlack() }
            }
            .disabled(model.isSlackUploading || !model.isSlackAuthorized)

            Spacer()
        }
    }

    private var status: some View {
        Text(model.statusMessage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.secondary)
            .lineLimit(2)
    }

    private var versionLabel: some View {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? "0"

        return Text("Version \(version) (Build \(build))")
            .frame(maxWidth: .infinity, alignment: .leading)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct LabeledField: View {
    let title: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: $value, format: .number)
                .frame(width: 120)
                .textFieldStyle(.roundedBorder)
        }
    }
}
