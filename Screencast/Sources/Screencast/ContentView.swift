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
            model.requestScreenRecordingPermission()
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
            Text("Record a window, display, or area and upload to Google Drive or Slack.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sourceSection: some View {
        GroupBox("Capture Source") {
            VStack(alignment: .leading, spacing: 12) {
                if model.hasScreenRecordingPermission {
                    Picker("Source", selection: $model.captureKind) {
                        ForEach(CaptureSourceKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                if model.captureKind == .window {
                    HStack(spacing: 12) {
                        Button("Pick Window…") {
                            Task { await model.selectWindow() }
                        }
                        if let selected = model.selectedWindow {
                            Text("Selected: \(selected.displayName)")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No window selected.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("Click a window to select it. Only on-screen windows are selectable.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Bring the window forward and click Refresh Sources if needed.")
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
                            Button("Select Area…") {
                                Task { await model.selectArea() }
                            }
                            Text(
                                "Selected: \(Int(model.area.width))×\(Int(model.area.height)) " +
                                "at \(Int(model.area.x)), \(Int(model.area.y))"
                            )
                            .foregroundStyle(.secondary)
                        }
                    }

                    HStack {
                        Button("Refresh Sources") {
                            Task { await model.refreshSources() }
                        }
                        Spacer()
                    }
                } else {
                    Text("Screen recording permission is required.")
                        .font(.headline)
                    Text(
                        "Open System Settings > Privacy & Security > Screen Recording, " +
                        "enable Screencast, then restart the app."
                    )
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var driveSection: some View {
        GroupBox("Google Drive") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if model.isAuthorized {
                        Text("Signed in")
                            .foregroundStyle(.green)
                        Button("Sign Out") {
                            model.signOut()
                        }
                    } else {
                        Button("Authorize") {
                            Task { await model.authorize() }
                        }
                        Text("Not signed in")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

            }
            .padding(.vertical, 4)
        }
    }

    private var slackSection: some View {
        GroupBox("Slack") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    if model.isSlackAuthorized {
                        Text("Connected")
                            .foregroundStyle(.green)
                        Button("Sign Out") {
                            model.signOutSlack()
                        }
                    } else {
                        Button("Connect Slack") {
                            Task { await model.connectSlack() }
                        }
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
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
                    .disabled(isEmpty)
                    .opacity(isEmpty ? 0.5 : 1.0)
                }

                if model.slackTargetKind == .person {
                    let isEmpty = model.slackUsers.isEmpty
                    Picker("Person", selection: $model.selectedSlackUserID) {
                        ForEach(model.slackUsers) { user in
                            Text(user.label).tag(Optional(user.id))
                        }
                    }
                    .disabled(isEmpty)
                    .opacity(isEmpty ? 0.5 : 1.0)
                }

            }
            .padding(.vertical, 4)
        }
    }

    private var controls: some View {
        HStack(spacing: 16) {
            Button {
                if model.isRecording {
                    Task { await model.stopRecording() }
                } else {
                    Task { await model.startRecording() }
                }
            } label: {
                if model.isRecording {
                    HStack(spacing: 6) {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(.primary)
                        Text("Stop Recording")
                            .foregroundStyle(.primary)
                    }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "record.circle.fill")
                            .foregroundStyle(.red)
                        Text("Start Recording")
                            .foregroundStyle(.primary)
                    }
                }
            }
            .disabled(!model.hasScreenRecordingPermission)

            Button("Upload to Google Drive") {
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
        VStack(alignment: .leading, spacing: 8) {
            Text("Status")
                .font(.headline)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.logs) { entry in
                            Text("\(timestamp(entry.date))  \(entry.message)")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(entry.level == .error ? .red : .primary)
                                .font(.caption)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 160)
                .background(Color(.textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: model.logs.count) { _, _ in
                    guard let last = model.logs.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
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

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
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
