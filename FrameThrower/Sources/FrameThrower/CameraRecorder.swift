@preconcurrency import AVFoundation
import Combine
import Foundation

struct CameraDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
}

enum CameraRecordingError: LocalizedError {
    case permissionDenied
    case unavailable
    case configurationFailed
    case noFrames
    case alreadyRecording
    case recordingFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Allow camera access in System Settings → Privacy & Security → Camera."
        case .unavailable:
            return "The selected camera is unavailable. Reconnect it or choose another camera."
        case .configurationFailed:
            return "The selected camera could not be started. It may be in use by another app."
        case .noFrames:
            return "The camera did not deliver video. Check its connection and privacy shutter."
        case .alreadyRecording:
            return "The camera is already recording."
        case let .recordingFailed(message):
            return "Camera recording failed: \(message)"
        }
    }
}

/// Camera audio is deliberately absent: the independently selected microphone is
/// captured by ScreenCaptureKit. No camera access is requested until selection.
@MainActor
final class CameraRecorder: ObservableObject {
    @Published private(set) var devices: [CameraDevice] = []
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isPreparing = false
    @Published private(set) var isReady = false
    @Published private(set) var isRecording = false

    var session: AVCaptureSession { engine.session }

    private let engine = CameraCaptureEngine()
    private var selectionGeneration = 0
    private var observers: [any NSObjectProtocol] = []

    init() {
        refreshDevices()
        engine.reportError = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.errorMessage = message
                self?.isReady = false
            }
        }
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in self?.refreshDevices() }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        engine.shutDown()
    }

    func refreshDevices() {
        devices = Self.discover().map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
        if let selectedDeviceID, !devices.contains(where: { $0.id == selectedDeviceID }) {
            isReady = false
            errorMessage = CameraRecordingError.unavailable.localizedDescription
            engine.failIfRecording(CameraRecordingError.unavailable)
        }
    }

    func selectDevice(_ id: String?) async {
        guard !isRecording else { return }
        selectionGeneration += 1
        let generation = selectionGeneration
        selectedDeviceID = id
        errorMessage = nil
        isReady = false
        isPreparing = true
        defer {
            if generation == selectionGeneration { isPreparing = false }
        }
        if id != nil {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
            default: granted = false
            }
            guard generation == selectionGeneration else { return }
            guard granted else {
                errorMessage = CameraRecordingError.permissionDenied.localizedDescription
                return
            }
        }
        guard generation == selectionGeneration else { return }
        do {
            try await engine.configure(id: id)
            guard generation == selectionGeneration else { return }
            isReady = id != nil
        } catch {
            guard generation == selectionGeneration else { return }
            errorMessage = error.localizedDescription
        }
    }

    /// Returns the host-clock timestamp of the first frame written, not the time
    /// this method was called. Use it to align the independent screen track.
    func startRecording(to url: URL) async throws -> Double {
        guard selectedDeviceID != nil, isReady, !isPreparing else {
            throw CameraRecordingError.unavailable
        }
        guard !isRecording else { throw CameraRecordingError.alreadyRecording }
        isRecording = true
        errorMessage = nil
        do {
            return try await engine.startRecording(to: url)
        } catch {
            isRecording = false
            errorMessage = error.localizedDescription
            throw error
        }
    }

    func stopRecording() async throws {
        guard isRecording else { return }
        defer { isRecording = false }
        do {
            try await engine.stopRecording()
        } catch {
            errorMessage = error.localizedDescription
            throw error
        }
    }

    private static func discover() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}

