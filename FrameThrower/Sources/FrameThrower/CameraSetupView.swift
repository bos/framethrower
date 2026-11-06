import SwiftUI

/// A local live preview. This stays inside the recorder, whose windows are
/// excluded from display capture; the camera track is composited after capture.
struct CameraSetupView: View {
    @ObservedObject var camera: CameraRecorder
    @Binding var placement: PIPPlacement
    let locked: Bool
    @State private var origin: PIPPlacement?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "video")
                Picker("Camera", selection: Binding(get: { camera.selectedDeviceID }, set: { id in
                    Task { await camera.selectDevice(id) }
                })) {
                    Text("Off").tag(Optional<String>.none)
                    ForEach(camera.devices) { device in Text(device.name).tag(Optional(device.id)) }
                    if let id = camera.selectedDeviceID, !camera.devices.contains(where: { $0.id == id }) {
                        Text("Camera disconnected").tag(Optional(id))
                    }
                }
                .disabled(locked || camera.isPreparing)
                if camera.isPreparing { ProgressView().controlSize(.small) }
                Spacer()
            }
            if camera.selectedDeviceID != nil { cameraLayout }
            if let message = camera.errorMessage {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
        .font(.system(size: 11))
    }

    private var cameraLayout: some View {
        HStack(spacing: 16) {
            GeometryReader { proxy in
                let rect = placement.frame(in: proxy.size, cameraAspect: 16.0 / 9.0)
                ZStack(alignment: .topLeading) {
                    Color.primary.opacity(0.05)
                    Text("Initial camera layout")
                        .font(.caption2).foregroundStyle(.secondary).padding(8)
                    CameraPreview(session: camera.session)
                        .background(.black)
                        .frame(width: rect.width, height: rect.height)
                        .overlay { Rectangle().strokeBorder(.white.opacity(0.7), lineWidth: 1) }
                        .offset(x: rect.minX, y: rect.minY)
                        .gesture(DragGesture(coordinateSpace: .named("initialCameraCanvas")).onChanged { value in
                            guard !locked else { return }
                            if origin == nil { origin = placement }
                            guard var next = origin else { return }
                            next.x = min(1, max(0, next.x + value.translation.width / max(1, proxy.size.width - rect.width)))
                            next.y = min(1, max(0, next.y + value.translation.height / max(1, proxy.size.height - rect.height)))
                            placement = next
                        }.onEnded { _ in origin = nil })
                        .accessibilityLabel("Live camera preview. Drag to set initial position.")
                }
                .coordinateSpace(name: "initialCameraCanvas")
            }
            .frame(width: 200, height: 112.5)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 10) {
                Text("Drag to position your camera.").font(.caption)
                Text("You can move, resize, or hide it after recording, too.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(0..<4) { index in
                        Button {
                            placement.x = index % 2 == 0 ? 0.04 : 0.96
                            placement.y = index < 2 ? 0.04 : 0.96
                        } label: {
                            Image(systemName: ["arrow.up.left", "arrow.up.right", "arrow.down.left", "arrow.down.right"][index])
                        }.accessibilityLabel(["Camera top left", "Camera top right", "Camera bottom left", "Camera bottom right"][index])
                    }
                }
                Slider(value: $placement.scale, in: 0.12...0.5) { Text("Camera size") }
            }.disabled(locked)
        }
    }
}
