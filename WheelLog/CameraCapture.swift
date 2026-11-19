import AVFoundation
import AudioToolbox
import Combine
import CoreMedia
import CoreVideo
import Photos
import SwiftUI
import UIKit

@MainActor
final class CameraModel: ObservableObject {
    enum Preview: Equatable {
        case closed, opening, ready, unavailable(String)
    }

    enum Recording: Equatable {
        case idle, starting, recording(Date), saving
    }

    @Published private(set) var preview = Preview.closed
    @Published private(set) var recording = Recording.idle
    @Published private(set) var audioAvailable = false
    @Published private(set) var latestVideo: URL?
    @Published var message: String?

    private let engine = CameraEngine()
    private var permissionTask: Task<Void, Never>?
    private var interruption: AnyCancellable?
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var requested = false
    var onVideoSaved: (() -> Void)?
    var session: AVCaptureSession { engine.session }
    var canRecord: Bool { preview == .ready && recording == .idle }

    init() {
        engine.onPreview = { [weak self] result in
            guard let self, self.requested else { return }
            switch result {
            case .success(let audio):
                self.audioAvailable = audio
                self.preview = .ready
            case .failure(let error):
                self.preview = .unavailable(error.localizedDescription)
            }
        }
        engine.onRecordingStarted = { [weak self] in
            guard let self, self.recording == .starting else { return }
            self.recording = .recording(Date())
        }
        engine.onRecordingEnded = { [weak self] result in
            guard let self else { return }
            self.recording = .idle
            self.endBackgroundTime()
            switch result {
            case .success(let url):
                self.latestVideo = url
                self.onVideoSaved?()
            case .failure(let error):
                self.message = error.localizedDescription
            }
        }
        interruption = NotificationCenter.default.publisher(for: AVCaptureSession.wasInterruptedNotification,
                                                            object: engine.session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.stopRecording() }
    }

    func open() {
        guard !requested else { return }
        requested = true
        preview = .opening
        permissionTask = Task { @MainActor [weak self] in
            #if targetEnvironment(simulator)
            self?.preview = .unavailable("Для записи видео нужна камера iPhone.")
            #else
            let allowed = await AVCaptureDevice.requestAccess(for: .video)
            guard !Task.isCancelled, let self, self.requested else { return }
            guard allowed else {
                self.preview = .unavailable("Разрешите доступ к камере в настройках iPhone.")
                return
            }
            let audio = await AVCaptureDevice.requestAccess(for: .audio)
            guard !Task.isCancelled, self.requested else { return }
            self.engine.open(withAudio: audio)
            #endif
        }
    }

    func close() {
        guard requested else { return }
        requested = false
        permissionTask?.cancel()
        permissionTask = nil
        preview = .closed
        if recording != .idle { stopRecording() }
        engine.close()
    }

    func update(_ sample: OverlaySample) {
        engine.update(sample)
    }

    func startRecording(mask: Int, demo: Bool) {
        guard canRecord else { return }
        recording = .starting
        engine.record(mask: mask, demo: demo)
    }

    func stopRecording() {
        guard recording != .idle, recording != .saving else { return }
        recording = .saving
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "WheelLog video") { [weak self] in
            self?.endBackgroundTime()
        }
        engine.stop()
    }

    func saveToPhotos(_ url: URL) {
        Task { @MainActor in
            let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard access == .authorized || access == .limited else {
                message = "Разрешите добавлять видео в «Фото» в настройках iPhone."
                return
            }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
                message = "Видео сохранено в «Фото»."
            } catch {
                message = "Не удалось сохранить видео в «Фото»."
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }
}

