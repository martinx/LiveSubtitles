//
//  StreamingTranscriber.swift
//  LiveSubtitles
//
//  Streaming English speech-to-text on the Apple Neural Engine, built on
//  Parakeet EOU (FluidAudio).
//
//  Parakeet EOU is a cache-aware streaming model: it decodes one chunk at a time
//  and reports partial text continuously, so words reach the screen about as fast
//  as they are spoken.
//
//  Two engine behaviours shape this wrapper:
//
//   1. Its callbacks report the *whole transcript so far*, so the part already
//      turned into cues is stripped off and only the new tail is displayed.
//
//   2. Its end-of-utterance latch can only confirm once per stream (see
//      `evaluateEouDebounce`: `!alreadyConfirmed`), so cues cannot be driven by it
//      without calling `reset()` - which would wipe the encoder context (worse
//      accuracy) and clip up to a chunk of audio (lost syllables in fast dialogue).
//      Cue boundaries are therefore derived here from the audio itself, and the
//      engine is never reset.
//
//  Everything below the public API runs on one ordered consumer, so the audio is
//  fed to the model in order and the model is only ever touched from one place.
//

import Foundation
import AVFoundation
import FluidAudio

/// Streaming chunk size, exposed without leaking FluidAudio's types.
enum CaptionChunk: Int {
    case ms160 = 160
    case ms320 = 320
    case ms1280 = 1280

    var fluidChunkSize: StreamingChunkSize {
        switch self {
        case .ms160: return .ms160
        case .ms320: return .ms320
        case .ms1280: return .ms1280
        }
    }
}

/// One caption update from the engine.
struct CaptionUpdate {
    enum Kind {
        /// Text still being spoken; replaces itself as the model revises.
        case partial
        /// A finished cue, safe to export.
        case utterance
        /// The audio itself has been quiet long enough that the next words should
        /// start a new line. Detected from the audio, not from the model's output:
        /// the model keeps emitting hallucinated words through silence, so "no new
        /// text" is not a usable pause signal.
        case pause
    }

    let kind: Kind
    let text: String
    /// Absolute cue bounds in milliseconds since capture started (utterances only),
    /// taken from the model's own token alignment rather than from wall-clock.
    var startMs: Int = 0
    var endMs: Int = 0
}

/// Single-slot, lock-guarded hand-off from FluidAudio's callback to the pump.
private final class Mailbox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?

    func store(_ newValue: Value) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func take() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let taken = value
        value = nil
        return taken
    }
}

final class StreamingTranscriber {
    /// A cue ends once the model has produced no new words for this long. Using the
    /// model's own output as the pause signal avoids tuning an energy threshold
    /// against whatever background music the show happens to have.
    private static let pauseToEndCueMs = 700
    /// ...but only if the cue already says something worth showing.
    private static let minimumCueMs = 1000
    /// Never let a cue grow past this, even through wall-to-wall dialogue.
    private static let maximumCueWords = 22

    /// Set LIVESUBTITLES_DEBUG=1 to trace latency, cues and pause detection.
    private static let debugLogging = ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil

    /// How fast the adaptive peak decays per 20 ms buffer (~1 dB per second).
    private static let peakDecay: Float = 0.998
    /// Audio this far below the recent peak counts as quiet.
    private static let quietRatio: Float = 0.3
    /// ...but never treat near-silence in a very quiet mix as speech.
    private static let absoluteFloor: Float = 0.0015

    private let manager: StreamingEouAsrManager
    private let pauseMs: Int
    private var pump: Task<Void, Never>?

    /// - Parameters:
    ///   - chunk: `.ms160` = minimum latency, `.ms320` / `.ms1280` = more accurate.
    ///   - eouDebounceMs: how much silence the model wants before it calls an utterance done.
    ///   - pauseMs: how much quiet audio ends the current line. 0 disables it.
    init(chunk: CaptionChunk = .ms160, eouDebounceMs: Int = 600, pauseMs: Int = 3000) {
        manager = StreamingEouAsrManager(chunkSize: chunk.fluidChunkSize,
                                         eouDebounceMs: eouDebounceMs)
        self.pauseMs = pauseMs
    }

