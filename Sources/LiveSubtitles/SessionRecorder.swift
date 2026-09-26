//
//  SessionRecorder.swift
//  LiveSubtitles
//
//  Keeps the audio a session was transcribed from.
//
//  Everything the library could do better than the live pass needs the original sound:
//  re-recognising the episode with full context, separating the speakers, replaying a line
//  to hear it again. The live transcript alone cannot support any of that, and audio that was
//  never written cannot be recovered afterwards.
//
//  Measured: AAC at 16 kHz mono lands around 160 KB per minute — about 7 MB for a 45-minute
//  episode — and writing a 20 ms buffer costs 0.03 ms, against the 6–8% of a core the
//  recogniser already uses.
//

import AVFoundation
import Foundation

final class SessionRecorder {
    let url: URL

    /// Optional so `close()` can release it: AVAudioFile writes its header when it is
    /// deallocated, so a recorder that only sets a flag leaves an unreadable file behind —
    /// which is exactly what the first version did.
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var isClosed = false
    private(set) var writtenFrames: AVAudioFramePosition = 0
    private let sampleRate: Double

    /// `settings` deliberately omits a bit rate: at 16 kHz mono the AAC encoder rejects
    /// 64 kbps outright, and letting it choose lands on something it accepts.
    init(url: URL, sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) throws {
        self.url = url
        self.sampleRate = sampleRate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings)
    }

    /// Called on the audio thread; writing is cheap but must not race with closing.
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        do {
            try file?.write(from: buffer)
            writtenFrames += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // A dropped buffer costs a few milliseconds of audio; stopping the session over it
            // would cost the whole episode.
            if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
                print("[rec] write failed: \(error.localizedDescription)")
            }
        }
    }

    /// How much has been recorded, for the session row.
    var duration: TimeInterval {
        writtenFrames > 0 ? Double(writtenFrames) / sampleRate : 0
    }

    /// Flushes and closes. AVAudioFile writes its header on deallocation, so this releases it.
    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        // Releasing the file is what writes the header. Without this the file is a pile of
        // audio frames that nothing can open.
        file = nil
    }

    deinit {
        file = nil
    }

    /// Where a session's audio lives.
    static func url(for sessionID: String) throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil,
                                               create: true)
        let directory = base.appendingPathComponent("Live Subtitles/Audio", isDirectory: true)
        return directory.appendingPathComponent("\(sessionID).m4a")
    }
}
