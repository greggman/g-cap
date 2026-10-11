import AVFoundation
import CoreMedia

enum VideoCodec: String, CaseIterable, Identifiable {
    case hevc = "HEVC (H.265)"
    case h264 = "H.264"
    case proRes422 = "ProRes 422"
    case proRes422HQ = "ProRes 422 HQ"

    var id: String { rawValue }
    var isProRes: Bool { self == .proRes422 || self == .proRes422HQ }

    var avCodec: AVVideoCodecType {
        switch self {
        case .hevc: .hevc
        case .h264: .h264
        case .proRes422: .proRes422
        case .proRes422HQ: .proRes422HQ
        }
    }
}

enum Quality: String, CaseIterable, Identifiable {
    case high = "High"
    case veryHigh = "Very High"
    case maximum = "Maximum"

    var id: String { rawValue }

    /// Target bits per pixel per frame. Screen content is mostly sharp edges
    /// and text, so these are deliberately generous.
    var bitsPerPixel: Double {
        switch self {
        case .high: 0.1
        case .veryHigh: 0.2
        case .maximum: 0.4
        }
    }

    func bitrate(width: Int, height: Int, fps: Int) -> Int {
        Int(Double(width * height * fps) * bitsPerPixel)
    }
}

enum RecorderError: LocalizedError {
    case noFrames
    case writer(Error?)

    var errorDescription: String? {
        switch self {
        case .noFrames: "No video frames were captured."
        case .writer(let e): "Failed to write movie: \(e?.localizedDescription ?? "unknown error")"
        }
    }
}

/// Writes ScreenCaptureKit sample buffers to a .mov file.
/// Not thread safe: every call must come from the same serial queue.
final class Recorder {
    enum AudioSource { case system, microphone }

    let url: URL
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?
    private var sessionStart: CMTime?
    private var lastVideo: CMSampleBuffer?
    private var lastVideoTime = CMTime.invalid

    init(url: URL, width: Int, height: Int, fps: Int, codec: VideoCodec, quality: Quality,
         systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        var videoSettings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !codec.isProRes {
            var props: [String: Any] = [
                AVVideoAverageBitRateKey: quality.bitrate(width: width, height: height, fps: fps),
                AVVideoExpectedSourceFrameRateKey: fps,
                AVVideoMaxKeyFrameIntervalKey: fps * 2,
            ]
            if codec == .h264 {
                props[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            }
            videoSettings[AVVideoCompressionPropertiesKey] = props
        }
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        writer.add(videoInput)

        // ProRes gets uncompressed audio to match; otherwise high bitrate AAC.
        let pcm = codec.isProRes
        systemAudioInput = systemAudio ? Self.makeAudioInput(channels: 2, pcm: pcm) : nil
        micInput = microphone ? Self.makeAudioInput(channels: 1, pcm: pcm) : nil
        for input in [systemAudioInput, micInput].compactMap({ $0 }) {
            writer.add(input)
        }

        guard writer.startWriting() else { throw RecorderError.writer(writer.error) }
    }

    private static func makeAudioInput(channels: Int, pcm: Bool) -> AVAssetWriterInput {
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        let layoutData = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        var settings: [String: Any] = [
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: channels,
            AVChannelLayoutKey: layoutData,
        ]
        if pcm {
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 24
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        } else {
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = channels == 1 ? 128_000 : 256_000
        }
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        return input
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard writer.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStart == nil {
            writer.startSession(atSourceTime: pts)
            sessionStart = pts
        }
        guard videoInput.isReadyForMoreMediaData, pts > lastVideoTime || !lastVideoTime.isValid else { return }
        if videoInput.append(sampleBuffer) {
            lastVideo = sampleBuffer
            lastVideoTime = pts
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer, from source: AudioSource) {
        guard writer.status == .writing, let start = sessionStart,
              CMSampleBufferGetPresentationTimeStamp(sampleBuffer) >= start,
              let input = source == .system ? systemAudioInput : micInput,
              input.isReadyForMoreMediaData else { return }
        input.append(sampleBuffer)
    }

    func finish(completion: @escaping (Result<URL, Error>) -> Void) {
        guard sessionStart != nil else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            completion(.failure(RecorderError.noFrames))
            return
        }

        // ScreenCaptureKit only delivers frames when something changes, so
        // repeat the last frame at "now" to make the video run to the end.
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        if let last = lastVideo, now > lastVideoTime, videoInput.isReadyForMoreMediaData {
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: last, sampleTimingEntryCount: 1,
                                                  sampleTimingArray: &timing, sampleBufferOut: &copy)
            if let copy, videoInput.append(copy) {
                lastVideoTime = now
            }
        }
        lastVideo = nil

        writer.endSession(atSourceTime: lastVideoTime)
        videoInput.markAsFinished()
        systemAudioInput?.markAsFinished()
        micInput?.markAsFinished()
        writer.finishWriting { [writer, url] in
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(RecorderError.writer(writer.error)))
            }
        }
    }
}
