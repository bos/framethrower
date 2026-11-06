import SwiftUI

/// The action and its capture settings share the same edges and surface. Saved
/// recordings live outside this block and cannot be mistaken for its target.
struct CaptureRecordingSetup<Control: View>: View {
    @Binding var quality: RecordingQuality
    let details: CaptureRecordingDetails
    let status: String?
    let isRecording: Bool
    let isLocked: Bool
    let recordingStartedAt: Date?
    @ViewBuilder var recordingControl: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            recordingControl()
            if let status {
                HStack(spacing: 7) {
                    if isRecording {
                        Circle().fill(RecorderStyle.accent).frame(width: 6, height: 6)
                    }
                    Text(status)
                    if let started = recordingStartedAt, isRecording {
                        Text(started, style: .timer).monospacedDigit()
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isRecording ? .primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Picker("Recording quality", selection: $quality) {
                    Text("High quality").tag(RecordingQuality.highQuality)
                    Text("Smaller files").tag(RecordingQuality.compact)
                }
                .pickerStyle(.menu)
                .disabled(isLocked)
                .help("Choose the format saved for new recordings. High quality uses ProRes LT; Smaller files uses H.264. Export creates a separate compressed copy.")
                Text(details.video)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
                Text(details.storage)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(2).frame(minHeight: 24, alignment: .topLeading)
                    .help("Camera and audio use additional storage. Actual video size depends on screen activity.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .modifier(RecorderCard())
    }
}
