import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// A still preview, refreshed when the capture selection changes or on request.
struct CapturePreview: View {
    @ObservedObject var model: CaptureViewModel
    var isEnabled: Bool
    let sourcePreviews: CaptureSourcePreviews
    @State private var image: NSImage?
    @State private var imageSource: CapturePreviewSource?
    @State private var imageDisplayFrame: CGRect?
    @State private var isLoading = false
    @State private var failed = false
    @State private var refreshID = 0
    @State private var previewRequested = false

    private var hasSource: Bool {
        model.captureKind == .window ? model.selectedWindow != nil : model.selectedDisplayID != nil
    }

    private var captureLocked: Bool { model.isRecording || model.isCountdownActive || model.isCaptureBusy }

    private var source: CapturePreviewSource? {
        if model.captureKind == .window { return model.selectedWindow.map(CapturePreviewSource.window) }
        guard let display = model.displays.first(where: { $0.id == model.selectedDisplayID }) else { return nil }
        return .display(id: display.id, frame: display.display.frame)
    }

    private struct RefreshKey: Hashable {
        var source: CapturePreviewSource?
        var kind: String
        var refreshID: Int
        var hasPermission: Bool
        var enabled: Bool
        var requested: Bool
        var locked: Bool
    }

    private var refreshKey: RefreshKey {
        RefreshKey(source: source, kind: model.captureKind.rawValue, refreshID: refreshID,
                   hasPermission: model.hasScreenRecordingPermission, enabled: isEnabled,
                   requested: previewRequested, locked: captureLocked)
    }

    private var currentImage: NSImage? { imageSource == source ? image : nil }

    var body: some View {
        ZStack {
            Color(white: 0.09)
            // Quiet texture behind the actual capture, rather than a simulated screen.
            LinearGradient(
                colors: [.white.opacity(0.045), .clear, .black.opacity(0.12)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let image = currentImage {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .overlay {
                        if model.captureKind == .area, let imageDisplayFrame {
                            AreaPreviewEditor(
                                area: $model.area,
                                displayFrame: imageDisplayFrame,
                                isEditable: !captureLocked
                            )
                        }
                    }
                    .padding(24)
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
                    .accessibilityLabel(model.captureKind == .area
                        ? "Full display preview with the recording area highlighted"
                        : "Preview of the selected capture source")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: model.hasScreenRecordingPermission ? "viewfinder" : "lock.rectangle")
                        .font(.system(size: 30, weight: .ultraLight))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                    if model.hasScreenRecordingPermission && hasSource && !isEnabled && !previewRequested {
                        Button { previewRequested = true } label: {
                            Text("Show preview")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .background(.white.opacity(0.12), in: Capsule())
                        }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                    }
                }
            }
        }
        .frame(minHeight: 100, idealHeight: 220, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isRecording ? RecorderStyle.accent : .white.opacity(0.45))
                    .frame(width: 5, height: 5)
                Text(model.isRecording ? "RECORDING" : "PREVIEW")
                    .font(.system(size: 9, weight: .medium))
                    .tracking(1.4)
            }
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            if model.hasScreenRecordingPermission && hasSource && !captureLocked {
                Button {
                    previewRequested = true
                    refreshID += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 28, height: 28)
                        .foregroundStyle(.white.opacity(0.8))
                        .background(.black.opacity(0.55), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Refresh preview")
                .accessibilityLabel("Refresh preview")
                .disabled(isLoading)
                .padding(12)
            }
        }
        .task(id: refreshKey) {
            await refreshPreview()
        }
    }

    private var placeholder: String {
        if !model.hasScreenRecordingPermission { return "Allow screen recording to see a preview" }
        if !hasSource { return "Choose a window" }
        if !isEnabled && !previewRequested { return "Preview not loaded" }
        if isLoading { return "Loading preview…" }
        if failed { return "Preview unavailable" }
        return "Select a source"
    }

    @MainActor
    private func refreshPreview() async {
        guard !captureLocked else { return }
        guard isEnabled || previewRequested else { return }
        image = nil
        imageSource = nil
        imageDisplayFrame = nil
        failed = false
        guard model.hasScreenRecordingPermission, CGPreflightScreenCaptureAccess(), let requestedSource = source else {
            if !model.hasScreenRecordingPermission { sourcePreviews.clear() }
            return
        }
        isLoading = true
        defer { isLoading = false }

        let filter: SCContentFilter
        var displayFrame: CGRect?
        switch model.captureKind {
        case .window:
            guard let window = model.selectedWindow else { return }
            filter = SCContentFilter(desktopIndependentWindow: window.window)
        case .display, .area:
            guard let display = model.displays.first(where: { $0.id == model.selectedDisplayID }) else {
                return
            }
            // Deferred or closed AppKit windows can have a window number of -1.
            let ownWindows = NSApp.windows.compactMap { CGWindowID(exactly: $0.windowNumber) }
            let content: SCShareableContent
            do {
                content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                try Task.checkCancellation()
                guard !captureLocked, model.hasScreenRecordingPermission,
                      CGPreflightScreenCaptureAccess(), source == requestedSource else { return }
            } catch {
                failed = true
                return
            }
            let excluded = content.windows.filter { ownWindows.contains($0.windowID) }
            filter = SCContentFilter(display: display.display, excludingWindows: excluded)
            displayFrame = display.display.frame
        }

        let configuration = SCStreamConfiguration()
        let size = filter.contentRect.size
        let scale = min(2, 1200 / max(size.width, size.height, 1))
        configuration.width = max(2, Int(size.width * scale))
        configuration.height = max(2, Int(size.height * scale))
        configuration.showsCursor = false
        do {
            try Task.checkCancellation()
            guard !captureLocked, model.hasScreenRecordingPermission,
                  CGPreflightScreenCaptureAccess(), source == requestedSource else { return }
            let capture = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
            try Task.checkCancellation()
            guard source == requestedSource, !captureLocked, model.hasScreenRecordingPermission,
                  CGPreflightScreenCaptureAccess() else { return }
            sourcePreviews.store(capture, contentSize: size, for: requestedSource)
            imageDisplayFrame = displayFrame
            imageSource = requestedSource
            image = NSImage(cgImage: capture, size: size)
        } catch is CancellationError {
            return
        } catch {
            guard source == requestedSource else { return }
            sourcePreviews.remove(requestedSource)
            failed = true
        }
    }
}
