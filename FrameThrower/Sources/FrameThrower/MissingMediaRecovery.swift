@preconcurrency import AVFoundation
import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers

struct MissingMediaReference: Identifiable, Equatable, Sendable {
    enum Role: String, Sendable {
        case screen, camera, cursor
        var title: String {
            switch self {
            case .screen: "screen recording"
            case .camera: "camera recording"
            case .cursor: "pointer data"
            }
        }
    }
    let role: Role
    let filename: String
    let url: URL
    var id: URL { url }

    private static func references(project: RecordingProject, directory: URL) -> [MissingMediaReference] {
        let references: [(Role, String?)] = [(.screen, project.screenFilename), (.camera, project.cameraFilename), (.cursor, project.cursorFilename)]
        return references.compactMap { role, filename in
            guard let filename else { return nil }
            let url = directory.appendingPathComponent(filename)
            return MissingMediaReference(role: role, filename: filename, url: url)
        }
    }

    static func missing(project: RecordingProject, directory: URL) -> [MissingMediaReference] {
        references(project: project, directory: directory).filter { reference in
            do { _ = try FileManager.default.attributesOfItem(atPath: reference.url.path); return false }
            catch { return isAbsent(error) }
        }
    }

    static func unusableMessages(project: RecordingProject, directory: URL) -> [String] {
        references(project: project, directory: directory).compactMap { reference in
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: reference.url.path)
                if attributes[.type] as? FileAttributeType != .typeRegular {
                    return "“\(reference.filename)” is not a regular file. Move that item out of the project folder, then reopen this recording to locate the original."
                }
                if !FileManager.default.isReadableFile(atPath: reference.url.path) {
                    return "“\(reference.filename)” cannot be read. Check its file permissions before reopening the recording."
                }
            } catch {
                if !isAbsent(error) { return "“\(reference.filename)” cannot be inspected. Check the project folder’s permissions before reopening the recording." }
            }
            return nil
        }
    }

    private static func isAbsent(_ error: any Error) -> Bool {
        let value = error as NSError
        return value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code)
            || value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT)
    }
}

enum CoreMediaRelinker {
    enum MediaKind: Sendable { case movie, cursor }
    enum RecoveryError: LocalizedError {
        case invalidChoice, invalidCursor, destinationExists(String), noVideo, tooShort(Double), changedSource, copyFailed(String)
        var errorDescription: String? {
            switch self {
            case .invalidChoice: "Choose a local, readable movie or pointer-data file."
            case .invalidCursor: "The selected file is not valid pointer data. Choose the original pointer JSON file."
            case .destinationExists(let name): "“\(name)” already exists in the project folder. It was not replaced."
            case .noVideo: "The selected file has no usable video track. Choose the original recording."
            case .tooShort(let seconds): "The selected file is too short. This recording needs at least \(String(format: "%.2f", seconds)) seconds."
            case .changedSource: "The selected file changed while it was being copied. Choose a completed recording and try again."
            case .copyFailed(let detail): "The missing file could not be restored: \(detail)"
            }
        }
    }
    static let copyChunkSize = 1_048_576

    /// Copy a validated original beside its project without changing either
    /// project's filenames or the user's chosen file. Publishing a hard link
    /// from a hidden sibling is atomic and fails if any destination exists.
    static func restore(source: URL, destination: URL, minimumDuration: Double? = nil,
                        kind: MediaKind? = nil, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard source.isFileURL, destination.isFileURL else { throw RecoveryError.invalidChoice }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard !exists(destination) else { throw RecoveryError.destinationExists(destination.lastPathComponent) }
        let kind = kind ?? (destination.pathExtension.lowercased() == "json" ? .cursor : .movie)
        try await validate(source, kind: kind, minimumDuration: minimumDuration)
        try Task.checkCancellation()
        let copy = Task.detached(priority: .userInitiated) {
            try stageCopy(source: source, destination: destination, progress: progress)
        }
        let staged = try await withTaskCancellationHandler { try await copy.value } onCancel: { copy.cancel() }
        defer { try? FileManager.default.removeItem(at: staged) }
        try Task.checkCancellation()
        // Revalidate the staged copy, so a changing source cannot publish an
        // incomplete or invalid movie after its first metadata check.
        try await validate(staged, kind: kind, minimumDuration: minimumDuration)
        try Task.checkCancellation()
        do { try FileManager.default.linkItem(at: staged, to: destination) }
        catch {
            if exists(destination) { throw RecoveryError.destinationExists(destination.lastPathComponent) }
            throw RecoveryError.copyFailed(error.localizedDescription)
        }
        progress(1)
    }