private final class CameraEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onPreview: (@MainActor (Result<Bool, Error>) -> Void)?
    var onRecordingStarted: (@MainActor () -> Void)?
    var onRecordingEnded: (@MainActor (Result<URL, Error>) -> Void)?

    private let queue = DispatchQueue(label: "WheelLog.camera", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let overlayLock = NSLock()
    private var overlay = OverlaySample()
    private var audioInput: AVCaptureDeviceInput?
    private var configured = false
    private var pending: (mask: Int, demo: Bool)?
    private var startTimeout: DispatchWorkItem?
    private var writer: MovieWriter?

    func open(withAudio: Bool) {
        queue.async {
            do {
                if !self.configured { try self.configureVideo() }
                self.configureAudio(enabled: withAudio)
                if !self.session.isRunning { self.session.startRunning() }
                guard self.session.isRunning else { throw VideoError.unsupported }
                let hasAudio = self.audioInput != nil
                DispatchQueue.main.async { self.onPreview?(.success(hasAudio)) }
            } catch {
                DispatchQueue.main.async { self.onPreview?(.failure(error)) }
            }
        }
    }

    func close() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func update(_ sample: OverlaySample) {
        overlayLock.lock()
        overlay = sample
        overlayLock.unlock()
    }

    func record(mask: Int, demo: Bool) {
        queue.async {
            guard self.session.isRunning else {
                self.emitRecordingEnd(.failure(VideoError.noCamera))
                return
            }
            self.pending = (mask, demo)
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, self.pending != nil else { return }
                self.pending = nil
                self.startTimeout = nil
                self.emitRecordingEnd(.failure(VideoError.noFrames))
            }
            self.startTimeout = timeout
            self.queue.asyncAfter(deadline: .now() + 4, execute: timeout)
        }
    }

    func stop() {
        queue.async {
            if self.pending != nil {
                self.startTimeout?.cancel()
                self.startTimeout = nil
                self.pending = nil
                self.emitRecordingEnd(.failure(VideoError.noFrames))
            }
            if let writer = self.writer {
                self.writer = nil
                writer.finish { [weak self] result in self?.emitRecordingEnd(result) }
            }
        }
    }

    private func configureVideo() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        else { throw VideoError.noCamera }
        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canSetSessionPreset(.hd1920x1080), session.canAddInput(input) else {
            throw VideoError.unsupported
        }
        session.sessionPreset = .hd1920x1080
        session.addInput(input)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        guard session.canAddOutput(videoOutput) else {
            session.removeInput(input)
            throw VideoError.unsupported
        }
        session.addOutput(videoOutput)
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(90) else {
            session.removeOutput(videoOutput)
            session.removeInput(input)
            throw VideoError.unsupported
        }
        connection.videoRotationAngle = 90
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        configured = true
    }

    private func configureAudio(enabled: Bool) {
        guard enabled != (audioInput != nil) else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if let audioInput {
            session.removeOutput(audioOutput)
            session.removeInput(audioInput)
            self.audioInput = nil
            return
        }
        guard let mic = AVCaptureDevice.default(for: .audio), let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        guard session.canAddOutput(audioOutput) else {
            session.removeInput(input)
            return
        }
        session.addOutput(audioOutput)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
        audioInput = input
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        do {
            if output === videoOutput {
                if let pending {
                    startTimeout?.cancel()
                    startTimeout = nil
                    self.pending = nil
                    let audioSettings: [String: Any]? = audioInput == nil ? nil :
                        audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4) ?? [
                            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44100,
                            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96000
                        ]
                    writer = try MovieWriter(firstFrame: sampleBuffer, audioSettings: audioSettings,
                                             mask: pending.mask, demo: pending.demo)
                    DispatchQueue.main.async { self.onRecordingStarted?() }
                }
                if let writer {
                    overlayLock.lock()
                    let sample = overlay
                    overlayLock.unlock()
                    try writer.appendVideo(sampleBuffer, overlay: sample)
                }
            } else {
                try writer?.appendAudio(sampleBuffer)
            }
        } catch {
            writer?.cancel()
            writer = nil
            emitRecordingEnd(.failure(error))
        }
    }

    private func emitRecordingEnd(_ result: Result<URL, Error>) {
        DispatchQueue.main.async { self.onRecordingEnded?(result) }
    }
}

struct CameraSurface: UIViewRepresentable {
    var session: AVCaptureSession
    var sample: OverlaySample
    var mask: Int
    var ready: Bool

    func makeUIView(context: Context) -> CameraPreviewView {
        CameraPreviewView(session: session)
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        if let connection = view.previewLayer.connection, connection.videoRotationAngle != 90,
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        view.previewLayer.opacity = ready ? 1 : 0
        view.overlay.sample = sample
        view.overlay.metricMask = mask
        view.overlay.setNeedsDisplay()
    }
}

final class CameraPreviewView: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer
    let overlay = OverlayView(frame: .zero)

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspect
        layer.addSublayer(previewLayer)
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { return nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        overlay.frame = bounds
        overlay.setNeedsDisplay()
    }

    final class OverlayView: UIView {
        var sample = OverlaySample()
        var metricMask = OverlayLayout.defaultMask

        override func draw(_ rect: CGRect) {
            guard let context = UIGraphicsGetCurrentContext() else { return }
            OverlayLayout.draw(sample, mask: metricMask, in: bounds.size, context: context)
        }
    }
}
