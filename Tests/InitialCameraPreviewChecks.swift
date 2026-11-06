import Foundation

private enum CameraPreviewCheckError: Error { case failed(String) }

@main
struct InitialCameraPreviewChecks {
    static func main() throws {
        let display = CGRect(x: -100, y: 50, width: 200, height: 100)
        let selection = CGRect(x: -50, y: 75, width: 100, height: 50)
        let recording = InitialCameraPreviewGeometry.recordingRect(area: selection, display: display,
                                                                   in: CGSize(width: 800, height: 400))
        try require(recording == CGRect(x: 200, y: 100, width: 400, height: 200),
                    "Area camera canvas must align with the selected source, including negative display origins")
        let full = InitialCameraPreviewGeometry.recordingRect(area: nil, display: nil,
                                                              in: CGSize(width: 800, height: 400))
        try require(full == CGRect(x: 0, y: 0, width: 800, height: 400), "Window/display camera canvas fills the fitted source")
        let origin = PIPPlacement(x: 0.25, y: 0.4, scale: 0.25)
        let old = InitialCameraPreviewGeometry.cameraRect(origin, in: recording)
        try require(recording.contains(old), "Camera must remain inside the selected area")
        let moved = InitialCameraPreviewGeometry.moved(origin, by: CGSize(width: 30, height: -20), in: recording)
        let next = InitialCameraPreviewGeometry.cameraRect(moved, in: recording)
        try near(next.minX, old.minX + 30, "Main camera drag must preserve its full horizontal pointer delta")
        try near(next.minY, old.minY - 20, "Main camera drag must preserve its full vertical pointer delta")
        let edge = InitialCameraPreviewGeometry.moved(origin, by: CGSize(width: 10000, height: -10000), in: recording)
        let edgeRect = InitialCameraPreviewGeometry.cameraRect(edge, in: recording)
        try near(edgeRect.maxX, recording.maxX, "Camera right edge clamps to the recording, not the full display")
        try near(edgeRect.minY, recording.minY, "Camera top edge clamps to the recording")
        try require(InitialCameraPreviewGeometry.moved(origin, by: CGSize(width: CGFloat.nan, height: 10), in: recording) == origin,
                    "Invalid pointer movement must not corrupt camera placement")
        try require(InitialCameraPreviewGeometry.recordingRect(area: CGRect(x: 900, y: 900, width: 20, height: 20),
            display: display, in: full.size) == .zero, "An invalid area must not put the camera on unrelated display pixels")
        try require(InitialCameraPreviewGeometry.recordingRect(area: nil, display: nil, in: .zero) == .zero,
                    "A collapsed preview must not yield invalid camera geometry")
        print("Initial camera preview checks passed (full-source and selected-area placement, negative origins, exact drag deltas, clamping, and invalid geometry).")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CameraPreviewCheckError.failed(message) }
    }

    private static func near(_ actual: Double, _ expected: Double, _ message: String) throws {
        try require(abs(actual - expected) < 0.000001, message)
    }
}
