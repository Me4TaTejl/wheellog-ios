import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

enum VideoError: LocalizedError {
    case noCamera, unsupported, noFrames, pixelBuffer, encode

    var errorDescription: String? {
        switch self {
        case .noCamera: "Камера недоступна на этом устройстве."
        case .unsupported: "Не удалось настроить камеру в 1080p."
        case .noFrames: "В ролик ещё не попало ни одного кадра."
        case .pixelBuffer: "Не удалось обработать кадр камеры."
        case .encode: "Не удалось записать видео. Проверьте свободное место."
        }
    }
}

final class MovieWriter {
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private let audio: AVAssetWriterInput?
    private let buffers: AVAssetWriterInputPixelBufferAdaptor
    private let start: CMTime
    private let temporaryURL: URL
    private let outputURL: URL
    private let width: Int
    private let height: Int
    private let mask: Int
    private var frameCount = 0

    init(firstFrame: CMSampleBuffer, audioSettings: [String: Any]?, mask: Int, demo: Bool) throws {
        guard let image = CMSampleBufferGetImageBuffer(firstFrame) else { throw VideoError.noFrames }
        let width = CVPixelBufferGetWidth(image)
        let height = CVPixelBufferGetHeight(image)
        self.width = width
        self.height = height
        self.mask = mask
        self.start = CMSampleBufferGetPresentationTimeStamp(firstFrame)

        let filename = RideFiles.filename(prefix: demo ? "Demo_video" : "ShermanS_video", ext: "mp4")
        let output = try RideFiles.folder("Видео").appending(path: filename)
        let temporary = FileManager.default.temporaryDirectory.appending(path: filename)
        outputURL = output
        temporaryURL = temporary
        let writer = try AVAssetWriter(outputURL: temporary, fileType: .mp4)
        self.writer = writer
        writer.shouldOptimizeForNetworkUse = true

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: 30
            ]
        ])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw VideoError.encode }
        writer.add(input)
        video = input
        buffers = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])

        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw VideoError.encode }
            writer.add(input)
            audio = input
        } else {
            audio = nil
        }
        guard writer.startWriting() else {
            try? FileManager.default.removeItem(at: temporary)
            throw writer.error ?? VideoError.encode
        }
        writer.startSession(atSourceTime: start)
    }

    func appendVideo(_ sample: CMSampleBuffer, overlay: OverlaySample) throws {
        guard writer.status == .writing else { throw writer.error ?? VideoError.encode }
        guard video.isReadyForMoreMediaData else { return }
        guard let source = CMSampleBufferGetImageBuffer(sample), let pool = buffers.pixelBufferPool,
              CVPixelBufferGetWidth(source) == width, CVPixelBufferGetHeight(source) == height else {
            throw VideoError.pixelBuffer
        }
        var candidate: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &candidate) == kCVReturnSuccess,
              let output = candidate else { throw VideoError.pixelBuffer }
        try composite(source: source, destination: output, overlay: overlay)
        guard buffers.append(output, withPresentationTime: CMSampleBufferGetPresentationTimeStamp(sample)) else {
            throw writer.error ?? VideoError.encode
        }
        frameCount += 1
    }

    func appendAudio(_ sample: CMSampleBuffer) throws {
        guard frameCount > 0, let audio,
              CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sample), start) >= 0 else { return }
        guard writer.status == .writing else { throw writer.error ?? VideoError.encode }
        if audio.isReadyForMoreMediaData, !audio.append(sample) {
            throw writer.error ?? VideoError.encode
        }
    }

    func finish(_ completion: @escaping (Result<URL, Error>) -> Void) {
        guard writer.status == .writing, frameCount > 0 else {
            let error = writer.error ?? VideoError.noFrames
            cancel()
            completion(.failure(error))
            return
        }
        video.markAsFinished()
        audio?.markAsFinished()
        writer.finishWriting { [writer, temporaryURL, outputURL] in
            do {
                guard writer.status == .completed else { throw writer.error ?? VideoError.encode }
                try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
                completion(.success(outputURL))
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                completion(.failure(error))
            }
        }
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: temporaryURL)
    }

    private func composite(source: CVPixelBuffer, destination: CVPixelBuffer, overlay: OverlaySample) throws {
        guard CVPixelBufferLockBaseAddress(source, .readOnly) == kCVReturnSuccess else { throw VideoError.pixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(source, .readOnly) }
        guard CVPixelBufferLockBaseAddress(destination, []) == kCVReturnSuccess else { throw VideoError.pixelBuffer }
        defer { CVPixelBufferUnlockBaseAddress(destination, []) }
        let sourceStride = CVPixelBufferGetBytesPerRow(source)
        let stride = CVPixelBufferGetBytesPerRow(destination)
        guard let from = CVPixelBufferGetBaseAddress(source), let to = CVPixelBufferGetBaseAddress(destination),
              let context = CGContext(data: to, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue |
                                          CGImageAlphaInfo.noneSkipFirst.rawValue) else { throw VideoError.pixelBuffer }
        if stride == sourceStride {
            memcpy(to, from, stride * height)
        } else {
            for row in 0..<height {
                memcpy(to.advanced(by: row * stride), from.advanced(by: row * sourceStride), width * 4)
            }
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        OverlayLayout.draw(overlay, mask: mask, in: size, context: context)
        context.flush()
    }
}
