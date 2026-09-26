//
//  StreamingTranscriber.swift
//  LiveSubtitles
//
//  Streaming English speech-to-text on the Apple Neural Engine, built on
//  FluidAudio's streaming ASR models.
//
//  Everything below talks to the generic `StreamingAsrManager` protocol, so the
//  model is a setting rather than a hard-coded choice. Three families are offered:
//
//    Parakeet EOU 120M      - smallest and lowest latency, but no punctuation.
//    Parakeet Unified 0.6B  - 5x the parameters, punctuated and capitalised,
//                             with a low-latency tier that keeps look-ahead.
//    Nemotron 0.6B          - alternative large English model.
//
//  Two engine behaviours shape this wrapper:
//
//   1. The callbacks report the *whole transcript so far*, so the part already
//      turned into cues is stripped off and only the new tail is displayed.
//
//   2. Cue boundaries are derived here, from the audio and the clock. EOU models
//      latch their end-of-utterance signal after the first confirmation and the
//      other families do not expose one at all, so nothing depends on it. Pause
//      detection runs on the audio level, because every one of these models keeps
//      emitting hallucinated words through silence, which defeats a text timer.
//

import Foundation
import AVFoundation
import FluidAudio

/// The streaming models offered in Settings.
enum SpeechModel: String, CaseIterable, Identifiable {
    case eou160 = "parakeet-eou-160ms"
    case eou320 = "parakeet-eou-320ms"
    case unified320 = "parakeet-unified-320ms"
    case unified640 = "parakeet-unified-640ms"
    case nemotron560 = "nemotron-560ms"

    var id: String { rawValue }

    /// Quality-first default: the 0.6B model is punctuated and noticeably more
    /// accurate for ~0.2 s more latency than the 120M EOU model.
    static let `default`: SpeechModel = .unified320

    private var variant: StreamingModelVariant? { StreamingModelVariant(rawValue: rawValue) }

    var title: String { variant?.displayName ?? rawValue }

    /// Shown under the picker so the trade-off is visible without reading docs.
    var note: String {
        switch self {
        case .eou160:     return "120M · lowest latency · no punctuation"
        case .eou320:     return "120M · slightly more accurate"
        case .unified320: return "0.6B · best quality at low latency · punctuated"
        case .unified640: return "0.6B · same accuracy, less work per second"
        case .nemotron560: return "0.6B · alternative large English model"
        }
    }

    /// Build the streaming manager. EOU needs its debounce wired into the initialiser,
    /// which FluidAudio's generic factory does not expose, so it is special-cased.
    func makeManager(eouDebounceMs: Int) -> any StreamingAsrManager {
        switch self {
        case .eou160:
            return StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: eouDebounceMs)
        case .eou320:
            return StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: eouDebounceMs)
        case .unified320, .unified640, .nemotron560:
            if let variant {
                return variant.createManager()
            }
            return StreamingEouAsrManager(chunkSize: .ms160, eouDebounceMs: eouDebounceMs)
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
        /// start a new line.
        case pause
    }

    let kind: Kind
    let text: String
    /// Absolute cue bounds in milliseconds since capture started (utterances only).
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
    /// Set LIVESUBTITLES_DEBUG=1 to trace latency, cues and pause detection.
    private static let debugLogging = ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil

    /// A cue ends once the model has produced no new words for this long.
    private static let pauseToEndCueMs = 700
    /// Never let a cue grow past this, even through wall-to-wall dialogue.
    private static let maximumCueWords = 22
    /// How fast the adaptive peak decays per 20 ms buffer (~1 dB per second).
    private static let peakDecay: Float = 0.998
    /// Audio this far below the recent peak counts as quiet.
    private static let quietRatio: Float = 0.3
    /// ...but never treat near-silence in a very quiet mix as speech.
    private static let absoluteFloor: Float = 0.0015

    private let manager: any StreamingAsrManager
    private let pauseMs: Int
    private var pump: Task<Void, Never>?

    /// - Parameters:
    ///   - model: which streaming model to run; larger models are more accurate.
    ///   - eouDebounceMs: how much silence an EOU model wants before it calls an utterance done.
    ///   - pauseMs: how much quiet audio ends the current line. 0 disables it.
    init(model: SpeechModel = .default, eouDebounceMs: Int = 600, pauseMs: Int = 3000) {
        manager = model.makeManager(eouDebounceMs: eouDebounceMs)
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
        await manager.setPartialTranscriptCallback { text in
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
            var cueOpenMs = 0         // when the current cue's first words appeared
            var msSinceNewWords = 0
            var lastLive = ""
            var peakLevel: Float = 0
            var quietMs = 0
            var pauseAnnounced = false

            do {
                for await buffer in audio {
                    try await manager.appendAudio(buffer)
                    try await manager.processBufferedAudio()

                    let frames = Int(buffer.frameLength)
                    samplesFed += frames
                    let nowMs = samplesFed / 16

                    // ---- Pause detection, on the audio itself -------------------
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

                    // ---- Has the model produced anything new? -------------------
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

                    if cueOpenMs == 0 { cueOpenMs = nowMs }

                    let words = pending.split(separator: " ").count
                    let ended = msSinceNewWords >= Self.pauseToEndCueMs
                    let tooLong = words >= Self.maximumCueWords

                    if ended || tooLong {
                        // Cue bounds come from the audio clock, so they line up with
                        // playback for every model family.
                        let endMs = max(cueOpenMs + 300, nowMs - msSinceNewWords)
                        // The models occasionally emit a bare "?" or "." for noise;
                        // a cue with no actual words is not worth showing or exporting.
                        if pending.contains(where: { $0.isLetter || $0.isNumber }) {
                            continuation.yield(CaptionUpdate(kind: .utterance,
                                                             text: pending,
                                                             startMs: cueOpenMs,
                                                             endMs: endMs))
                        } else if Self.debugLogging {
                            print("[cue] dropped wordless \(pending)")
                        }
                        consumed = transcript.count
                        cueOpenMs = 0
                        msSinceNewWords = 0
                        lastLive = ""
                    } else if pending != lastLive {
                        // Only push a partial when it actually changed: the model reports
                        // once per chunk, but we are called once per 20 ms buffer.
                        continuation.yield(CaptionUpdate(kind: .partial, text: pending))
                        lastLive = pending
                    }
                }

                // Flush whatever is left when capture stops.
                let tail = String(transcript.dropFirst(consumed))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty {
                    let nowMs = samplesFed / 16
                    continuation.yield(CaptionUpdate(kind: .utterance,
                                                     text: tail,
                                                     startMs: cueOpenMs == 0 ? nowMs : cueOpenMs,
                                                     endMs: nowMs))
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
