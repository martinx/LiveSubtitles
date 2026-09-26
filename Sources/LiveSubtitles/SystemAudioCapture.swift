//
//  SystemAudioCapture.swift
//  LiveSubtitles
//
//  Captures everything the Mac is playing (ScreenCaptureKit system audio) and
//  hands it on as 16 kHz mono buffers - exactly what the speech model wants, so
//  nothing is resampled on the hot path.
//

import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia

enum CaptureError: LocalizedError {
    case noDisplay
    case unexpectedAudioFormat

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available to capture audio from."
        case .unexpectedAudioFormat:
            return "ScreenCaptureKit delivered an unexpected audio format."
        }
    }
}

final class SystemAudioCapture: NSObject {
    private let sampleRate = 16000
    private let channelCount = 1

    private var stream: SCStream?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?

    /// Fed every buffer alongside the transcriber, so a session's audio is kept whether or not
    /// the recogniser is keeping up. Set before `start()`.
    var recorder: SessionRecorder?
    private let sampleQueue = DispatchQueue(label: "com.local.LiveSubtitles.audio", qos: .userInteractive)

    /// Create this before calling `start()`.
    func makeAudioStream() -> AsyncStream<AVAudioPCMBuffer> {
        AsyncStream(bufferingPolicy: .unbounded) { continuation in
            self.continuation = continuation
        }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = sampleRate
        configuration.channelCount = channelCount
        // Only audio is used; keep the video side of the stream negligible.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        self.stream = stream
        try await stream.startCapture()
    }

    func stop() async {
        continuation?.finish()
        continuation = nil
        try? await stream?.stopCapture()
        stream = nil
    }
}

extension SystemAudioCapture: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[capture] stream stopped: \(error.localizedDescription)")
    }
}

extension SystemAudioCapture: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let buffer = Self.makePCMBuffer(from: sampleBuffer) else { return }
        recorder?.append(buffer)
        continuation?.yield(buffer)
    }

    private static func makePCMBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription),
              let format = AVAudioFormat(streamDescription: streamDescription) else {
            return nil
        }

        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else {
            return nil
        }
        buffer.frameLength = frames

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
