import Foundation
import ScreenCaptureKit

/// Owns the SCStream and routes its sample buffers to a Recorder.
/// All sample handling happens on one serial queue, which is also where the
/// Recorder is finished, so the Recorder never sees concurrent calls.
final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue = DispatchQueue(label: "com.greggman.gcap.capture", qos: .userInteractive)
    private var stream: SCStream?
    private var recorder: Recorder?

    /// Called on the main queue if the stream stops on its own (for example
    /// the user clicks "Stop" in the system's screen sharing menu).
    var onUnexpectedStop: ((Error) -> Void)?

    func start(filter: SCContentFilter, configuration: SCStreamConfiguration, recorder: Recorder) async throws {
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if configuration.capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        }
        if configuration.captureMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
        }
        queue.sync { self.recorder = recorder }
        self.stream = stream
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            _ = try? await finishRecorder()
            throw error
        }
    }

    func stop() async throws -> URL {
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        return try await finishRecorder()
    }

    private func finishRecorder() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                guard let recorder = self.recorder else {
                    continuation.resume(throwing: RecorderError.noFrames)
                    return
                }
                self.recorder = nil
                recorder.finish { continuation.resume(with: $0) }
            }
        }
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard let recorder, sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            guard Self.isCompleteFrame(sampleBuffer) else { return }
            recorder.appendVideo(sampleBuffer)
        case .audio:
            recorder.appendAudio(sampleBuffer, from: .system)
        case .microphone:
            recorder.appendAudio(sampleBuffer, from: .microphone)
        @unknown default:
            break
        }
    }

    private static func isCompleteFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return false }
        return status == .complete
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { self.onUnexpectedStop?(error) }
    }
}
