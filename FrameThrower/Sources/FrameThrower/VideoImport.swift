@preconcurrency import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Import references the existing file; it never transcodes or changes it.
enum VideoImporter {
    struct Metadata: Equatable, Sendable {
        let duration: Double
        let frameDuration: Double
        var pixelWidth: Int? = nil
        var pixelHeight: Int? = nil
        var hasAudio: Bool? = nil

        func validate() throws {
            guard duration.isFinite, duration > 0,
                  frameDuration.isFinite, frameDuration > 0 else { throw ImportError.invalidTiming }
        }
    }

    enum ImportError: LocalizedError {
        case invalidFile, noVideo, unsupported, protectedContent, invalidTiming, sourceChanged, noDestination

        var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose a local, readable video file."
            case .noVideo: "The selected file does not contain a video track."
            case .unsupported: "macOS cannot read or decode this video's format or codec."
            case .protectedContent: "Protected video cannot be imported for editing."
            case .invalidTiming: "The selected video does not have a finite, positive duration and frame rate."
            case .sourceChanged: "The video changed during import. Wait for it to finish saving, then try again."
            case .noDestination: "Could not find an unused project name beside the video."
            }
        }
    }

    /// Include the system's additional container types without maintaining an
    /// extension whitelist. The contents and codecs are validated separately.
    static var contentTypes: [UTType] {
        guard !MediaProcessing.isSuspended else { return [.movie, .video] }
        let supported: [UTType]
        if #available(macOS 26, *) {
            supported = AVURLAsset.audiovisualContentTypes
        } else {
            supported = AVURLAsset.audiovisualTypes().compactMap { UTType($0.rawValue) }
        }
        return Array(Set([.movie, .video] + supported.filter {
            $0.conforms(to: .movie) || $0.conforms(to: .video)
        })).sorted { $0.identifier < $1.identifier }
    }

    @MainActor
    static func importVideo(at url: URL) async throws -> ProjectEditor {
        // Reject before constructing any AVFoundation object or touching media.
        try MediaProcessing.requireEnabled()
        try Task.checkCancellation()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        let before = try fileIdentity(source)
        let metadata = try await inspect(source)
        try Task.checkCancellation()
        guard try fileIdentity(source) == before else { throw ImportError.sourceChanged }
        return try createProject(for: source, metadata: metadata)
    }

    static func inspect(_ url: URL) async throws -> Metadata {
        try MediaProcessing.requireEnabled()
        try Task.checkCancellation()
        _ = try fileIdentity(url)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            guard try await !asset.load(.hasProtectedContent) else { throw ImportError.protectedContent }
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ImportError.noVideo }
            guard try await asset.load(.isReadable), try await asset.load(.isComposable),
                  try await track.load(.isDecodable) else { throw ImportError.unsupported }
            let videoDuration = try await track.load(.timeRange).duration.seconds
            guard videoDuration.isFinite, videoDuration > 0 else { throw ImportError.noVideo }
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            for audio in audioTracks {
                guard try await audio.load(.isDecodable) else { throw ImportError.unsupported }
            }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
                throw ImportError.noVideo
            }
            let duration = try await asset.load(.duration).seconds
            let minimumFrameDuration = try await track.load(.minFrameDuration).seconds
            let nominalFrameRate = Double(try await track.load(.nominalFrameRate))
            let frameDuration: Double
            if minimumFrameDuration.isFinite, minimumFrameDuration > 0 { frameDuration = minimumFrameDuration }
            else if nominalFrameRate.isFinite, nominalFrameRate > 0 { frameDuration = 1 / nominalFrameRate }
            else { frameDuration = 1.0 / 30 }
            let metadata = Metadata(duration: duration, frameDuration: frameDuration,
                pixelWidth: Int(bounds.width.rounded()), pixelHeight: Int(bounds.height.rounded()), hasAudio: !audioTracks.isEmpty)
            try metadata.validate()
            try Task.checkCancellation()
            return metadata
        } catch is CancellationError { throw CancellationError() }
        catch let error as ImportError { throw error }
        catch { throw ImportError.unsupported }
    }

    /// Pure project/file work, separated from video inspection so persistence
    /// can be tested while media processing is suspended.
    @MainActor
    static func createProject(for url: URL, metadata: Metadata) throws -> ProjectEditor {
        try metadata.validate()
        let source = url.standardizedFileURL.resolvingSymlinksInPath()
        _ = try fileIdentity(source)
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        // Render cadence is bounded by the editor, independently of the source
        // timestamps. VFR media remains referenced with its original timing.
        let project = RecordingProject(screenFilename: source.lastPathComponent,
            duration: metadata.duration, captureFrameDuration: min(1, max(1.0 / 120, metadata.frameDuration)))
        try project.validate()
        for suffix in 1...10_000 {
            try Task.checkCancellation()
            let name = suffix == 1 ? stem : "\(stem) \(suffix)"
            let destination = directory.appendingPathComponent(name).appendingPathExtension("framethrower")
            guard !exists(destination), !exists(destination.appendingPathExtension("recovery")) else { continue }
            let editor = ProjectEditor(project: project, url: destination)
            if editor.save() { return editor }
            // Saving publishes exclusively. If another writer won the name,
            // try the next one without replacing its project or recovery data.
            if exists(destination) { continue }
            throw ProjectError.invalid("Could not save a project beside the video: " +
                (editor.errorMessage ?? "Check the folder's write permissions."))
        }
        throw ImportError.noDestination
    }

    private struct FileIdentity: Equatable {
        let size: UInt64
        let modified: Date?
        let inode: UInt64?
    }

    private static func fileIdentity(_ url: URL) throws -> FileIdentity {
        guard url.isFileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.uint64Value > 0,
              FileManager.default.isReadableFile(atPath: url.path) else { throw ImportError.invalidFile }
        return FileIdentity(size: size.uint64Value, modified: attributes[.modificationDate] as? Date,
                            inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
}


/// Copies a source once into this project's media library. Occurrences refer to
/// its UUID; neither removing a clip nor Undo removes the immutable bytes.
enum ProjectVideoImport {
    struct StoredSource: Sendable {
        let source: VideoSource
        let directory: URL
    }

    static func importSource(at url: URL, projectURL: URL) async throws -> StoredSource {
        // Keep the driver interlock in front of security access and AVFoundation.
        try MediaProcessing.requireEnabled()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let before = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
        let identity = (before[.size] as? NSNumber)?.uint64Value
        let modified = before[.modificationDate] as? Date
        let inode = (before[.systemFileNumber] as? NSNumber)?.uint64Value
        let metadata = try await VideoImporter.inspect(url)
        let worker = Task.detached(priority: .utility) {
            let stored = try storeSource(at: url, projectURL: projectURL, metadata: metadata)
            do {
                let after = try FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
                guard identity == (after[.size] as? NSNumber)?.uint64Value,
                      modified == after[.modificationDate] as? Date,
                      inode == (after[.systemFileNumber] as? NSNumber)?.uint64Value else {
                    throw VideoImporter.ImportError.sourceChanged
                }
            } catch {
                try? FileManager.default.removeItem(at: stored.directory); throw error
            }
            return stored
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    @MainActor
    static func addSources(_ urls: [URL], to editor: ProjectEditor, at requested: Double) async throws -> (UUID, UUID) {
        try MediaProcessing.requireEnabled()
        var stored: [StoredSource] = []
        do {
            for url in urls { try Task.checkCancellation(); stored.append(try await importSource(at: url, projectURL: editor.url)) }
            try Task.checkCancellation()
            guard editor.finishDraft(), !stored.isEmpty else { throw ProjectError.invalid("The pending edit could not be saved.") }
            let project = editor.project
            var next = editor.editingState
            var layers = project.effectiveVideoLayers(in: next)
            let start = min(max(0, requested), max(0, project.duration - min(0.1, project.duration)))
            var selected: (UUID, UUID)?
            for item in stored {
                let clip = VideoClip(sourceID: item.source.id, start: start,
                    end: min(project.duration, start + (item.source.duration ?? project.duration)))
                let layer = VideoLayer(name: item.source.name, clips: [clip])
                layers.append(layer); selected = (layer.id, clip.id)
            }
            next.videoLayers = layers
            guard editor.registerVideoSources(stored.map(\.source), state: next, name: stored.count == 1 ? "Add video" : "Add videos"), let selected else {
                throw ProjectError.invalid(editor.errorMessage ?? "The video sources could not be saved.")
            }
            return selected
        } catch {
            for item in stored { try? FileManager.default.removeItem(at: item.directory) }
            throw error
        }
    }

    /// File-only seam for metadata fixtures. Tests use plain text, never video.
    static func storeSource(at url: URL, projectURL: URL, metadata: VideoImporter.Metadata) throws -> StoredSource {
        try metadata.validate()
        try Task.checkCancellation()
        let manager = FileManager.default
        let original = url.standardizedFileURL.resolvingSymlinksInPath()
        let before = try manager.attributesOfItem(atPath: original.path)
        guard original.isFileURL, before[.type] as? FileAttributeType == .typeRegular,
              let size = before[.size] as? NSNumber, size.uint64Value > 0,
              manager.isReadableFile(atPath: original.path) else { throw VideoImporter.ImportError.invalidFile }
        let root = projectURL.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        let id = UUID()
        let folderName = projectURL.deletingPathExtension().lastPathComponent + ".media"
        let relative = folderName + "/" + id.uuidString + "/" + original.lastPathComponent
        let source = VideoSource(id: id, name: original.deletingPathExtension().lastPathComponent,
            kind: .file, relativePath: relative, duration: metadata.duration,
            pixelWidth: metadata.pixelWidth, pixelHeight: metadata.pixelHeight, hasAudio: metadata.hasAudio)
        try source.validate()
        let target = try source.resolvedURL(in: root)
        let directory = target.deletingLastPathComponent()
        // Exclusive UUID directory also ensures a failed import cannot clean up
        // another asset or an existing project/recovery file.
        try manager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard try source.resolvedURL(in: root) == target else { throw VideoImporter.ImportError.sourceChanged }
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            try manager.copyItem(at: original, to: target)
            try Task.checkCancellation()
            let after = try manager.attributesOfItem(atPath: original.path)
            let copied = try manager.attributesOfItem(atPath: target.path)
            guard before[.size] as? NSNumber == after[.size] as? NSNumber,
                  before[.modificationDate] as? Date == after[.modificationDate] as? Date,
                  before[.systemFileNumber] as? NSNumber == after[.systemFileNumber] as? NSNumber,
                  copied[.size] as? NSNumber == size else { throw VideoImporter.ImportError.sourceChanged }
            return StoredSource(source: source, directory: directory)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
    }
}
