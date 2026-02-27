import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: CaptureViewModel
    @State private var delayedStartAnchorView: NSView?
    @State private var delayedStartMenuHandler: DelayedStartMenuActionHandler?

    private static let recordingControlWidth: CGFloat = 240
    private static let recordingControlHeight: CGFloat = 36
    private static let delayedStartCaretWidth: CGFloat = 40
    private static let maxContentWidth: CGFloat = 860
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    var body: some View {
        VStack(spacing: 14) {
            captureCard
            destinationCard
            actionRow
                .zIndex(20)
            if model.isUploadProgressVisible {
                uploadProgressRow
            }
            statusSection
        }
        .padding(16)
        .frame(maxWidth: Self.maxContentWidth, alignment: .leading)
        .frame(minWidth: 740, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            model.loadTokens()
            model.loadSlackTokens()
            model.loadAudioSettings()
            model.loadAreaSettings()
            _ = model.requestScreenRecordingPermission()
            model.startSourceAutoRefresh()
            Task { await model.refreshSources() }
        }
        .onDisappear {
            model.stopSourceAutoRefresh()
        }
        .onOpenURL { url in
            SlackCallbackRouter.shared.handle(url: url)
        }
    }

    private var captureCard: some View {
        GroupBox("Capture") {
            VStack(alignment: .leading, spacing: 10) {
                if model.hasScreenRecordingPermission {
                    HStack(alignment: .top, spacing: 12) {
                        Picker("Source", selection: $model.captureKind) {
                            ForEach(CaptureSourceKind.allCases) { kind in
                                Text(kind.rawValue).tag(kind)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(maxWidth: 340)

                        Spacer(minLength: 0)

                        audioMenu
                    }

                    sourceDetails
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen recording permission is required.")
                            .font(.headline)
                        Text(
                            "Enable Screencast in System Settings > Privacy & Security > " +
                            "Screen Recording, then restart the app."
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var sourceDetails: some View {
        switch model.captureKind {
        case .window:
            HStack(spacing: 10) {
                Button("Pick Window…") {
                    Task { await model.selectWindow() }
                }

                Picker("Window", selection: $model.selectedWindowID) {
                    ForEach(model.windows) { window in
                        Text(window.displayName).tag(Optional(window.id))
                    }
                }
                .disabled(model.windows.isEmpty)
            }

        case .display:
            Picker("Display", selection: $model.selectedDisplayID) {
                ForEach(model.displays) { display in
                    Text(display.name).tag(Optional(display.id))
                }
            }

        case .area:
            HStack(spacing: 10) {
                Button("Select Area…") {
                    Task { await model.selectArea() }
                }
                Text(areaSelectionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var areaSelectionSummary: String {
        "Selected: \(Int(model.area.width))×\(Int(model.area.height)) at " +
        "\(Int(model.area.x)), \(Int(model.area.y))"
    }

    private var audioMenu: some View {
        Menu {
            Toggle("Record system audio", isOn: $model.recordSystemAudio)
            Toggle("Record microphone", isOn: $model.recordMicrophoneAudio)

            if model.recordMicrophoneAudio {
                Divider()
                if model.microphones.isEmpty {
                    Text("No microphone devices found.")
                } else {
                    Menu("Microphone: \(selectedMicrophoneName)") {
                        ForEach(model.microphones) { microphone in
                            Button {
                                model.selectedMicrophoneID = microphone.id
                            } label: {
                                if model.selectedMicrophoneID == microphone.id {
                                    Label(microphone.name, systemImage: "checkmark")
                                } else {
                                    Text(microphone.name)
                                }
                            }
                        }
                    }
                }
                if !model.hasMicrophonePermission {
                    Divider()
                    Text("Microphone permission is not granted.")
                }
            }
        } label: {
            Label(audioMenuTitle, systemImage: "waveform")
        }
        .help("Audio capture options")
    }

    private var audioMenuTitle: String {
        switch (model.recordSystemAudio, model.recordMicrophoneAudio) {
        case (false, false):
            return "Audio"
        case (true, false):
            return "Audio (System)"
        case (false, true):
            return "Audio (Mic)"
        case (true, true):
            return "Audio (System, Mic)"
        }
    }

    private var selectedMicrophoneName: String {
        if let selectedID = model.selectedMicrophoneID,
           let selected = model.microphones.first(where: { $0.id == selectedID }) {
            return selected.name
        }
        return "System Default"
    }

    private var destinationCard: some View {
        GroupBox("Destination") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    HStack(spacing: 8) {
                        Text("Google Drive")
                            .foregroundStyle(.secondary)
                        StatusChip(
                            text: model.driveAccountStatusText,
                            tone: model.isAuthorized ? .good : .warning
                        )
                    }

                    HStack(spacing: 8) {
                        Text("Slack")
                            .foregroundStyle(.secondary)
                        StatusChip(
                            text: model.slackAccountStatusText,
                            tone: model.isSlackAuthorized ? .good : .warning
                        )
                    }

                    Spacer(minLength: 0)

                    Button("Manage Accounts…") {
                        openSettingsWindow()
                    }
                }

                HStack(spacing: 10) {
                    Picker("Slack Target", selection: $model.slackTargetKind) {
                        ForEach(SlackTargetKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 220)
                    .disabled(!model.isSlackAuthorized)
                    .opacity(model.isSlackAuthorized ? 1.0 : 0.6)

                    if model.slackTargetKind == .channel {
                        let isEmpty = model.slackChannels.isEmpty || !model.isSlackAuthorized
                        Picker("Channel", selection: $model.selectedSlackChannelID) {
                            ForEach(model.slackChannels) { channel in
                                let label = channel.isPrivate
                                    ? "[private] #\(channel.name)"
                                    : "#\(channel.name)"
                                Text(label).tag(Optional(channel.id))
                            }
                        }
                        .disabled(isEmpty)
                        .opacity(isEmpty ? 0.6 : 1.0)
                    } else {
                        let isEmpty = model.slackUsers.isEmpty || !model.isSlackAuthorized
                        Picker("Person", selection: $model.selectedSlackUserID) {
                            ForEach(model.slackUsers) { user in
                                Text(user.label).tag(Optional(user.id))
                            }
                        }
                        .disabled(isEmpty)
                        .opacity(isEmpty ? 0.6 : 1.0)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            recordingControl

            Divider()
                .frame(height: 24)

            Button("Upload to Google Drive") {
                Task { await model.uploadLastRecording() }
            }
            .disabled(model.isUploading || !model.isAuthorized || !model.hasRecordingToUpload)

            Button("Upload to Slack") {
                Task { await model.uploadLastRecordingToSlack() }
            }
            .disabled(
                model.isSlackUploading || !model.isSlackAuthorized || !model.hasRecordingToUpload
            )

            Button("Copy Drive URL") {
                model.copyLastDriveURLToPasteboard()
            }
            .disabled(model.lastDriveFileURL == nil)

            Button("Copy Slack URL") {
                model.copyLastSlackURLToPasteboard()
            }
            .disabled(model.lastSlackFileURL == nil)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var recordingControl: some View {
        if model.isRecording {
            recordingActionButton(
                iconSystemName: "stop.fill",
                iconColor: .primary,
                title: "Stop Recording",
                useMonospacedDigits: false,
                isDisabled: !model.hasScreenRecordingPermission,
                shortcut: "r"
            ) {
                Task { await model.stopRecording() }
            }
        } else if let remaining = model.countdownRemainingSeconds {
            recordingActionButton(
                iconSystemName: "hourglass",
                iconColor: .primary,
                title: "Starting in \(remaining)s...",
                useMonospacedDigits: true,
                isDisabled: !model.hasScreenRecordingPermission,
                shortcut: nil
            ) {
                model.cancelRecordingCountdown()
            }
        } else {
            delayedStartControl
        }
    }

    private func recordingActionButton(
        iconSystemName: String,
        iconColor: Color,
        title: String,
        useMonospacedDigits: Bool,
        isDisabled: Bool,
        shortcut: Character?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: iconSystemName)
                    .foregroundStyle(iconColor)
                Text(title)
                    .lineLimit(1)
                    .applyIf(useMonospacedDigits) { view in
                        view.monospacedDigit()
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .applyIf(shortcut != nil) { view in
            view.keyboardShortcut(KeyEquivalent(shortcut!), modifiers: [.command])
        }
        .frame(width: Self.recordingControlWidth, height: Self.recordingControlHeight)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.32), lineWidth: 1)
        )
        .opacity(isDisabled ? 0.55 : 1.0)
        .allowsHitTesting(!isDisabled)
    }

    private var delayedStartControl: some View {
        let isDisabled = !model.hasScreenRecordingPermission || model.isCountdownActive

        return HStack(spacing: 0) {
            Button {
                Task { await model.startRecording() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                    Text("Start Recording")
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("r", modifiers: [.command])
            .disabled(isDisabled)

            Rectangle()
                .fill(Color.secondary.opacity(0.28))
                .frame(width: 1, height: 20)

            Button {
                showDelayedStartMenu()
            } label: {
                Image(systemName: "chevron.down")
                    .frame(
                        width: Self.delayedStartCaretWidth,
                        height: Self.recordingControlHeight
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.32), lineWidth: 1)
        )
        .opacity(isDisabled ? 0.55 : 1.0)
        .frame(width: Self.recordingControlWidth, height: Self.recordingControlHeight)
        .background(
            DelayedStartAnchorReader { anchor in
                delayedStartAnchorView = anchor
            }
        )
    }

    private func showDelayedStartMenu() {
        guard let anchorView = delayedStartAnchorView else { return }
        let handler = DelayedStartMenuActionHandler(
            startInFive: {
                Task { await model.startRecordingAfterDelay(seconds: 5) }
            },
            startInTen: {
                Task { await model.startRecordingAfterDelay(seconds: 10) }
            }
        )
        delayedStartMenuHandler = handler

        let menu = NSMenu()
        let startInFive = NSMenuItem(
            title: "Start in 5 Seconds",
            action: #selector(DelayedStartMenuActionHandler.startInFiveAction),
            keyEquivalent: ""
        )
        startInFive.target = handler

        let startInTen = NSMenuItem(
            title: "Start in 10 Seconds",
            action: #selector(DelayedStartMenuActionHandler.startInTenAction),
            keyEquivalent: ""
        )
        startInTen.target = handler

        menu.addItem(startInFive)
        menu.addItem(startInTen)
        let menuOrigin = NSPoint(x: Self.recordingControlWidth - Self.delayedStartCaretWidth, y: 0)
        menu.popUp(positioning: nil, at: menuOrigin, in: anchorView)
        delayedStartMenuHandler = nil
    }

    private func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Status")
                    .font(.headline)

                if let latest = model.latestLogEntry {
                    Text(timestamp(latest.date))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Text(model.latestStatusLine)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(statusTextColor)

                Spacer(minLength: 0)

                Button(model.isLogExpanded ? "Hide Log" : "Show Log") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        model.isLogExpanded.toggle()
                    }
                }
                .keyboardShortcut("l", modifiers: [.command])

                if model.isLogExpanded {
                    Button("Copy Log") {
                        model.copyLogsToPasteboard()
                    }
                    .disabled(model.logs.isEmpty)
                }
            }

            if model.isLogExpanded {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(model.logs) { entry in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(timestamp(entry.date))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                    Text(linkedMessage(entry.message))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(entry.level == .error ? .red : .primary)
                                .font(.caption)
                                .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, minHeight: 110, maxHeight: 160)
                    .background(Color(.textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .textSelection(.enabled)
                    .onChange(of: model.logs.count) { _, _ in
                        guard let last = model.logs.last else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
    }

    private var uploadProgressRow: some View {
        HStack(spacing: 10) {
            let percent = Int((model.uploadProgressFraction * 100).rounded())
            Text("Uploading")
                .font(.caption)
                .foregroundStyle(.secondary)
            ProgressView(value: model.uploadProgressFraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: .infinity)
            Text("\(percent)%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var statusTextColor: Color {
        if model.latestLogEntry?.level == .error {
            return .red
        }
        return .primary
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private func linkedMessage(_ message: String) -> AttributedString {
        let markdown = markdownLinkedMessage(message)
        if let attributed = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(
                interpretedSyntax: .inlineOnlyPreservingWhitespace
            )
        ) {
            return attributed
        }
        return AttributedString(message)
    }

    private func markdownLinkedMessage(_ message: String) -> String {
        guard let detector = Self.linkDetector else {
            return escapeMarkdown(message)
        }
        let fullRange = NSRange(message.startIndex..<message.endIndex, in: message)
        let matches = detector.matches(in: message, options: [], range: fullRange)
        guard !matches.isEmpty else {
            return escapeMarkdown(message)
        }

        var result = ""
        var cursor = message.startIndex
        for match in matches {
            guard let url = match.url, let range = Range(match.range, in: message) else {
                continue
            }
            if cursor < range.lowerBound {
                result += escapeMarkdown(String(message[cursor..<range.lowerBound]))
            }
            let label = escapeMarkdown(String(message[range]))
            result += "[\(label)](\(url.absoluteString))"
            cursor = range.upperBound
        }
        if cursor < message.endIndex {
            result += escapeMarkdown(String(message[cursor...]))
        }
        return result
    }

    private func escapeMarkdown(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
    }
}

private extension View {
    @ViewBuilder
    func applyIf<Transformed: View>(
        _ condition: Bool,
        transform: (Self) -> Transformed
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

private struct DelayedStartAnchorReader: NSViewRepresentable {
    let onResolve: (NSView) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            onResolve(view)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            onResolve(nsView)
        }
    }
}

@MainActor
private final class DelayedStartMenuActionHandler: NSObject {
    private let startInFive: () -> Void
    private let startInTen: () -> Void

    init(startInFive: @escaping () -> Void, startInTen: @escaping () -> Void) {
        self.startInFive = startInFive
        self.startInTen = startInTen
    }

    @objc
    func startInFiveAction() {
        startInFive()
    }

    @objc
    func startInTenAction() {
        startInTen()
    }
}
