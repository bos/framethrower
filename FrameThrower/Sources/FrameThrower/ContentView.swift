import AppKit
import AVFoundation
import SwiftUI

private enum MicrophoneInputChoice: Hashable {
    case off, systemDefault, device(String)
}

struct ContentView: View {
    @ObservedObject var model: CaptureViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openWindow) private var openWindow
    @State private var recordingStartedAt: Date?
    @State private var clipDuration: Double?
    @State private var clipSize = ""
    @State private var previewEnabled = false
    @StateObject private var sourcePreviews = CaptureSourcePreviews()

    private var captureLocked: Bool { model.isRecording || model.isCountdownActive || model.isCaptureBusy }
    private var canRecord: Bool {
        guard !MediaProcessing.isSuspended else { return false }
        guard model.hasScreenRecordingPermission, !model.isAnyUploadActive, !model.isCaptureBusy, model.isCameraReadyForCapture else { return false }
        switch model.captureKind {
        case .window: return model.selectedWindow != nil
        case .display: return model.selectedDisplayID != nil
        case .area: return model.selectedDisplayID != nil && model.area.width >= 2 && model.area.height >= 2
        }
    }
    private var selectedPreviewSource: CapturePreviewSource? {
        guard model.hasScreenRecordingPermission else { return nil }
        if model.captureKind == .window {
            return model.selectedWindow.map(CapturePreviewSource.window)
        }
        guard let display = model.displays.first(where: { $0.id == model.selectedDisplayID }) else { return nil }
        return .display(id: display.id, frame: display.display.frame)
    }
    private var showRecording: Bool {
        (!model.recordingLibrary.entries.isEmpty || model.recordingLibrary.canUndoRemoval) && !model.isRecording
    }

    var body: some View {
        VStack(spacing: 0) {
            RecorderWorkspace {
                captureCard
            } recordingControls: {
                recordingSetup
            } recordings: {
                if showRecording { recordingSummary }
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 8)
            .padding(.bottom, 16)
            footer
        }
        .background(colorScheme == .dark ? Color(white: 0.105) : Color(red: 0.965, green: 0.960, blue: 0.949))
        .tint(RecorderStyle.accent)
        .frame(minWidth: 1000, minHeight: 780)
        .navigationTitle(model.nextRecordingName.displayName)
        .toolbar(removing: .title)
        .toolbar {
            recordingTitleToolbar
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.chooseProject() } label: { Label("Open Recording", systemImage: "folder") }
                    .labelStyle(.iconOnly)
                    .disabled(captureLocked || model.isAnyUploadActive)
                    .help("Open a recording project (⌘O)")
                SettingsLink { Label("Accounts", systemImage: "person.crop.circle") }
                    .labelStyle(.iconOnly)
                    .help("Manage Google Drive and Slack accounts")
            }
        }
        .onAppear {
            model.restoreLastProject()
            model.loadTokens()
            model.loadSlackTokens()
            model.loadAudioSettings()
            model.loadAreaSettings()
            model.refreshScreenRecordingPermissionState()
            model.startSourceAutoRefresh()
            Task { await model.refreshSources() }
        }
        .onChange(of: model.hasScreenRecordingPermission) { _, granted in
            if !granted { sourcePreviews.clear() }
        }
        .onChange(of: model.editorOpenRequest) { _, request in
            if let request { openWindow(id: "editor", value: request.url) }
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

    @ToolbarContentBuilder
    private var recordingTitleToolbar: some ToolbarContent {
        if #available(macOS 26, *) {
            ToolbarItem(placement: .principal) { recordingTitle }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { recordingTitle }
        }
    }

    private var recordingTitle: some View {
        NewRecordingTitleEditor(model: model)
            .frame(minWidth: 140, idealWidth: 240, maxWidth: 320, minHeight: 24, maxHeight: 24)
            .disabled(captureLocked)
    }

    private var captureCard: some View {
        VStack(spacing: 12) {
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

            if model.captureKind == .display && model.camera.selectedDeviceID == nil && model.hasScreenRecordingPermission {
                DisplayCarousel(model: model, isEnabled: previewEnabled, sourcePreviews: sourcePreviews) {
                    previewEnabled = true
                }
                .frame(minHeight: 300, idealHeight: 400, maxHeight: .infinity)
            } else if model.hasScreenRecordingPermission {
                CapturePreview(model: model,
                    isEnabled: previewEnabled || model.camera.selectedDeviceID != nil,
                    sourcePreviews: sourcePreviews)
                    .frame(minHeight: 300, idealHeight: 400, maxHeight: .infinity)
            }

            if model.hasScreenRecordingPermission {
                if model.captureKind != .display || model.camera.selectedDeviceID != nil {
                    sourceDetails
                        .disabled(captureLocked)
                }
            } else {
                permissionNotice.frame(maxHeight: .infinity)
            }

            Divider().opacity(0.6)
            inputControls
                .disabled(captureLocked)
            if model.camera.selectedDeviceID != nil || model.camera.errorMessage != nil {
                CameraSetupView(camera: model.camera, placement: $model.initialCameraPlacement, locked: captureLocked,
                    sourcePreviews: sourcePreviews, source: selectedPreviewSource,
                    area: model.captureKind == .area ? model.area.rect : nil)
            }
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
                Picker("Display", selection: $model.selectedDisplayID) {
                    ForEach(model.displays) { display in
                        Text(display.name).tag(Optional(display.id))
                    }
                }
                .labelsHidden()
                .disabled(model.displays.isEmpty)
                .help("Choose the display shown in the recording preview.")
            case .area:
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displays.first(where: { $0.id == model.selectedDisplayID })?.name ?? "Selected area")
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(Int(model.area.width)) × \(Int(model.area.height)) points")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .help("Drag the area outline to move or resize it. Choose… opens precise on-screen selection.")
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

    private var inputControls: some View {
        HStack(spacing: 14) {
            Picker("Microphone", selection: Binding<MicrophoneInputChoice>(get: {
                guard model.recordMicrophoneAudio else { return .off }
                return model.selectedMicrophoneID.map { .device($0) } ?? .systemDefault
            }, set: { choice in
                switch choice {
                case .off: model.recordMicrophoneAudio = false
                case .systemDefault:
                    model.selectedMicrophoneID = nil
                    model.recordMicrophoneAudio = true
                case let .device(id):
                    model.selectedMicrophoneID = id
                    model.recordMicrophoneAudio = true
                }
            })) {
                Text("Off").tag(MicrophoneInputChoice.off)
                Text("Default").tag(MicrophoneInputChoice.systemDefault)
                ForEach(model.microphones) { microphone in
                    Text(microphone.name).tag(MicrophoneInputChoice.device(microphone.id))
                }
                if let id = model.selectedMicrophoneID, !model.microphones.contains(where: { $0.id == id }) {
                    Text("Microphone unavailable").tag(MicrophoneInputChoice.device(id)).disabled(true)
                }
            }
            .tint(model.recordMicrophoneAudio ? RecorderStyle.accent : Color.secondary)
            .frame(minWidth: 150, maxWidth: .infinity)
            Toggle("System audio", isOn: $model.recordSystemAudio)
                .toggleStyle(.checkbox)
                .fixedSize()
                .help(model.recordSystemAudio ? "Record audio from apps" : "System audio is off")
            CameraInputPicker(camera: model.camera, locked: captureLocked,
                onSelectionChange: model.cameraSelectionWillChange)
                .frame(minWidth: 190, maxWidth: .infinity)
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .frame(height: 24)
    }

    private var recordingSetup: some View {
        CaptureRecordingSetup(quality: $model.recordingQuality, details: model.recordingDetails,
            status: recordingStatus, isRecording: model.isRecording, isLocked: captureLocked,
            recordingStartedAt: recordingStartedAt) { recordingControl }
    }

    @ViewBuilder
    private var recordingControl: some View {
        if model.isRecording {
            Button {
                Task { await model.stopRecording() }
            } label: {
                Label("Stop recording", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(RecordButtonStyle())
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(model.isCaptureBusy)
        } else if let remaining = model.countdownRemainingSeconds {
            Button {
                model.cancelRecordingCountdown()
            } label: {
                HStack(spacing: 10) {
                    Text("Cancel")
                    Text("\(remaining)s").monospacedDigit().opacity(0.7)
                }
                .frame(maxWidth: .infinity)
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
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
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

    private var recordingSummary: some View {
        RecordingLibraryView(library: model.recordingLibrary,
            isLocked: captureLocked || model.isAnyUploadActive,
            editorForURL: { try model.editor(for: $0) },
            onOpen: { model.openRecording(at: $0) },
            onShare: { model.selectRecordingForSharing(at: $0) },
            shareContent: { AnyView(recordingCard.frame(width: 560).padding(16)) })
    }

    private var recordingCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Button {
                    if model.projectEditor != nil { model.requestProjectEditor() }
                    else if !MediaProcessing.isSuspended, let url = model.lastRecordingURL { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "play.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(RecorderStyle.accent)
                        .frame(width: 42, height: 42)
                        .background(RecorderStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                }
                .buttonStyle(.plain)
                .disabled(MediaProcessing.isSuspended && model.projectEditor == nil)
                .help("Review and edit recording")
                .accessibilityLabel("Review and edit recording")
                VStack(alignment: .leading, spacing: 4) {
                    if let editor = model.projectEditor {
                        RecordingTitleEditor(editor: editor)
                            .frame(height: 24)
                    }
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

    private var recordingStatus: String? {
        if model.isCaptureBusy { return model.isRecording ? "Finishing recording…" : "Starting recording…" }
        if model.isRecording { return "Recording" }
        if MediaProcessing.isSuspended { return MediaProcessing.statusMessage }
        if let remaining = model.countdownRemainingSeconds { return "Recording starts in \(remaining)s" }
        if !model.hasScreenRecordingPermission { return "Screen recording permission required" }
        if model.camera.isPreparing { return "Starting camera…" }
        if !model.isCameraReadyForCapture { return "Camera unavailable" }
        if !canRecord {
            switch model.captureKind {
            case .window: return "Choose a window"
            case .display: return "Choose a display"
            case .area: return "Select a recording area"
            }
        }
        return nil
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
            if let footerMessage {
                if model.latestLogEntry?.level == .error {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(RecorderStyle.accent)
                }
                Text(footerMessage)
                    .lineLimit(1)
                    .foregroundStyle(model.latestLogEntry?.level == .error ? RecorderStyle.accent : .secondary)
            }
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

    private var footerMessage: String? {
        if model.latestLogEntry?.level == .error { return model.latestStatusLine }
        if model.isExporting { return "Rendering video…" }
        if model.isAnyUploadActive { return "Uploading… \(Int(model.uploadProgressFraction * 100))%" }
        return nil
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
        guard !MediaProcessing.isSuspended else { return }
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

/// Capture sizing stays independent of the number of saved recordings. The
/// record action has one stable position above the separately scrolling list.
struct RecorderWorkspace<Capture: View, Controls: View, Recordings: View>: View {
    private let capture: Capture
    private let recordingControls: Controls
    private let recordings: Recordings

    init(@ViewBuilder capture: () -> Capture,
         @ViewBuilder recordingControls: () -> Controls,
         @ViewBuilder recordings: () -> Recordings) {
        self.capture = capture()
        self.recordingControls = recordingControls()
        self.recordings = recordings()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            capture.frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 20) {
                recordingControls.fixedSize(horizontal: false, vertical: true)
                recordings.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: 280)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}
