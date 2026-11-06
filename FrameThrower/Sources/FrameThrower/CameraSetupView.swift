import SwiftUI

/// Initial placement controls for the camera shown in the main source preview.
struct CameraSetupView: View {
    @ObservedObject var camera: CameraRecorder
    @Binding var placement: PIPPlacement
    let locked: Bool
    @ObservedObject var sourcePreviews: CaptureSourcePreviews
    let source: CapturePreviewSource?
    let area: CGRect?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if camera.selectedDeviceID != nil {
                HStack(spacing: 12) {
                    ForEach(0..<4) { index in
                        Button {
                            placement.x = index % 2 == 0 ? 0.04 : 0.96
                            placement.y = index < 2 ? 0.04 : 0.96
                        } label: {
                            Image(systemName: ["arrow.up.left", "arrow.up.right", "arrow.down.left", "arrow.down.right"][index])
                        }
                        .accessibilityLabel(["Camera top left", "Camera top right", "Camera bottom left", "Camera bottom right"][index])
                        .help(["Move camera to the top left", "Move camera to the top right", "Move camera to the bottom left", "Move camera to the bottom right"][index])
                    }
                    Slider(value: $placement.scale, in: 0.12...0.5) { Text("Camera size") }
                        .frame(minWidth: 160, maxWidth: 300)
                        .help("Resize the camera overlay in the recording preview. Drag the camera picture to move it.")
                    Spacer(minLength: 0)
                }
                .frame(height: 24)
                .disabled(locked)
            }
            if let message = camera.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.system(size: 11))
    }
}

/// Uses the existing live session at its actual position on the main source
/// preview. This is also the camera drag target, above the area selection view.
struct InitialCameraPreview: View {
    @ObservedObject var camera: CameraRecorder
    @Binding var placement: PIPPlacement
    let recordingRect: CGRect
    let locked: Bool
    @State private var origin: PIPPlacement?

    var body: some View {
        let rect = InitialCameraPreviewGeometry.cameraRect(placement, in: recordingRect)
        if recordingRect.width > 0, recordingRect.height > 0 {
            Group {
                if MediaProcessing.isSuspended {
                    Image(systemName: "video.slash")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .help(MediaProcessing.statusMessage)
                } else {
                    CameraPreview(session: camera.session)
                }
            }
                .background(.black)
                .frame(width: rect.width, height: rect.height)
                .overlay { Rectangle().strokeBorder(.white.opacity(0.8), lineWidth: 1) }
                .contentShape(Rectangle())
                .offset(x: rect.minX, y: rect.minY)
                .gesture(DragGesture(coordinateSpace: .named("mainInitialCameraCanvas")).onChanged { value in
                    guard !locked else { return }
                    if origin == nil { origin = placement }
                    guard let origin else { return }
                    placement = InitialCameraPreviewGeometry.moved(origin, by: value.translation, in: recordingRect)
                }.onEnded { _ in origin = nil })
                .allowsHitTesting(!locked)
                .accessibilityLabel(MediaProcessing.isSuspended ? "Camera preview disabled" : "Live camera preview. Drag to set initial position.")
                .help(MediaProcessing.isSuspended ? MediaProcessing.statusMessage : "Drag the camera picture to move it within the recording.")
                .onChange(of: locked) { _, locked in if locked { origin = nil } }
        }
    }
}

/// Camera selection shares the recorder's input row; its layout stays beneath.
struct CameraInputPicker: View {
    @ObservedObject var camera: CameraRecorder
    let locked: Bool
    var onSelectionChange: (String?, String?) -> Void = { _, _ in }

    var body: some View {
        HStack(spacing: 6) {
            Picker("Camera", selection: Binding(get: { camera.selectedDeviceID }, set: { id in
                onSelectionChange(camera.selectedDeviceID, id)
                Task { await camera.selectDevice(id) }
            })) {
                Text("Off").tag(Optional<String>.none)
                ForEach(camera.devices) { device in Text(device.name).tag(Optional(device.id)) }
                if let id = camera.selectedDeviceID, !camera.devices.contains(where: { $0.id == id }) {
                    Text("Camera disconnected").tag(Optional(id))
                }
            }
            .tint(camera.selectedDeviceID == nil ? Color.secondary : RecorderStyle.accent)
            .disabled(MediaProcessing.isSuspended || locked || camera.isPreparing)
            .help(MediaProcessing.isSuspended ? MediaProcessing.statusMessage : "Choose the camera to record.")
            if camera.isPreparing { ProgressView().controlSize(.small) }
        }
        .lineLimit(1)
    }
}
