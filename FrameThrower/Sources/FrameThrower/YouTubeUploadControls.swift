import SwiftUI

struct YouTubeUploadControls: View {
    @ObservedObject var model: CaptureViewModel
    var isLocked: Bool
    @State private var isExpanded = false
    @State private var metadata = YouTubeUploadMetadata(title: "")

    private var locked: Bool { isLocked || model.isAnyUploadActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(.red)
                    .frame(width: 30, height: 30)
                Text("YouTube").font(.system(size: 12, weight: .medium))
                Spacer()
                if let url = model.lastYouTubeURL {
                    Link("Open", destination: url).controlSize(.small)
                    Button("Copy link") { model.copyLastYouTubeURLToPasteboard() }.controlSize(.small)
                }
                if model.isYouTubeAuthorized {
                    Button(isExpanded ? "Hide options" : "Upload…") { isExpanded.toggle() }
                        .controlSize(.small).disabled(locked)
                } else {
                    SettingsLink { Text("Connect") }.controlSize(.small)
                }
            }
            if let message = model.youTubeUploadError {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).textSelection(.enabled)
            }
            if isExpanded && model.isYouTubeAuthorized {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Title", text: $metadata.title)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("YouTube title")
                    TextField("Description (optional)", text: $metadata.description, axis: .vertical)
                        .lineLimit(2...4)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("YouTube description")
                    HStack {
                        Picker("Visibility", selection: $metadata.visibility) {
                            ForEach(YouTubeUploadMetadata.Visibility.allCases) { visibility in
                                Text(visibility.title).tag(visibility)
                            }
                        }
                        .help("Private: only selected viewers. Unlisted: anyone with the link. Public: anyone.")
                        Picker("Made for kids", selection: $metadata.madeForKids) {
                            Text("Choose…").tag(Optional<Bool>.none)
                            Text("Yes").tag(Optional(true))
                            Text("No").tag(Optional(false))
                        }
                    }
                }
                .controlSize(.small)
                .disabled(locked)
                HStack {
                    if let message = metadata.validationMessage {
                        Text(message).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button(model.isYouTubeUploading ? "Uploading…" : "Upload to YouTube") {
                        let snapshot = metadata
                        Task { await model.uploadLastRecordingToYouTube(metadata: snapshot) }
                    }
                    .controlSize(.small)
                    .disabled(locked || MediaProcessing.isSuspended || metadata.validationMessage != nil)
                    .help(MediaProcessing.isSuspended ? MediaProcessing.statusMessage : "Upload the current edit to YouTube")
                }
            }
        }
        .onAppear { resetMetadata() }
        .onChange(of: model.lastRecordingURL) { _, _ in resetMetadata() }
        .onChange(of: model.projectEditor?.url) { _, _ in resetMetadata() }
    }

    private func resetMetadata() {
        metadata = YouTubeUploadMetadata(title: model.projectEditor?.displayName
            ?? model.lastRecordingURL?.deletingPathExtension().lastPathComponent ?? "")
        isExpanded = false
    }
}
