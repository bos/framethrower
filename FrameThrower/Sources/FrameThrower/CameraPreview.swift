@preconcurrency import AVFoundation
import AppKit
import SwiftUI

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        view.setSession(session)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
        nsView.setSession(session)
    }
}

final class CameraPreviewView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = previewLayer
        previewLayer.videoGravity = .resizeAspect

    }

    required init?(coder: NSCoder) { nil }

    func setSession(_ session: AVCaptureSession) {
        guard !MediaProcessing.isSuspended else {
            previewLayer.session = nil
            return
        }
        if previewLayer.session !== session { previewLayer.session = session }
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            if connection.automaticallyAdjustsVideoMirroring { connection.automaticallyAdjustsVideoMirroring = false }
            if connection.isVideoMirrored { connection.isVideoMirrored = false }
        }
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}