/// All mutable capture/writer state is confined to queue. The session is exposed
/// only for AVCaptureVideoPreviewLayer; its configuration stays on this queue.
private final class CameraCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var reportError: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "framethrower.camera.capture")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var trackWriter: CameraTrackWriter?
    private var outputURL: URL?
    private var pendingStart: CheckedContinuation<Double, any Error>?
    private var recordingError: (any Error)?
    private var generation = UUID()
    private var runtimeObserver: (any NSObjectProtocol)?
    private var interruptedObserver: (any NSObjectProtocol)?
    private var isFinishing = false

    override init() {
        super.init()
        runtimeObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil
        ) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                .localizedDescription ?? "The camera stopped unexpectedly."
            self?.failIfRecording(CameraRecordingError.recordingFailed(message))
        }
        interruptedObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil
        ) { [weak self] _ in
            self?.failIfRecording(CameraRecordingError.unavailable)
        }
    }

    deinit {
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver) }
        if let interruptedObserver { NotificationCenter.default.removeObserver(interruptedObserver) }
    }

    func configure(id: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard self.outputURL == nil, !self.isFinishing else {
                    continuation.resume(throwing: CameraRecordingError.alreadyRecording)
                    return
                }
                self.session.stopRunning()
                self.session.beginConfiguration()
                self.session.inputs.forEach { self.session.removeInput($0) }
                self.session.outputs.forEach { self.session.removeOutput($0) }
                self.videoOutput = nil
                do {
                    if let id {
                        guard let device = AVCaptureDevice(uniqueID: id), device.isConnected else {
                            throw CameraRecordingError.unavailable
                        }
                        let input = try AVCaptureDeviceInput(device: device)
                        guard self.session.canAddInput(input) else {
                            throw CameraRecordingError.configurationFailed
                        }
                        self.session.addInput(input)
                        if self.session.canSetSessionPreset(.hd1280x720) {
                            self.session.sessionPreset = .hd1280x720
                        } else if self.session.canSetSessionPreset(.high) {
                            self.session.sessionPreset = .high
                        }
                        let output = AVCaptureVideoDataOutput()
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        output.alwaysDiscardsLateVideoFrames = true
                        guard self.session.canAddOutput(output) else {
                            throw CameraRecordingError.configurationFailed
                        }
                        self.session.addOutput(output)
                        output.setSampleBufferDelegate(self, queue: self.queue)
                        // Preview and saved camera use the same unmirrored image.
                        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false
                            connection.isVideoMirrored = false
                        }
                        self.videoOutput = output
                    }
                    self.session.commitConfiguration()
                    if id != nil {
                        self.session.startRunning()
                        guard self.session.isRunning else { throw CameraRecordingError.configurationFailed }
                    }
                    continuation.resume()
                } catch {
                    if self.videoOutput == nil { self.session.commitConfiguration() }
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startRecording(to url: URL) async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.outputURL == nil, !self.isFinishing else {
                    continuation.resume(throwing: CameraRecordingError.alreadyRecording)
                    return
                }
                guard self.session.isRunning, self.videoOutput != nil else {
                    continuation.resume(throwing: CameraRecordingError.unavailable)
                    return
                }
                self.outputURL = url
                self.pendingStart = continuation
                self.recordingError = nil
                self.generation = UUID()
                let generation = self.generation
                self.queue.asyncAfter(deadline: .now() + 8) {
                    guard self.generation == generation, self.pendingStart != nil else { return }
                    self.fail(CameraRecordingError.noFrames)
                }
            }
        }
    }

    func stopRecording() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard !self.isFinishing else {
                    continuation.resume(throwing: CameraRecordingError.alreadyRecording)
                    return
                }
                let priorError = self.recordingError
                self.recordingError = nil
                if let pendingStart = self.pendingStart {
                    self.pendingStart = nil
                    pendingStart.resume(throwing: priorError ?? CameraRecordingError.noFrames)
                }
                self.outputURL = nil
                self.generation = UUID()
                guard let trackWriter = self.trackWriter else {
                    continuation.resume(throwing: priorError ?? CameraRecordingError.noFrames)
                    return
                }
                self.trackWriter = nil
                self.isFinishing = true
                trackWriter.finish { result in
                    self.queue.async {
                        self.isFinishing = false
                        if let priorError {
                            continuation.resume(throwing: priorError)
                        } else {
                            continuation.resume(with: result)
                        }
                    }
                }
            }
        }
    }

    func failIfRecording(_ error: any Error) {
        let message = error.localizedDescription
        queue.async {
            if self.outputURL != nil { self.fail(CameraRecordingError.recordingFailed(message)) }
            self.reportError?(message)
        }
    }

    func shutDown() {
        queue.async {
            self.fail(CameraRecordingError.unavailable)
            self.trackWriter?.cancel()
            self.trackWriter = nil
            self.outputURL = nil
            self.session.stopRunning()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let outputURL, recordingError == nil, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            guard let clock = session.synchronizationClock else { throw CameraRecordingError.noFrames }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let hostTime = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
            if trackWriter == nil { trackWriter = CameraTrackWriter(url: outputURL) }
            if try trackWriter?.append(sampleBuffer, hostTime: hostTime) == true, let pendingStart {
                self.pendingStart = nil
                pendingStart.resume(returning: hostTime)
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        guard outputURL != nil else { return }
        recordingError = error
        if let pendingStart {
            self.pendingStart = nil
            self.trackWriter?.cancel()
            self.trackWriter = nil
            self.outputURL = nil
            pendingStart.resume(throwing: error)
        }
        reportError?(error.localizedDescription)
    }
}


/// Writes only camera video, retaining the captured timeline without a baked-in
/// PIP transform. Call append/finish serially; append stops before finish begins.
/// Kept independent of capture hardware so synchronization and failure behavior
/// can be exercised with synthetic camera samples.
final class CameraTrackWriter: @unchecked Sendable {
    private let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstHostTime: Double?
    private var isFinishing = false

    init(url: URL) { self.url = url }

    /// Returns true only when this sample was actually accepted by the encoder.
    @discardableResult
    func append(_ sample: CMSampleBuffer, hostTime: Double) throws -> Bool {
        guard !isFinishing, hostTime.isFinite, CMSampleBufferDataIsReady(sample) else {
            throw CameraRecordingError.noFrames
        }
        if writer == nil {
            guard let format = CMSampleBufferGetFormatDescription(sample) else {
                throw CameraRecordingError.noFrames
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dimensions.width),
                AVVideoHeightKey: Int(dimensions.height)
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw CameraRecordingError.configurationFailed }
            writer.add(input)
            guard writer.startWriting() else {
                throw writer.error ?? CameraRecordingError.configurationFailed
            }
            self.writer = writer
            self.input = input
        }
        guard let writer, let input, writer.status == .writing else {
            throw writer?.error ?? CameraRecordingError.noFrames
        }
        guard input.isReadyForMoreMediaData else { return false }
        if firstHostTime == nil {
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sample))
        }
        guard input.append(sample) else { throw writer.error ?? CameraRecordingError.noFrames }
        if firstHostTime == nil { firstHostTime = hostTime }
        return true
    }

    func finish(completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        guard !isFinishing else {
            completion(.failure(CameraRecordingError.alreadyRecording))
            return
        }
        isFinishing = true
        guard let writer, let input, writer.status == .writing, firstHostTime != nil else {
            completion(.failure(writer?.error ?? CameraRecordingError.noFrames))
            return
        }
        input.markAsFinished()
        writer.finishWriting { [self] in
            if let error = self.writer?.error {
                completion(.failure(error))
            } else if self.writer?.status != .completed {
                completion(.failure(CameraRecordingError.noFrames))
            } else {
                completion(.success(()))
            }
        }
    }

    func cancel() { writer?.cancelWriting() }
}
