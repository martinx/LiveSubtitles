//
//  SessionAnalyzer.swift
//  LiveSubtitles
//
//  The pass that runs after a session ends, over the audio that was kept.
//
//  It answers the one question the live pass cannot: who was speaking. The stream has no
//  memory of earlier voices, so it can only ever produce an undifferentiated wall of text;
//  given the whole episode at once, the speakers separate cleanly.
//
//  Two things learned the hard way and encoded here:
//    * FluidAudio reads audio through ExtAudioFile, which does not open an .m4a container.
//      The recording has to be rewritten as WAV first, which is what `toWAV` is for.
//    * The output is keyed `speakerId` / `startTimeSeconds`, not `speaker` / `start`.
//

import AVFoundation
import FluidAudio
import Foundation
import LiveSubtitlesKit

actor SessionAnalyzer {
    static let shared = SessionAnalyzer()

    /// On. What this gates had one bug left in it: reading past the end of a file throws, and
    /// in the app it throws `_GenericObjCError 0` rather than the documented `eofErr (-39)`,
    /// so a read that had completed was being treated as a failure.
    static let isEnabled = true

    /// On. The conversion that this gates had one bug left in it: reading past the end of a
    /// file throws, and in the app it throws `_GenericObjCError 0` rather than the documented
    /// `eofErr (-39)`, so a complete read was being read as a failure.

    /// Loaded once and kept: the model is 14 MB and loading it per session would be silly.
    private var diarizer: OfflineSortformerDiarizer?

    /// Separates the speakers in a finished session and writes the labels back.
    /// Returns how many lines were labelled.
    @discardableResult
    func analyze(sessionID: String, audioURL: URL, store: HistoryStore) async throws -> Int {
        let started = Date()
        let debug = ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil

        let wav: URL
        do { wav = try toWAV(audioURL) }
        catch {
            let ns = error as NSError
            if debug { print("[analyze] STEP toWAV failed: type=\(type(of: error)) domain=\(ns.domain) code=\(ns.code) \(error)") }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: wav) }

        let diarizer: OfflineSortformerDiarizer
        do { diarizer = try await loadedDiarizer() }
        catch {
            if debug { print("[analyze] STEP loadModel failed: \(error)") }
            throw error
        }
        if debug { print("[analyze] STEP loadModel ok") }

        let timeline: DiarizerTimeline
        do { timeline = try diarizer.processComplete(audioFileURL: wav) }
        catch {
            if debug { print("[analyze] STEP processComplete failed: \(error)") }
            throw error
        }
        if debug { print("[analyze] STEP processComplete ok, speakers=\(timeline.speakers.count)") }

        var ranges: [(start: Double, end: Double, speaker: String)] = []
        for speaker in timeline.speakers.values {
            for segment in speaker.finalizedSegments {
                ranges.append((Double(segment.startTime),
                               Double(segment.endTime),
                               String(speaker.index)))
            }
        }
        guard !ranges.isEmpty else { return 0 }

        // Each line takes the speaker it overlaps most; a line straddling a change of speaker
        // goes to whoever held the floor longest.
        let cues = try await store.cues(in: sessionID)
        var assignments: [CueSpeaker] = []
        for cue in cues {
            let start = Double(cue.startMs) / 1000
            let end = Double(cue.endMs) / 1000
            let best = ranges
                .map { (overlap: min($0.end, end) - max($0.start, start), speaker: $0.speaker) }
                .filter { $0.overlap > 0 }
                .max { $0.overlap < $1.overlap }
            if let best { assignments.append(CueSpeaker(cueID: cue.id, speaker: best.speaker)) }
        }
        try await store.applySpeakers(assignments)

        if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
            let speakers = Set(assignments.map(\.speaker)).sorted()
            print("[analyze] \(assignments.count) lines labelled, speakers=\(speakers), "
                  + "took \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        }
        return assignments.count
    }

    private func loadedDiarizer() async throws -> OfflineSortformerDiarizer {
        if let diarizer { return diarizer }
        let made = OfflineSortformerDiarizer()
        // Downloads the 14 MB model the first time; the CLI had already fetched it, so this
        // normally finds it in the cache.
        try await made.initializeFromHuggingFace()
        diarizer = made
        return made
    }

    /// Rewrites a recording as 16 kHz mono WAV, which is what the diarizer can open.
    ///
    /// The session's own audio is already 16 kHz mono, so this is a container change rather
    /// than a resample — but it is written as a general copy so a differently shaped file
    /// still comes out at the rate the model wants.
    private func toWAV(_ source: URL) throws -> URL {
        let debug = ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil
        func step(_ message: String) { if debug { print("[analyze]   \(message)") } }

        step("opening source \(source.lastPathComponent)")
        let input = try AVAudioFile(forReading: source)
        step("source open ok, frames=\(input.length)")

        // Written beside the recording rather than to the temporary directory: that folder is
        // written to on every session, so it is known to work, and it removes one variable
        // from a conversion that failed here while working standalone.
        let target = source.deletingLastPathComponent()
            .appendingPathComponent("analyze-\(UUID().uuidString).wav")
        step("target \(target.path)")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        step("creating output file")
        var output: AVAudioFile? = try AVAudioFile(forWriting: target, settings: settings)
        step("output created, format=\(output?.processingFormat.description ?? "?")")

        // Read into the input's own format and let AVAudioFile convert on the way out.
        var writtenFrames = 0
        let chunk: AVAudioFrameCount = 16_384
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat,
                                            frameCapacity: chunk) else {
            throw AnalysisError.unreadable
        }
        while true {
            do {
                try input.read(into: buffer)
            } catch {
                // AVAudioFile signals the end of a file by throwing rather than by returning
                // an empty buffer, and the error is not always the documented eofErr (-39):
                // in the app the same read produces _GenericObjCError code 0. Both mean the
                // stream is finished. Treating either as a failure aborted the analysis after
                // every frame had already been written — which is what happened, twice.
                let nsError = error as NSError
                let endOfStream = (nsError.domain == NSOSStatusErrorDomain && nsError.code == -39)
                    || nsError.domain == "Foundation._GenericObjCError"
                if endOfStream {
                    step("read reached end of stream: \(nsError.domain)/\(nsError.code)")
                    break
                }
                step("READ failed: \(nsError.domain)/\(nsError.code)")
                throw error
            }
            if buffer.frameLength == 0 { break }
            do { try output?.write(from: buffer) }
            catch {
                let ns = error as NSError
                step("WRITE failed after \(writtenFrames) frames: \(ns.domain)/\(ns.code)")
                throw error
            }
            writtenFrames += Int(buffer.frameLength)
        }
        step("wrote \(writtenFrames) frames")

        // The WAV header — including its data size — is only written when the file is
        // released. Returning while it is still alive leaves a file that reads as zero
        // seconds long, which is exactly what the isolated test showed.
        output = nil
        return target
    }
}

enum AnalysisError: LocalizedError {
    case unreadable
    var errorDescription: String? { "The recording could not be read." }
}