    private static func exists(_ url: URL) -> Bool {
        // attributesOfItem also notices dangling symbolic links; publishing
        // itself still uses an exclusive atomic operation to close the race.
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }

    private static func validate(_ url: URL, kind: MediaKind, minimumDuration: Double?) async throws {
        try Task.checkCancellation()
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              FileManager.default.isReadableFile(atPath: url.path) else { throw RecoveryError.invalidChoice }
        let duration: Double
        switch kind {
        case .cursor:
            let read = Task.detached(priority: .userInitiated) {
                do { return try CursorRecording.load(from: url).duration }
                catch { throw RecoveryError.invalidCursor }
            }
            duration = try await withTaskCancellationHandler { try await read.value } onCancel: { read.cancel() }
        case .movie:
            try MediaProcessing.requireEnabled()
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw RecoveryError.noVideo }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let bounds = CGRect(origin: .zero, size: size).applying(transform).standardized
            let videoDuration = try await track.load(.timeRange).duration.seconds
            duration = try await asset.load(.duration).seconds
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
                  bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0,
                  videoDuration.isFinite, videoDuration > 0,
                  duration.isFinite, duration > 0 else { throw RecoveryError.noVideo }
        }
        if let minimumDuration, minimumDuration.isFinite, minimumDuration > 0,
           duration + 1.0 / 15 < minimumDuration { throw RecoveryError.tooShort(minimumDuration) }
        try Task.checkCancellation()
    }

    private static func stageCopy(source: URL, destination: URL, progress: @Sendable (Double) -> Void) throws -> URL {
        let suffix = destination.pathExtension.isEmpty ? source.pathExtension : destination.pathExtension
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".framethrower-relink-\(UUID().uuidString).partial.\(suffix.isEmpty ? "mov" : suffix)")
        let descriptor = staged.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR) }
        guard descriptor >= 0 else { throw RecoveryError.copyFailed(String(cString: strerror(errno))) }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: staged) } }
        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? output.close() }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let original = try CopySourceSnapshot(descriptor: input.fileDescriptor)
        let expected = UInt64(original.size)
        var copied: UInt64 = 0
        var lastProgress = ContinuousClock.now
        progress(0)
        while true {
            try Task.checkCancellation()
            let count: Int = try autoreleasepool {
                guard let chunk = try input.read(upToCount: copyChunkSize), !chunk.isEmpty else { return 0 }
                try output.write(contentsOf: chunk)
                return chunk.count
            }
            guard count > 0 else { break }
            copied += UInt64(count)
            if ContinuousClock.now - lastProgress >= .milliseconds(50) {
                progress(min(0.95, Double(copied) / Double(max(1, expected)) * 0.95))
                lastProgress = .now
            }
        }
        // Equal byte counts do not prove a stable original: a writer can edit
        // in place or atomically replace its path with another same-size file.
        guard copied == expected,
              try CopySourceSnapshot(descriptor: input.fileDescriptor) == original,
              (try? CopySourceSnapshot(url: source)) == original else { throw RecoveryError.changedSource }
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        progress(0.95)
        completed = true
        return staged
    }

    private struct CopySourceSnapshot: Equatable {
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64

        init(descriptor: Int32) throws {
            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0 else {
                throw RecoveryError.copyFailed(String(cString: strerror(errno)))
            }
            try self.init(information)
        }

        init(url: URL) throws {
            var information = stat()
            guard url.path.withCString({ Darwin.lstat($0, &information) }) == 0 else { throw RecoveryError.changedSource }
            try self.init(information)
        }

        private init(_ information: stat) throws {
            guard information.st_mode & S_IFMT == S_IFREG, information.st_size >= 0 else { throw RecoveryError.invalidChoice }
            device = Int64(information.st_dev)
            inode = UInt64(information.st_ino)
            size = information.st_size
            modifiedSeconds = Int64(information.st_mtimespec.tv_sec)
            modifiedNanoseconds = Int64(information.st_mtimespec.tv_nsec)
            changedSeconds = Int64(information.st_ctimespec.tv_sec)
            changedNanoseconds = Int64(information.st_ctimespec.tv_nsec)
        }
    }
}

