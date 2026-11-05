import AppKit
import AVFoundation
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CaptureViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var recordingStartedAt: Date?
    @State private var clipDuration: Double?
    @State private var clipSize = ""
    @State private var previewEnabled = false

    private var captureLocked: Bool { model.isRecording || model.isCountdownActive }
    private var canRecord: Bool {
        guard model.hasScreenRecordingPermission else { return false }
        switch model.captureKind {
        case .window: return model.selectedWindow != nil
        case .display: return model.selectedDisplayID != nil
        case .area: return model.selectedDisplayID != nil && model.area.width >= 2 && model.area.height >= 2
        }
    }
    private var showRecording: Bool { model.hasRecordingToUpload && !model.isRecording }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 18) {
                        captureCard
                        if showRecording {
                            recordingCard.id("recording")
                        } else {
                            sharingHint
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .onChange(of: showRecording) { _, visible in
                    if visible {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo("recording", anchor: .bottom)
                        }
                    }
                }
            }
            recordingBar
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
            footer
        }
        .background(colorScheme == .dark ? Color(white: 0.105) : Color(red: 0.965, green: 0.960, blue: 0.949))
        .tint(RecorderStyle.accent)
        .frame(minWidth: 640, minHeight: 610)
        .onAppear {
            model.loadTokens()
            model.loadSlackTokens()
            model.loadAudioSettings()
            model.loadAreaSettings()
            model.refreshScreenRecordingPermissionState()
            model.startSourceAutoRefresh()
            Task { await model.refreshSources() }
        }
        .onDisappear { model.stopSourceAutoRefresh() }
        .onOpenURL { SlackCallbackRouter.shared.handle(url: $0) }
        .onChange(of: model.isRecording) { _, isRecording in
            recordingStartedAt = isRecording ? Date() : nil
        }
        .task(id: "\(model.lastRecordingURL?.path ?? ""):\(model.isRecording)") {
            await loadClipDetails()
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "viewfinder")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(RecorderStyle.accent)
                .frame(width: 38, height: 38)
                .background(RecorderStyle.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text("FrameThrower")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.6)
                Text("A little context goes a long way.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Label("Accounts", systemImage: "person.crop.circle")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.045), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Manage Google Drive and Slack accounts")
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 22)
    }

    private var captureCard: some View {
        VStack(spacing: 16) {
            HStack(spacing: 4) {
                ForEach(CaptureSourceKind.allCases) { kind in
                    Button {
                        model.captureKind = kind
                        previewEnabled = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: sourceIcon(kind))
                                .font(.system(size: 13, weight: .medium))
                            Text(kind.rawValue)
                                .font(.system(size: 12, weight: .medium))
                        }
                        .foregroundStyle(model.captureKind == kind ? Color.primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 36)
                        .background {
                            if model.captureKind == kind {
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(colorScheme == .dark ? Color(white: 0.25) : .white)
                                    .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Capture \(kind.rawValue.lowercased())")
                    .accessibilityAddTraits(model.captureKind == kind ? .isSelected : [])
                }
            }
            .padding(4)
            .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
            .disabled(captureLocked)

            if model.captureKind == .display && model.hasScreenRecordingPermission {
                DisplayCarousel(model: model, isEnabled: previewEnabled) {
                    previewEnabled = true
                }
            } else {
                CapturePreview(model: model, isEnabled: previewEnabled)
            }

            if model.hasScreenRecordingPermission {
                if model.captureKind != .display {
                    sourceDetails
                        .disabled(captureLocked)
                }
            } else {
                permissionNotice
            }

            Divider().opacity(0.6)
            audioControls
                .disabled(captureLocked)
        }
        .padding(18)
        .modifier(RecorderCard())
    }

    @ViewBuilder
    private var sourceDetails: some View {
        HStack(spacing: 12) {
            Image(systemName: sourceIcon(model.captureKind))
                .foregroundStyle(.secondary)
                .frame(width: 20)
            switch model.captureKind {
            case .window:
                Picker("Window", selection: Binding(
                    get: { model.selectedWindowID },
                    set: { model.selectedWindowID = $0; previewEnabled = true }
                )) {
                    if model.selectedWindowID == nil {
                        Text(model.windows.isEmpty ? "No windows available" : "Choose a window…")
                            .tag(Optional<CGWindowID>.none)
                    }
                    ForEach(model.windows) { window in
                        Text(window.displayName).tag(Optional(window.id))
                    }
                }
                .labelsHidden()
                .disabled(model.windows.isEmpty)
            case .display:
                EmptyView()
            case .area:
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displays.first(where: { $0.id == model.selectedDisplayID })?.name ?? "Selected area")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(Int(model.area.width)) × \(Int(model.area.height)) points")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("Drag to draw, move, or resize the area. Choose… for precise on-screen selection.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            if model.captureKind != .display {
                Button {
                    Task {
                        if model.captureKind == .window { await model.selectWindow() }
                        else { await model.selectArea() }
                        previewEnabled = true
                    }
                } label: {
                    Label("Choose…", systemImage: "scope")
                }
                .help("Choose \(model.captureKind.rawValue.lowercased()) on screen")
            }
        }
        .controlSize(.regular)
        .frame(minHeight: 30)
    }

    private var permissionNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.shield")
                .foregroundStyle(RecorderStyle.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow screen recording")
                    .font(.system(size: 12, weight: .semibold))
                Text("Enable FrameThrower in System Settings → Privacy & Security → Screen Recording, then reopen the app.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Allow Screen Recording…") {
                    if model.requestScreenRecordingPermission() {
                        Task { await model.refreshSources() }
                    }
                }
                .padding(.top, 4)
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
    }

    private var audioControls: some View {
        HStack(spacing: 16) {
            Toggle(isOn: $model.recordMicrophoneAudio) {
                Label("Microphone", systemImage: model.recordMicrophoneAudio ? "mic" : "mic.slash")
            }
            .help(model.recordMicrophoneAudio ? "Record microphone audio" : "Microphone is off")
            Toggle(isOn: $model.recordSystemAudio) {
                Label("System audio", systemImage: model.recordSystemAudio ? "speaker.wave.2" : "speaker.slash")
            }
            .help(model.recordSystemAudio ? "Record audio from apps" : "System audio is off")
            Spacer(minLength: 0)
            if model.recordMicrophoneAudio {
                Menu {
                    ForEach(model.microphones) { microphone in
                        Button {
                            model.selectedMicrophoneID = microphone.id
                        } label: {
                            if model.selectedMicrophoneID == microphone.id {
                                Label(microphone.name, systemImage: "checkmark")
                            } else { Text(microphone.name) }
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose microphone")
                .accessibilityLabel("Choose microphone")
            }
        }
        .font(.system(size: 11))
        .toggleStyle(.checkbox)
        .foregroundStyle(.secondary)
        .frame(minHeight: 20)
    }

    private var recordingBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    if model.isRecording {
                        Circle().fill(RecorderStyle.accent).frame(width: 6, height: 6)
                    }
                    Text(recordingHeading)
                        .font(.system(size: 14, weight: .medium))
                }
                if let started = recordingStartedAt, model.isRecording {
                    Text(started, style: .timer)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                } else {
                    Text(recordingHint)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            recordingControl
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var recordingControl: some View {
        if model.isRecording {
            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop recording", systemImage: "stop.fill")
                    .frame(width: 150)
            }
            .buttonStyle(RecordButtonStyle())
            .keyboardShortcut("r", modifiers: [.command])
        } else if let remaining = model.countdownRemainingSeconds {
            Button {
                model.cancelRecordingCountdown()
            } label: {
                HStack(spacing: 10) {
                    Text("Cancel")
                    Text("\(remaining)s").monospacedDigit().opacity(0.7)
                }
                .frame(width: 150)
            }
            .buttonStyle(RecordButtonStyle())
        } else {
            HStack(spacing: 0) {
                Button {
                    Task { await model.startRecording() }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "record.circle")
                        Text("Record")
                        Text("⌘R")
                            .font(.system(size: 11))
                            .opacity(0.55)
                    }
                    .frame(width: 140, height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: [.command])
                Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 18)
                Menu {
                    Button("Start in 5 seconds") { Task { await model.startRecordingAfterDelay(seconds: 5) } }
                    Button("Start in 10 seconds") { Task { await model.startRecordingAfterDelay(seconds: 10) } }
                } label: {
                    Image(systemName: "chevron.down")
                        .renderingMode(.original)
                        .foregroundStyle(.white)
                        .accessibilityLabel("Delayed recording")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 37, height: 48)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.white)
                .fixedSize()
                .accessibilityLabel("Delayed recording")
                .help("Start after a countdown")
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .background(RecorderStyle.accent.gradient)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: RecorderStyle.accent.opacity(0.17), radius: 8, y: 3)
            .opacity(canRecord ? 1 : 0.4)
            .disabled(!canRecord)
        }
    }

    private var sharingHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.right.square")
            Text("A clip worth sharing? Send it to Slack or Drive when you're done.")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    if let url = model.lastRecordingURL { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(RecorderStyle.accent)
                        .frame(width: 42, height: 42)
                        .background(RecorderStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .help("Play recording")
                .accessibilityLabel("Play recording")
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your recording")
                        .font(.system(size: 13, weight: .semibold))
                    Text(clipSummary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let url = model.lastRecordingURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            Divider().opacity(0.6)
            driveShareRow
            Divider().opacity(0.4)
            slackShareRow
            if model.isUploadProgressVisible {
                HStack(spacing: 10) {
                    ProgressView(value: model.uploadProgressFraction)
                        .progressViewStyle(.linear)
                    Text("\(Int(model.uploadProgressFraction * 100))%")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .modifier(RecorderCard())
    }

    private var driveShareRow: some View {
        HStack(spacing: 12) {
            destinationIcon("externaldrive", color: RecorderStyle.green)
            VStack(alignment: .leading, spacing: 3) {
                Text("Google Drive").font(.system(size: 12, weight: .medium))
                Text(model.isAuthorized ? "Upload a private copy" : "Connect your account to share")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            if let _ = model.lastDriveFileURL {
                Button("Copy link") { model.copyLastDriveURLToPasteboard() }
                    .controlSize(.small)
            }
            if model.isAuthorized {
                Button(model.isUploading ? "Uploading…" : "Upload") {
                    Task { await model.uploadLastRecording() }
                }
                .disabled(model.isAnyUploadActive || captureLocked)
                .controlSize(.small)
            } else {
                SettingsLink { Text("Connect") }.controlSize(.small)
            }
        }
    }

    private var slackShareRow: some View {
        HStack(spacing: 12) {
            destinationIcon("number", color: Color(red: 0.45, green: 0.30, blue: 0.53))
            VStack(alignment: .leading, spacing: 4) {
                Text("Slack").font(.system(size: 12, weight: .medium))
                if model.isSlackAuthorized {
                    HStack(spacing: 6) {
                        Picker("Slack destination", selection: $model.slackTargetKind) {
                            ForEach(SlackTargetKind.allCases) { kind in Text(kind.rawValue).tag(kind) }
                        }
                        .labelsHidden()
                        .frame(width: 82)
                        if model.slackTargetKind == .person {
                            Picker("Person", selection: $model.selectedSlackUserID) {
                                if model.slackUsers.isEmpty { Text("No people").tag(Optional<String>.none) }
                                ForEach(model.slackUsers) { user in Text(user.label).tag(Optional(user.id)) }
                            }
                            .labelsHidden()
                        } else {
                            Picker("Channel", selection: $model.selectedSlackChannelID) {
                                if model.slackChannels.isEmpty { Text("No channels").tag(Optional<String>.none) }
                                ForEach(model.slackChannels) { channel in
                                    Text("\(channel.isPrivate ? "🔒 " : "")#\(channel.name)").tag(Optional(channel.id))
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    .controlSize(.small)
                    .disabled(model.isAnyUploadActive || captureLocked)
                } else {
                    Text("Connect your workspace to share").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if let _ = model.lastSlackFileURL {
                Button("Copy link") { model.copyLastSlackURLToPasteboard() }.controlSize(.small)
            }
            if model.isSlackAuthorized {
                Button(model.isSlackUploading ? "Sending…" : "Send") {
                    Task { await model.uploadLastRecordingToSlack() }
                }
                .disabled(model.isAnyUploadActive || captureLocked || !hasSlackTarget)
                .controlSize(.small)
            } else {
                SettingsLink { Text("Connect") }.controlSize(.small)
            }
        }
    }

    private var hasSlackTarget: Bool {
        model.slackTargetKind == .person ? model.selectedSlackUserID != nil : model.selectedSlackChannelID != nil
    }

    private var recordingHeading: String {
        if model.isRecording { return "Recording" }
        if model.isCountdownActive { return "Get ready…" }
        if !model.hasScreenRecordingPermission { return "One quick setup." }
        return canRecord ? "Ready when you are." : "Choose your capture."
    }

    private var recordingHint: String {
        if model.isCountdownActive { return "Your recording will start automatically." }
        if !model.hasScreenRecordingPermission { return "Allow screen recording to get started." }
        if !canRecord { return "Pick a window or switch to a display or area." }
        return "⌘R to record. Use the arrow for a countdown."
    }

    private func destinationIcon(_ name: String, color: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(color)
            .frame(width: 32, height: 32)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Image(systemName: model.latestLogEntry?.level == .error ? "exclamationmark.circle" : "lock")
                .foregroundStyle(model.latestLogEntry?.level == .error ? RecorderStyle.accent : .secondary)
            Text(footerMessage)
                .lineLimit(1)
                .foregroundStyle(model.latestLogEntry?.level == .error ? RecorderStyle.accent : .secondary)
            Spacer(minLength: 8)
            Button {
                model.isLogExpanded.toggle()
            } label: {
                Label("Activity", systemImage: "list.bullet")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("l", modifiers: [.command])
            .popover(isPresented: $model.isLogExpanded, arrowEdge: .top) { activityLog }
        }
        .font(.system(size: 10))
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.primary.opacity(0.025))
    }

    private var footerMessage: String {
        if model.latestLogEntry?.level == .error { return model.latestStatusLine }
        if model.isAnyUploadActive { return "Uploading your recording…" }
        return "Local by default. Yours to share."
    }

    private var activityLog: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Activity").font(.headline)
                Spacer()
                Button("Copy log") { model.copyLogsToPasteboard() }.disabled(model.logs.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if model.logs.isEmpty { Text("No activity yet.").foregroundStyle(.secondary) }
                        ForEach(model.logs) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(entry.date, style: .time)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                    .frame(width: 75, alignment: .leading)
                                Text(linkedMessage(entry.message))
                                    .foregroundStyle(entry.level == .error ? RecorderStyle.accent : .primary)
                            }
                            .font(.system(size: 11))
                            .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .onAppear { if let last = model.logs.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                .onChange(of: model.logs.count) { _, _ in
                    if let last = model.logs.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 300)
    }

    private var clipSummary: String {
        var parts = ["Saved to Movies"]
        if let duration = clipDuration, duration.isFinite {
            let seconds = Int(duration)
            parts.append(String(format: "%d:%02d", seconds / 60, seconds % 60))
        }
        if !clipSize.isEmpty { parts.append(clipSize) }
        return parts.joined(separator: "  ·  ")
    }

    private func linkedMessage(_ message: String) -> AttributedString {
        var attributed = AttributedString(message)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return attributed
        }
        for match in detector.matches(in: message, range: NSRange(message.startIndex..., in: message)) {
            if let url = match.url,
               let stringRange = Range(match.range, in: message),
               let range = Range(stringRange, in: attributed) {
                attributed[range][AttributeScopes.FoundationAttributes.LinkAttribute.self] = url
            }
        }
        return attributed
    }

    @MainActor
    private func loadClipDetails() async {
        guard !model.isRecording, let url = model.lastRecordingURL else { return }
        clipDuration = nil
        clipSize = ""
        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let bytes = attributes[.size] as? Int64 {
            clipSize = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        if let duration = try? await AVURLAsset(url: url).load(.duration) {
            guard !Task.isCancelled else { return }
            clipDuration = duration.seconds
        }
    }

    private func sourceIcon(_ kind: CaptureSourceKind) -> String {
        switch kind {
        case .window: "macwindow"
        case .display: "display"
        case .area: "viewfinder"
        }
    }
}
