import AppKit
@preconcurrency import ScreenCaptureKit
import SwiftUI

/// Still thumbnails make every display recognizable before choosing what to record.
struct DisplayCarousel: View {
    @ObservedObject var model: CaptureViewModel
    var isEnabled: Bool
    var onSelect: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var images: [CGDirectDisplayID: NSImage] = [:]
    @State private var failedDisplays: Set<CGDirectDisplayID> = []
    @State private var isLoading = false
    @State private var refreshID = 0

    private var captureLocked: Bool { model.isRecording || model.isCountdownActive || model.isCaptureBusy }
    private var displayKey: String {
        model.displays.map { "\($0.id):\($0.display.width)x\($0.display.height)" }
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
                    Button {
                        onSelect()
                        refreshID += 1
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 26, height: 26)
                            .background(.white.opacity(0.08), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Refresh display previews")
                    .accessibilityLabel("Refresh display previews")
                    .disabled(captureLocked || isLoading || model.displays.isEmpty)
                }
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 16)
                .padding(.top, 10)

                if model.displays.isEmpty {
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
        .task(id: "\(displayKey):\(refreshID):\(isEnabled):\(model.hasScreenRecordingPermission):\(captureLocked)") {
            await refreshPreviews()
        }
    }

    @MainActor
    private func refreshPreviews() async {
        guard model.hasScreenRecordingPermission, CGPreflightScreenCaptureAccess() else {
            images = [:]
            return
        }
        let displays = model.displays
        let displayIDs = Set(displays.map(\.id))
        images = images.filter { displayIDs.contains($0.key) }
        failedDisplays = []
        // Display thumbnails are part of choosing a source, so they load with
        // existing permission even before a user clicks a capture control.
        guard !captureLocked, !displays.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            // Exclude this app, so the chooser never appears recursively in its own thumbnails.
            let content = try await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true
            )
            try Task.checkCancellation()
            guard !captureLocked, model.hasScreenRecordingPermission,
                  CGPreflightScreenCaptureAccess() else { return }
            // Deferred or closed AppKit windows can have a window number of -1.
            let ownWindows = Set(NSApp.windows.compactMap { CGWindowID(exactly: $0.windowNumber) })
            let excluded = content.windows.filter { ownWindows.contains($0.windowID) }
            for display in displays {
                try Task.checkCancellation()
                guard !captureLocked, model.hasScreenRecordingPermission,
                      CGPreflightScreenCaptureAccess() else { return }
                let filter = SCContentFilter(display: display.display, excludingWindows: excluded)
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
                    images[display.id] = NSImage(cgImage: capture, size: size)
                } catch {
                    try Task.checkCancellation()
                    images[display.id] = nil
                    failedDisplays.insert(display.id)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            failedDisplays = displayIDs
        }
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

                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.white.opacity(0.045))
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            .padding(5)
                    } else {
                        VStack(spacing: 7) {
                            if isLoading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "display")
                                    .font(.system(size: 25, weight: .ultraLight))
                            }
                            Text(failed ? "Preview unavailable" : "Display preview")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.white.opacity(0.45))
                    }
                }
                .frame(height: imageHeight)
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

                Text("\(Int(size.width)) × \(Int(size.height)) points")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .frame(width: 236)
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
