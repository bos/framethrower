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
    case timedOut
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
        case .timedOut:
            return "The camera encoder did not finish in time. Any captured media has been kept."
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

    var session: AVCaptureSession? { engine?.session }

    // Selection is restored after a Debug opt-in, but native objects are never
    // constructed by startup or by device discovery alone.
    private var engine: CameraCaptureEngine?
    private var engineToken: UUID?
    private var selectionGeneration: UInt64 = 0
    private var observers: [any NSObjectProtocol] = []

    init() {}

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        engine?.shutDown()
    }

    func resumeCaptureDiscovery() async {
        guard !MediaProcessing.isCaptureSuspended else { return }
        let captureGeneration = MediaProcessing.captureGeneration
        if observers.isEmpty {
            for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.refreshDevices() }
                })
            }
        }
        refreshDevices()
        guard captureIsCurrent(captureGeneration) else { return }
        if let selectedDeviceID { await selectDevice(selectedDeviceID) }
    }

    /// Revocation is a shutdown action, so it remains permitted after Off.
    /// Keep the selection and last device names for a later deliberate opt-in.
    func suspendCapture() async {
        selectionGeneration &+= 1
        isPreparing = false; isReady = false; isRecording = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        let previous = engine
        engine = nil; engineToken = nil
        previous?.invalidate()
        await previous?.shutDownAndWait()
    }

    func refreshDevices() {
        guard !MediaProcessing.isCaptureSuspended else { return }
        let captureGeneration = MediaProcessing.captureGeneration
        let discovered = Self.discover().map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
        guard captureIsCurrent(captureGeneration) else { return }
        devices = discovered
        if let selectedDeviceID, !devices.contains(where: { $0.id == selectedDeviceID }) {
            isReady = false
            errorMessage = CameraRecordingError.unavailable.localizedDescription
            engine?.failIfRecording(CameraRecordingError.unavailable)
        }
    }

    func selectDevice(_ id: String?) async {
        guard !isRecording else { return }
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectedDeviceID = id
        errorMessage = nil; isReady = false
        if MediaProcessing.isCaptureSuspended {
            errorMessage = id == nil ? nil : MediaProcessing.captureStatusMessage
            await suspendCapture()
            return
        }
        let captureGeneration = MediaProcessing.captureGeneration
        guard let id else {
            isPreparing = false
            let previous = engine; engine = nil; engineToken = nil
            previous?.invalidate()
            await previous?.shutDownAndWait()
            return
        }
        isPreparing = true
        defer { if generation == selectionGeneration { isPreparing = false } }
        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        // A permission response can arrive long after Off, or after a different
        // selection. Never let that response create or restart a native session.
        guard !Task.isCancelled, generation == selectionGeneration, captureIsCurrent(captureGeneration) else { return }
        guard granted else { errorMessage = CameraRecordingError.permissionDenied.localizedDescription; return }
        if engine == nil {
            guard let created = CameraCaptureEngine(captureGeneration: captureGeneration) else { return }
            let token = UUID(); engine = created; engineToken = token
            created.reportError = { [weak self] message in
                Task { @MainActor [weak self] in
                    guard let self, self.engineToken == token, self.captureIsCurrent(captureGeneration) else { return }
                    self.errorMessage = message; self.isReady = false
                }
            }
        }
        guard let engine else { return }
        do {
            try await engine.configure(id: id)
            guard !Task.isCancelled, generation == selectionGeneration, captureIsCurrent(captureGeneration), self.engine === engine else { return }
            isReady = true
        } catch {
            guard generation == selectionGeneration, captureIsCurrent(captureGeneration), self.engine === engine else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func captureIsCurrent(_ generation: UInt64) -> Bool {
        !MediaProcessing.isCaptureSuspended && MediaProcessing.captureGeneration == generation
    }

    /// Returns the host-clock timestamp of the first frame written, not the time
    /// this method was called. Use it to align the independent screen track.
    func startRecording(to url: URL, quality: RecordingQuality = .compact) async throws -> Double {
        try MediaProcessing.requireCaptureEnabled()
        guard let engine else { throw MediaProcessing.CaptureSuspended() }
        guard selectedDeviceID != nil, isReady, !isPreparing else {
            throw CameraRecordingError.unavailable
        }
        guard !isRecording else { throw CameraRecordingError.alreadyRecording }
        let generation = selectionGeneration, captureGeneration = MediaProcessing.captureGeneration
        isRecording = true
        errorMessage = nil
        do {
            let time = try await engine.startRecording(to: url, quality: quality)
            guard generation == selectionGeneration, captureIsCurrent(captureGeneration), self.engine === engine else { throw MediaProcessing.CaptureSuspended() }
            return time
        } catch {
            if generation == selectionGeneration { isRecording = false; errorMessage = error.localizedDescription }
            throw error
        }
    }

    func stopRecording() async throws {
        guard isRecording, let engine else { return }
        let generation = selectionGeneration
        defer { if generation == selectionGeneration { isRecording = false } }
        do {
            try await engine.stopRecording()
        } catch {
            if generation == selectionGeneration { errorMessage = error.localizedDescription }
            throw error
        }
    }

    private static func discover() -> [AVCaptureDevice] {
        guard !MediaProcessing.isCaptureSuspended else { return [] }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }
}

/// Thread-safe revocation and request ordering; it contains no native camera
/// object. The injected policy seam lets tests cover Off/On ABA without touching
/// the process's real opt-in or any device.
final class CameraCaptureRequestGate: @unchecked Sendable {
    private let lock = NSLock()
    private let policy: @Sendable () -> (suspended: Bool, generation: UInt64)
    private let captureGeneration: UInt64
    private var active = true
    private var request: UInt64 = 0
    init(captureGeneration: UInt64, policy: @escaping @Sendable () -> (suspended: Bool, generation: UInt64) = {
        (MediaProcessing.isCaptureSuspended, MediaProcessing.captureGeneration)
    }) { self.captureGeneration = captureGeneration; self.policy = policy }
    func nextRequest() -> UInt64 {
        lock.lock(); defer { lock.unlock() }; request &+= 1; return request
    }
    func invalidate() { lock.lock(); active = false; request &+= 1; lock.unlock() }
    func allows(_ token: UInt64? = nil) -> Bool {
        lock.lock(); let current = active && (token == nil || token == request); lock.unlock()
        let value = policy()
        return current && !value.suspended && value.generation == captureGeneration
    }
    func requireAllowed(_ token: UInt64? = nil) throws {
        guard allows(token) else { throw MediaProcessing.CaptureSuspended() }
    }
}

/// All mutable capture/writer state is confined to queue. The session is exposed
/// only for AVCaptureVideoPreviewLayer; its configuration stays on this queue.
private final class CameraCaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session: AVCaptureSession
    private let gate: CameraCaptureRequestGate
    var reportError: (@Sendable (String) -> Void)?

    private let queue = DispatchQueue(label: "framethrower.camera.capture")
    private var videoOutput: AVCaptureVideoDataOutput?
    private var trackWriter: CameraTrackWriter?
    private var outputURL: URL?
    private var quality: RecordingQuality = .compact
    private var pendingStart: CheckedContinuation<Double, any Error>?
    private var recordingError: (any Error)?
    private var generation = UUID()
    private var runtimeObserver: (any NSObjectProtocol)?
    private var interruptedObserver: (any NSObjectProtocol)?
    private var isFinishing = false
    private var finishOperation: UUID?
    private var finishContinuation: CheckedContinuation<Void, any Error>?

    init?(captureGeneration: UInt64) {
        let gate = CameraCaptureRequestGate(captureGeneration: captureGeneration)
        guard gate.allows() else { return nil }
        self.gate = gate
        session = AVCaptureSession()
        super.init()
        guard gate.allows() else { return nil }
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

    func configure(id: String) async throws {
        try MediaProcessing.requireCaptureEnabled()
        let request = gate.nextRequest()
        try gate.requireAllowed(request)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                guard self.outputURL == nil, !self.isFinishing else {
                    continuation.resume(throwing: CameraRecordingError.alreadyRecording); return
                }
                do {
                    try self.gate.requireAllowed(request)
                    self.clearSession()
                    try self.gate.requireAllowed(request)
                    self.session.beginConfiguration()
                    var configuring = true
                    do {
                        defer { if configuring { self.session.commitConfiguration() } }
                        try self.gate.requireAllowed(request)
                        guard let device = AVCaptureDevice(uniqueID: id), device.isConnected else { throw CameraRecordingError.unavailable }
                        let input = try AVCaptureDeviceInput(device: device)
                        try self.gate.requireAllowed(request)
                        guard self.session.canAddInput(input) else { throw CameraRecordingError.configurationFailed }
                        self.session.addInput(input)
                        if self.session.canSetSessionPreset(.hd1280x720) { self.session.sessionPreset = .hd1280x720 }
                        else if self.session.canSetSessionPreset(.high) { self.session.sessionPreset = .high }
                        let output = AVCaptureVideoDataOutput()
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        output.alwaysDiscardsLateVideoFrames = true
                        try self.gate.requireAllowed(request)
                        guard self.session.canAddOutput(output) else { throw CameraRecordingError.configurationFailed }
                        self.session.addOutput(output)
                        output.setSampleBufferDelegate(self, queue: self.queue)
                        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
                            connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false
                        }
                        self.videoOutput = output
                        self.session.commitConfiguration(); configuring = false
                    }
                    try self.gate.requireAllowed(request)
                    self.session.startRunning()
                    try self.gate.requireAllowed(request)
                    guard self.session.isRunning else { throw CameraRecordingError.configurationFailed }
                    continuation.resume()
                } catch {
                    // Cleanup is deliberately not capture-policy gated.
                    self.clearSession()
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func startRecording(to url: URL, quality: RecordingQuality) async throws -> Double {
        try MediaProcessing.requireCaptureEnabled()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard self.gate.allows() else { continuation.resume(throwing: MediaProcessing.CaptureSuspended()); return }
                guard self.outputURL == nil, !self.isFinishing else {
                    continuation.resume(throwing: CameraRecordingError.alreadyRecording)
                    return
                }
                guard self.session.isRunning, self.videoOutput != nil else {
                    continuation.resume(throwing: CameraRecordingError.unavailable)
                    return
                }
                self.outputURL = url
                self.quality = quality
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
                let operation = UUID()
                self.finishOperation = operation
                self.finishContinuation = continuation
                self.queue.asyncAfter(deadline: .now() + 15) {
                    self.resolveFinish(operation: operation, result: .failure(CameraRecordingError.timedOut))
                }
                trackWriter.finish { result in
                    self.queue.async {
                        self.resolveFinish(operation: operation,
                            result: priorError.map { .failure($0) } ?? result)
                    }
                }
            }
        }
    }

    func failIfRecording(_ error: any Error) {
        let message = error.localizedDescription
        queue.async {
            if self.outputURL != nil { self.fail(CameraRecordingError.recordingFailed(message)) }
            else { self.reportError?(message) }
        }
    }

    func invalidate() { gate.invalidate() }

    func shutDown() {
        invalidate()
        queue.async { self.tearDown() }
    }

    func shutDownAndWait() async {
        invalidate()
        await withCheckedContinuation { continuation in
            queue.async { self.tearDown(); continuation.resume() }
        }
    }

    /// Called only on queue, including after capture policy becomes Off.
    private func clearSession() {
        videoOutput?.setSampleBufferDelegate(nil, queue: nil)
        session.stopRunning()
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        videoOutput = nil
    }

    private func tearDown() {
        generation = UUID()
        if let pendingStart { self.pendingStart = nil; pendingStart.resume(throwing: MediaProcessing.CaptureSuspended()) }
        // Preserve an accepted take; shutdown must never cancel its source file.
        trackWriter?.finish { _ in }; trackWriter = nil; outputURL = nil
        clearSession()
        if let runtimeObserver { NotificationCenter.default.removeObserver(runtimeObserver); self.runtimeObserver = nil }
        if let interruptedObserver { NotificationCenter.default.removeObserver(interruptedObserver); self.interruptedObserver = nil }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard gate.allows(), let outputURL, recordingError == nil, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            guard let clock = session.synchronizationClock else { throw CameraRecordingError.noFrames }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let hostTime = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock()).seconds
            if trackWriter == nil { trackWriter = CameraTrackWriter(url: outputURL, quality: quality) }
            if try trackWriter?.append(sampleBuffer, hostTime: hostTime) == true, let pendingStart {
                self.pendingStart = nil
                pendingStart.resume(returning: hostTime)
            }
        } catch {
            fail(error)
        }
    }

    private func resolveFinish(operation: UUID, result: Result<Void, any Error>) {
        guard finishOperation == operation, let continuation = finishContinuation else { return }
        finishOperation = nil
        finishContinuation = nil
        isFinishing = false
        continuation.resume(with: result)
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
    private let quality: RecordingQuality
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstHostTime: Double?
    private var isFinishing = false

    init(url: URL, quality: RecordingQuality = .compact) { self.url = url; self.quality = quality }

    /// Returns true only when this sample was actually accepted by the encoder.
    @discardableResult
    func append(_ sample: CMSampleBuffer, hostTime: Double) throws -> Bool {
        try MediaProcessing.requireCaptureEnabled()
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard !isFinishing, hostTime.isFinite, timestamp.isNumeric,
              timestamp.seconds.isFinite, CMSampleBufferDataIsReady(sample) else {
            throw CameraRecordingError.noFrames
        }
        if writer == nil {
            guard let format = CMSampleBufferGetFormatDescription(sample) else {
                throw CameraRecordingError.noFrames
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let input = AVAssetWriterInput(mediaType: .video,
                outputSettings: quality.videoSettings(width: Int(dimensions.width), height: Int(dimensions.height)),
                sourceFormatHint: format)
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
            writer.startSession(atSourceTime: timestamp)
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
