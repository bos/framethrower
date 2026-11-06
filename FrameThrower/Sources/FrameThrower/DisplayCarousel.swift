import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Low-resolution snapshots keep display selection current without a recording stream.
struct DisplayCarousel: View {
    @ObservedObject var model: CaptureViewModel
    var isEnabled: Bool
    let sourcePreviews: CaptureSourcePreviews
    var onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var images: [CGDirectDisplayID: NSImage] = [:]
    @State private var failedDisplays: Set<CGDirectDisplayID> = []
    @State private var isLoading = false
    @State private var previewVisible = false

    private var captureLocked: Bool { model.isRecording || model.isCountdownActive || model.isCaptureBusy }
    private var displayKey: String {
        model.displays.map {
            let frame = $0.display.frame
            return "\($0.id):\(frame.minX),\(frame.minY),\(frame.width),\(frame.height):\($0.display.width)x\($0.display.height)"
        }
            .joined(separator: ",")
    }

    var body: some View {
        GeometryReader { geometry in
            let imageHeight = max(64, geometry.size.height - 112)
            VStack(spacing: 0) {
                HStack {
                    Text("CHOOSE A DISPLAY")
                        .font(.system(size: 9, weight: .medium))
                        .tracking(1.4)
                    Spacer()
                }
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 16)
                .padding(.top, 10)

                if MediaProcessing.isSuspended {
                    Text(MediaProcessing.statusMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.displays.isEmpty {
                    ContentUnavailableView("No displays available", systemImage: "display")
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal) {
                            HStack(alignment: .top, spacing: 18) {
                                ForEach(model.displays) { display in
                                    DisplayCarouselTile(
                                        title: display.name,
                                        size: display.display.frame.size,
                                        imageHeight: imageHeight,
                                        image: images[display.id],
                                        isSelected: model.selectedDisplayID == display.id,
                                        isLoading: isLoading && images[display.id] == nil,
                                        failed: failedDisplays.contains(display.id)
                                    ) {
                                        model.selectedDisplayID = display.id
                                        onSelect()
                                    }
                                    .id(display.id)
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.top, 8)
                            .padding(.bottom, 12)
                        }
                        .frame(maxHeight: .infinity)
                        .defaultScrollAnchor(.center, for: .alignment)
                        .scrollIndicators(.visible)
                        .onChange(of: model.selectedDisplayID, initial: true) { _, selected in
                            guard let selected else { return }
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                                proxy.scrollTo(selected, anchor: .center)
                            }
                        }
                        .disabled(captureLocked)
                    }
                }
            }
        }
        .frame(minHeight: 176, idealHeight: 244, maxHeight: .infinity)
        .background {
            Color(white: 0.09)
                .overlay {
                    LinearGradient(
                        colors: [.white.opacity(0.045), .clear, .black.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(CapturePreviewVisibility(isVisible: $previewVisible))
        .task(id: "\(displayKey):\(previewVisible):\(model.hasScreenRecordingPermission):\(captureLocked)") {
            await refreshPreviews()
        }
    }

    @MainActor
    private func refreshPreviews() async {
        guard !MediaProcessing.isSuspended else {
            images = [:]
            failedDisplays = []
            isLoading = false
            sourcePreviews.clear()
            return
        }
        guard model.hasScreenRecordingPermission, CGPreflightScreenCaptureAccess() else {
            images = [:]
            sourcePreviews.clear()
            return
        }
        let displays = model.displays
        let displayIDs = Set(displays.map(\.id))
        images = images.filter { displayIDs.contains($0.key) }
        failedDisplays = []
        // Display thumbnails are part of choosing a source, so they load with
        // existing permission even before a user clicks a capture control.
        guard previewVisible, !captureLocked, !displays.isEmpty else { return }
        var filters: [CGDirectDisplayID: SCContentFilter] = [:]
        await sourcePreviews.refreshes.run {
            isLoading = true
            defer { isLoading = false }
            do {
                if filters.isEmpty {
                    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
                    try Task.checkCancellation()
                    // Exclude the application, including windows opened after
                    // this filter was built. Reuse filters between snapshots.
                    let ownApp = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
                    for display in displays {
                        filters[display.id] = SCContentFilter(display: display.display,
                            excludingApplications: ownApp, exceptingWindows: [])
                    }
                }
                var succeeded = true
                for display in displays {
                    try Task.checkCancellation()
                    guard previewVisible, !captureLocked, model.hasScreenRecordingPermission,
                          CGPreflightScreenCaptureAccess(), let filter = filters[display.id] else { return false }
                    let size = filter.contentRect.size
                    let scale = min(1, 640 / max(size.width, size.height, 1))
                    let configuration = SCStreamConfiguration()
                    configuration.width = max(2, Int(size.width * scale))
                    configuration.height = max(2, Int(size.height * scale))
                    configuration.showsCursor = false
                    do {
                        let capture = try await SCScreenshotManager.captureImage(
                            contentFilter: filter, configuration: configuration
                        )
                        try Task.checkCancellation()
                        guard previewVisible, !captureLocked, model.hasScreenRecordingPermission,
                              CGPreflightScreenCaptureAccess() else { return false }
                        let source = CapturePreviewSource.display(id: display.id, frame: display.display.frame)
                        sourcePreviews.store(capture, contentSize: size, for: source)
                        images[display.id] = NSImage(cgImage: capture, size: size)
                        failedDisplays.remove(display.id)
                    } catch {
                        try Task.checkCancellation()
                        failedDisplays.insert(display.id)
                        succeeded = false
                        // Keep the last good image through a transient failure.
                    }
                }
                if !succeeded { filters = [:] }
                return succeeded
            } catch {
                guard !Task.isCancelled else { return false }
                filters = [:]
                failedDisplays = displayIDs
                return false
            }
        }
    }
}

enum DisplayThumbnailGeometry {
    static func fittedSize(for source: CGSize, maxHeight: CGFloat, maxWidth: CGFloat = 236) -> CGSize {
        guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0,
              maxHeight.isFinite, maxWidth.isFinite, maxHeight > 0, maxWidth > 0 else { return .zero }
        let scale = min(maxWidth / source.width, maxHeight / source.height)
        return CGSize(width: source.width * scale, height: source.height * scale)
    }
}

struct DisplayCarouselTile: View {
    var title: String
    var size: CGSize
    var imageHeight: CGFloat = 132
    var image: NSImage?
    var isSelected: Bool
    var isLoading: Bool
    var failed: Bool
    var select: () -> Void
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    private var thumbnailSize: CGSize {
        DisplayThumbnailGeometry.fittedSize(for: image?.size ?? size, maxHeight: imageHeight)
    }

    private var previewStatus: String {
        if image != nil { return "preview loaded" }
        if isLoading { return "loading preview" }
        return failed ? "preview unavailable" : "preview not loaded"
    }

    var body: some View {
        Button(action: select) {
            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.65))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        isSelected ? RecorderStyle.accent : .white.opacity(isHovered ? 0.13 : 0.07),
                        in: Capsule()
                    )

                if let image {
                    ZStack {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    }
                    .frame(width: thumbnailSize.width, height: thumbnailSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSelected ? RecorderStyle.accent : .white.opacity(isHovered ? 0.4 : 0.16),
                                lineWidth: isSelected ? 2.5 : 1
                            )
                    }
                    .overlay(alignment: .topTrailing) {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(RecorderStyle.accent, in: Circle())
                                .padding(8)
                        }
                    }
                    .shadow(color: isSelected ? RecorderStyle.accent.opacity(0.18) : .clear, radius: 9, y: 3)
                } else {
                    HStack(spacing: 6) {
                        if isLoading { ProgressView().controlSize(.small) }
                        Text(isLoading ? "Loading preview…" : failed ? "Preview unavailable" : "Preview not loaded")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.white.opacity(0.45))
                }

                Text("\(Int(size.width)) × \(Int(size.height)) points")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(width: max(120, thumbnailSize.width))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.65)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Record \(title)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue((isSelected ? "Selected" : "Not selected") + ", " + previewStatus)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