    /// Loads the model (downloading it on first use), then consumes `audio` forever,
    /// emitting caption updates as they are decoded.
    func updates(from audio: AsyncStream<AVAudioPCMBuffer>) async throws -> AsyncStream<CaptionUpdate> {
        try await manager.loadModels()

        let (updates, continuation) = AsyncStream<CaptionUpdate>.makeStream(
            bufferingPolicy: .unbounded
        )

        let partials = Mailbox<String>()
        await manager.setPartialCallback { text in
            partials.store(text)
        }

        // One ordered consumer, detached from the main actor so caption rendering can
        // never throttle audio intake.
        let manager = self.manager
        let pauseMs = self.pauseMs
        pump = Task.detached {
            var transcript = ""
            var consumed = 0          // characters already turned into cues
            var samplesFed = 0
            var tokenCursor = 0       // index of the first token of the current cue
            var msSinceNewWords = 0
            var lastLive = ""
            // Pause detection runs on the audio, independently of what the model
            // decides to emit. `peakLevel` follows the loudest audio of the last few
            // seconds so the threshold adapts to the show's own volume.
            var peakLevel: Float = 0
            var quietMs = 0
            var pauseAnnounced = false

            do {
                for await buffer in audio {
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()

                    let frames = Int(buffer.frameLength)
                    samplesFed += frames

                    let energy = Self.rms(buffer)
                    peakLevel = max(energy, peakLevel * Self.peakDecay)
                    let isQuiet = energy < max(Self.absoluteFloor, peakLevel * Self.quietRatio)
                    if isQuiet {
                        quietMs += frames / 16
                    } else {
                        quietMs = 0
                        if pauseAnnounced, Self.debugLogging {
                            print("[pause] speech resumed (level \(Self.db(energy)) dB)")
                        }
                        pauseAnnounced = false
                    }

                    if pauseMs > 0, !pauseAnnounced, quietMs >= pauseMs {
                        pauseAnnounced = true
                        if Self.debugLogging {
                            print("[pause] \(pauseMs)ms of quiet (level \(Self.db(energy)) dB, "
                                  + "peak \(Self.db(peakLevel)) dB) -> new line next")
                        }
                        continuation.yield(CaptionUpdate(kind: .pause, text: ""))
                    }

                    // The model only reports when it decoded something, so "no news"
                    // counts as a pause. All O(1) work, no audio analysis.
                    if let latest = partials.take(), latest != transcript {
                        transcript = latest
                        msSinceNewWords = 0
                    } else {
                        msSinceNewWords += frames / 16
                    }

                    guard transcript.count > consumed else { continue }

                    let pending = String(transcript.dropFirst(consumed))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !pending.isEmpty else { continue }

                    let nowMs = samplesFed / 16
                    let words = pending.split(separator: " ").count
                    let ended = msSinceNewWords >= Self.pauseToEndCueMs
                    let tooLong = words >= Self.maximumCueWords

                    if ended || tooLong {
                        // One actor call per cue: the token timeline gives the real speech
                        // bounds, so exported .srt lines line up with the audio.
                        let stamps = await manager.getTokenTimestampsMs()
                        let endMs = stamps.last ?? nowMs
                        let startMs = tokenCursor < stamps.count ? stamps[tokenCursor] : endMs
                        tokenCursor = stamps.count
                        continuation.yield(CaptionUpdate(kind: .utterance,
                                                         text: pending,
                                                         startMs: startMs,
                                                         endMs: endMs))
                        consumed = transcript.count
                        msSinceNewWords = 0
                        lastLive = ""
                    } else if pending != lastLive {
                        continuation.yield(CaptionUpdate(kind: .partial, text: pending))
                        lastLive = pending
                    }
                }

                // Flush whatever is left when capture stops.
                let tail = String(transcript.dropFirst(consumed))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    let stamps = await manager.getTokenTimestampsMs()
                    continuation.yield(CaptionUpdate(kind: .utterance,
                                                     text: tail,
                                                     startMs: tokenCursor < stamps.count ? stamps[tokenCursor] : 0,
                                                     endMs: stamps.last ?? samplesFed / 16))
                }
            } catch {
                print("[transcriber] audio pump stopped: \(error.localizedDescription)")
            }
            continuation.finish()
        }

        return updates
    }

    func stop() async {
        pump?.cancel()
        pump = nil
        await manager.cleanup()
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<count {
            let value = samples[index]
            sum += value * value
        }
        return (sum / Float(count)).squareRoot()
    }

    private static func db(_ level: Float) -> String {
        guard level > 0 else { return "-inf" }
        return String(format: "%.1f", 20 * log10(level))
    }
}