struct MissingMediaRecoveryView: View {
    @ObservedObject var editor: ProjectEditor
    var onRestored: () -> Void
    @StateObject private var recovery = MissingMediaRecoveryController()

    var body: some View {
        let missing = MissingMediaReference.missing(project: editor.project, directory: editor.url.deletingLastPathComponent())
        let unusable = MissingMediaReference.unusableMessages(project: editor.project, directory: editor.url.deletingLastPathComponent())
        if !missing.isEmpty || !unusable.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(missing) { reference in
                    HStack(spacing: 12) {
                        Text("Missing \(reference.role.title): \(reference.filename)")
                            .font(.callout).textSelection(.enabled).lineLimit(2)
                        Spacer(minLength: 0)
                        Button("Locate…") {
                            recovery.locate(reference, minimumDuration: reference.role == .screen ? editor.project.duration : nil) {
                                onRestored()
                            }
                        }.disabled(recovery.isBusy)
                    }
                }
                ForEach(unusable, id: \.self) { Text($0).font(.callout).textSelection(.enabled) }
                if recovery.isCopying {
                    HStack {
                        ProgressView(value: recovery.progress).frame(width: 180)
                        Button("Cancel") { recovery.cancel() }
                    }
                }
                if let message = recovery.errorMessage { Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            .padding(16).frame(maxWidth: 540)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .background(MissingMediaWindowAnchor(controller: recovery).frame(width: 0, height: 0))
            .onDisappear { recovery.cancel() }
        }
    }
}

@MainActor
private final class MissingMediaRecoveryController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var isCopying = false
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?
    weak var window: NSWindow?
    private var panel: NSOpenPanel?
    private var task: Task<Void, Never>?
    private var requestID: UUID?

    func locate(_ reference: MissingMediaReference, minimumDuration: Double?, restored: @escaping () -> Void) {
        guard !isBusy else { return }
        let id = UUID(); requestID = id
        isBusy = true; errorMessage = nil
        task = Task { @MainActor [self] in
            defer { isBusy = false; isCopying = false; task = nil; requestID = nil }
            let chooser = NSOpenPanel()
            panel = chooser
            chooser.title = "Locate \(reference.filename)"
            chooser.prompt = "Copy to Project"
            chooser.message = "Select the original \(reference.role.title). It will be copied into this project’s folder as “\(reference.filename)”."
            chooser.allowedContentTypes = reference.role == .cursor ? [.json] : [.movie]
            chooser.allowsOtherFileTypes = false
            chooser.canChooseDirectories = false
            chooser.allowsMultipleSelection = false
            let response: NSApplication.ModalResponse
            if let window { response = await withCheckedContinuation { continuation in chooser.beginSheetModal(for: window) { continuation.resume(returning: $0) } } }
            else { response = chooser.runModal() }
            panel = nil
            guard response == .OK, let source = chooser.url, !Task.isCancelled else { return }
            isCopying = true; progress = 0
            do {
                try await CoreMediaRelinker.restore(source: source, destination: reference.url, minimumDuration: minimumDuration,
                    kind: reference.role == .cursor ? .cursor : .movie) { [weak self] value in
                        Task { @MainActor in if self?.requestID == id { self?.progress = value } }
                    }
                restored()
            } catch is CancellationError { }
            catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
    }
    func cancel() { task?.cancel(); panel?.cancel(nil) }
}

private struct MissingMediaWindowAnchor: NSViewRepresentable {
    let controller: MissingMediaRecoveryController
    func makeNSView(context: Context) -> MissingMediaWindowView { MissingMediaWindowView() }
    func updateNSView(_ view: MissingMediaWindowView, context: Context) { view.controller = controller; controller.window = view.window }
}
@MainActor
private final class MissingMediaWindowView: NSView {
    weak var controller: MissingMediaRecoveryController?
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); controller?.window = window }
}
