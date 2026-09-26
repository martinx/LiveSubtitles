//
//  CaptionController.swift
//  LiveSubtitles
//
//  Wires capture -> transcriber -> captions, keeps the session transcript, and serves
//  the menu actions and global shortcuts.
//
//  Three states, because "stop" and "pause" cost different things:
//
//    stopped   no capture, model released   (~600 MB back; resuming reloads, ~2 s)
//    paused    no capture, model still warm (resume is instant)
//    listening capturing and transcribing
//
//  Pausing keeps the model loaded on purpose: the point of a pause is to come back in a
//  second, so paying the model load again would defeat it. Stopping is for "I am not
//  using this right now".
//

import AppKit
import Combine
import LiveSubtitlesKit
import UniformTypeIdentifiers

enum ListeningState {
    case stopped
    case listening
    case paused

    var description: String {
        switch self {
        case .stopped: return "Stopped"
        case .listening: return "Listening"
        case .paused: return "Paused"
        }
    }

    var symbolName: String {
        switch self {
        case .stopped: return "captions.bubble"
        case .listening: return "captions.bubble.fill"
        case .paused: return "pause.circle"
        }
    }
}

extension Notification.Name {
    /// Posted whenever the archive changes — a session starts or ends, or a line is written.
    ///
    /// The library window cannot poll the database and has no other way to know that the
    /// recording it is watching has produced a line, so the writer says so. Cues are written
    /// as they are finished, so this fires in real time during a session.
    static let liveSubtitlesHistoryChanged = Notification.Name("LiveSubtitlesHistoryChanged")
}

@MainActor
final class CaptionController {
    let settings: Settings
    let captions: CaptionModel
    let transcript = TranscriptStore()

    private var capture: SystemAudioCapture?
    private var transcriber: StreamingTranscriber?
    private var transcriberSignature = ""
    private var panel: CaptionPanel?
    private var consumer: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var hotKeySignature = ""

    /// Persistent history. Created on first use; a failure here must never stop captioning.
    private var history: HistoryStore?
    private var liveSession: Session?
    /// Keeps the audio this session was transcribed from. Created with the session.
    private var recorder: SessionRecorder?
    /// The engine options the running transcriber was built with.
    private var engineSettingsSignature = ""

    private lazy var settingsWindow = SettingsWindow()

    /// Fired on every state change so the menu bar icon and Dock can follow.
    var onStateChanged: ((ListeningState) -> Void)?

    private(set) var state: ListeningState = .stopped {
        didSet { if state != oldValue { onStateChanged?(state) } }
    }

    init() {
        let settings = Settings()
        self.settings = settings
        self.captions = CaptionModel(settings: settings)
        // Opened up front so the library can show existing history before anything new
        // is recorded. A failure is remembered as nil and surfaces in the window.
        history = try? HistoryStore()

        // Re-apply the overlay whenever a setting changes. `objectWillChange` fires
        // before the value is stored, hence the hop to the next runloop turn.
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applyActivationPolicy()
                    self.syncHotKeys()
                    self.applyEngineSettingsIfNeeded()
                    guard let panel = self.panel else { return }
                    panel.applyLayout(settings: self.settings)
                    panel.applyInteraction(settings: self.settings)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Flushes the recording. Called when the app is about to quit, because a recorder that
    /// is only torn down when its object is released never gets that chance on a quit — and
    /// without the flush the file has no header and cannot be opened at all.
    func flushRecording() {
        recorder?.close()
        recorder = nil
    }

    /// Menu-bar only by default; the Dock icon is opt-in so the app can never take
    /// activation away from whatever is playing. Not private: the View menu flips the
    /// setting and has to re-apply it.
    func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    func start() {
        applyActivationPolicy()
        showPanel()
        syncHotKeys()
        onStateChanged?(state)

        if settings.startAtLaunch {
            startListening()
        }
    }

    // MARK: - Start / pause / stop

    /// Begin listening, or resume from a pause. Both are safe to call repeatedly.
    func startListening() {
        engineTask?.cancel()
        engineTask = Task { [weak self] in
            await self?.beginSession()
        }
    }

    /// Stop capturing but keep the model loaded, so coming back is instant.
    func pauseListening() {
        engineTask?.cancel()
        engineTask = Task { [weak self] in
            await self?.endSession(releaseModel: false)
        }
    }

    /// Stop capturing and release the model.
    func stopListening() {
        engineTask?.cancel()
        engineTask = Task { [weak self] in
            await self?.endSession(releaseModel: true)
        }
    }

    /// Rebuild the engine from scratch, e.g. after an engine setting changed.
    func restartEngine() {
        engineTask?.cancel()
        engineTask = Task { [weak self] in
            guard let self else { return }
            await self.endSession(releaseModel: true)
            guard !Task.isCancelled else { return }
            await self.beginSession()
        }
    }

    private func beginSession() async {
        guard state != .listening else { return }

        let transcriber = await makeOrReuseTranscriber()
        let capture = SystemAudioCapture()
        self.capture = capture

        if state == .stopped {
            captions.setStatus("Loading speech model… (first use downloads it)")
            captions.clear()
        }

        do {
            let audio = capture.makeAudioStream()
            // Every session starts with a clean decoder, so a resume cannot replay the
            // tail of whatever was being said before the pause.
            let updates = try await transcriber.updates(from: audio, resettingDecoder: true)
            // The session and its recorder exist before capture starts, so the first words
            // are recorded too; attaching afterwards would lose the opening seconds.
            await beginHistorySession()
            capture.recorder = recorder

            try await capture.start()
            state = .listening
            captions.setStatus("")
            consume(updates)
        } catch {
            captions.setStatus("Error: \(error.localizedDescription)")
            self.capture = nil
            state = .stopped
        }
    }

    private func endSession(releaseModel: Bool) async {
        await endHistorySession()
        consumer?.cancel()
        consumer = nil
        await capture?.stop()
        capture = nil

        // The overlay goes quiet either way; the exported transcript is untouched.
        captions.clear()

        if releaseModel {
            await transcriber?.stop()
            transcriber = nil
            transcriberSignature = ""
            state = .stopped
        } else {
            state = .paused
        }
    }

    /// Engine settings are baked into the transcriber at construction, so a changed
    /// model or threshold means building a new one (and releasing the old model).
    private func makeOrReuseTranscriber() async -> StreamingTranscriber {
        let signature = engineSettingsSignature
        if let transcriber, signature == transcriberSignature {
            return transcriber
        }
        if let previous = transcriber {
            await previous.stop()
            transcriber = nil
        }

        let model = SpeechModel(rawValue: settings.modelID) ?? .default
        let created = StreamingTranscriber(model: model,
                                           eouDebounceMs: settings.eouDebounceMs,
                                           pauseMs: Int(settings.newLineAfterSilence * 1000))
        transcriber = created
        transcriberSignature = signature
        return created
    }

    private func consume(_ updates: AsyncStream<CaptionUpdate>) {
        consumer?.cancel()
        consumer = Task { @MainActor [weak self] in
            for await update in updates {
                guard let self else { return }
                switch update.kind {
                case .partial:
                    self.captions.applyPartial(update.text)

                case .pause:
                    // Quiet audio: the next sentence starts a new line.
                    self.captions.markPause()

                case .utterance:
                    let line = Self.finalize(update.text)
                    guard !line.isEmpty else { break }
                    let cue = TranscriptCue(startMs: update.startMs,
                                            endMs: update.endMs,
                                            text: line)
                    self.transcript.append(cue)
                    self.record(cue, text: line)
                    self.captions.applyUtterance(line)
                    self.dumpSRTIfRequested()
                }
            }
        }
    }

    /// Engine options are baked into the transcriber when it is constructed, so changing
    /// one has to rebuild it. Doing that automatically is what makes the engine settings
    /// as immediate as the cosmetic ones - no "apply and restart" step.
    ///
    /// Only while listening: a paused or stopped engine picks the new options up when it
    /// is next started, and resuming listening on its own would be a surprise.
    private func applyEngineSettingsIfNeeded() {
        let signature = "\(settings.modelID)|\(settings.eouDebounceMs)|\(Int(settings.newLineAfterSilence))"

        guard !engineSettingsSignature.isEmpty else {
            engineSettingsSignature = signature
            return
        }
        guard signature != engineSettingsSignature else { return }
        engineSettingsSignature = signature

        guard state == .listening else { return }
        restartEngine()
    }

    // MARK: - History

    /// Opens the database and starts a session. Every failure path here is soft: a history
    /// that cannot be written must not take captioning down with it.
    private func beginHistorySession() async {
        do {
            guard let history else { return }
            let source = NSWorkspace.shared.frontmostApplication?.localizedName ?? ""
            let model = SpeechModel(rawValue: settings.modelID) ?? .default
            let session = try await history.startSession(source: source, modelID: model.rawValue)
            liveSession = session

            // Start recording straight away. A failure here is reported and the session runs
            // without audio: losing the recording is much better than losing the captions.
            do {
                let url = try SessionRecorder.url(for: session.id)
                let made = try SessionRecorder(url: url, sampleRate: 16_000, channels: 1)
                recorder = made
                try await history.setAudioPath(url.path, for: session.id)
                if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
                    print("[rec] recording to \(url.lastPathComponent)")
                }
            } catch {
                recorder = nil
                captions.setStatus("Recording unavailable: \(error.localizedDescription)")
            }
            if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
                print("[history] session started — \(session.title)")
            }
            NotificationCenter.default.post(name: .liveSubtitlesHistoryChanged, object: nil)
        } catch {
            history = nil
            liveSession = nil
            captions.setStatus("History unavailable: \(error.localizedDescription)")
        }
    }

    private func endHistorySession() async {
        recorder?.close()
        recorder = nil
        capture?.recorder = nil
        guard let history, let session = liveSession else { return }
        try? await history.endSession(session.id)
        NotificationCenter.default.post(name: .liveSubtitlesHistoryChanged, object: nil)

        // Analyse in the background: the transcript is already saved and usable, and the
        // speaker pass takes about twenty seconds for an episode.
        // Switched off deliberately: the converter works as a standalone program but fails
        // inside the app with an opaque _GenericObjCError, and a pass that runs on every
        // session end and always fails is worse than no pass. The schema, the recorder and
        // the analyzer are all in place; this is the one switch to flip once that is fixed.
        if SessionAnalyzer.isEnabled,
           let url = try? SessionRecorder.url(for: session.id),
           FileManager.default.fileExists(atPath: url.path) {
            let store = history
            let id = session.id
            Task.detached(priority: .utility) {
                do {
                    let labelled = try await SessionAnalyzer.shared.analyze(
                        sessionID: id, audioURL: url, store: store)
                    if labelled > 0 {
                        await MainActor.run {
                            NotificationCenter.default.post(
                                name: .liveSubtitlesHistoryChanged, object: nil)
                        }
                    }
                } catch {
                    if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
                        print("[analyze] failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        if ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil {
            print("[history] session ended")
        }
        liveSession = nil
    }

    /// Mirrors one finished line into the archive.
    private func record(_ cue: TranscriptCue, text: String) {
        guard let history, let session = liveSession else { return }
        // The id, never the title: renaming the session in the library must not detach the
        // recording from it, and a UUID cannot be renamed.
        let sessionID = session.id
        Task {
            try? await history.appendCue(sessionID: sessionID,
                                         startMs: cue.startMs,
                                         endMs: cue.endMs,
                                         text: text)
            NotificationCenter.default.post(name: .liveSubtitlesHistoryChanged, object: nil)
        }
    }

    /// The library window shares one database and one session state with the pipeline.
    func historyStore() -> HistoryStore? { history }

    // MARK: - Global shortcuts

    /// Register the configured shortcuts. Re-registers only when they actually changed,
    /// because this is also called from the catch-all settings observer.
    func syncHotKeys() {
        let signature = [settings.startShortcut, settings.pauseShortcut, settings.stopShortcut]
            .map { $0?.storage ?? "-" }
            .joined(separator: ",")
        guard signature != hotKeySignature else { return }
        hotKeySignature = signature

        let debug = ProcessInfo.processInfo.environment["LIVESUBTITLES_DEBUG"] != nil
        var bindings: [(KeyShortcut, () -> Void)] = []
        if let shortcut = settings.startShortcut {
            bindings.append((shortcut, { [weak self] in
                if debug { print("[hotkey] start") }
                self?.startListening()
            }))
        }
        if let shortcut = settings.pauseShortcut {
            bindings.append((shortcut, { [weak self] in
                if debug { print("[hotkey] pause") }
                self?.pauseListening()
            }))
        }
        if let shortcut = settings.stopShortcut {
            bindings.append((shortcut, { [weak self] in
                if debug { print("[hotkey] stop") }
                self?.stopListening()
            }))
        }

        let rejected = GlobalHotKeyCenter.shared.replaceAll(with: bindings)
        if !rejected.isEmpty {
            print("[hotkey] already taken by another app: \(rejected.map(\.display).joined(separator: ", "))")
        }
    }

    // MARK: - Session

    func clearSession() {
        transcript.clear()
        captions.clear()
    }

    func openSettings() {
        settingsWindow.show(
            settings: settings,
            transcript: transcript,
            onApplyEngine: { [weak self] in self?.restartEngine() },
            onExport: { [weak self] in self?.exportTranscript() },
            onCopy: { [weak self] in self?.copyTranscript() },
            onClear: { [weak self] in self?.clearSession() }
        )
    }

    private func showPanel() {
        guard panel == nil else { return }
        let panel = CaptionPanel(model: captions, settings: settings)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    // MARK: - Export

    func exportTranscript() {
        guard !transcript.isEmpty else {
            presentInfo("Nothing to export yet — no speech has been captured.")
            return
        }

        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.nameFieldStringValue = "LiveSubtitles-\(Self.fileStamp()).srt"
        var types: [UTType] = []
        if let srt = UTType(filenameExtension: "srt") {
            types.append(srt)
        }
        types.append(.plainText)
        panel.allowedContentTypes = types

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self else { return }
                let isSRT = url.pathExtension.lowercased() == "srt"
                let content = isSRT ? self.transcript.srt() : self.transcript.plainText
                do {
                    try content.write(to: url, atomically: true, encoding: .utf8)
                } catch {
                    self.presentInfo("Could not write the file: \(error.localizedDescription)")
                }
            }
        }
    }

    func copyTranscript() {
        guard !transcript.isEmpty else {
            presentInfo("Nothing to copy yet — no speech has been captured.")
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(transcript.plainText, forType: .string)
    }

    /// Tidy a finished cue.
    ///
    /// A streaming model punctuates *volatile* text: it can insert a mark at exactly the
    /// point a cue was cut, which strands that mark at the start of the next cue, and it
    /// can leave a comma where the cut happened. The old "append a full stop unless it
    /// already ends in .!?" rule then turned that comma into ",.".
    static func finalize(_ text: String) -> String {
        let terminators: Set<Character> = [".", "!", "?", "…"]
        let punctuation: Set<Character> = [".", ",", "!", "?", ";", ":", "…", "·"]

        // 1. Drop marks stranded at the very start: they belong to the previous cue.
        var characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = characters.first, punctuation.contains(first) {
            characters.removeFirst()
            while characters.first == " " { characters.removeFirst() }
        }
        guard !characters.isEmpty else { return "" }

        // 2. Collapse a run of marks into the strongest one: ".." -> ".", ",." -> ".",
        //    ",," -> ",", while "?!" survives.
        var tidied: [Character] = []
        var index = 0
        while index < characters.count {
            let character = characters[index]
            guard punctuation.contains(character) else {
                tidied.append(character)
                index += 1
                continue
            }
            var run: [Character] = []
            while index < characters.count, punctuation.contains(characters[index]) {
                run.append(characters[index])
                index += 1
            }
            if run.contains("…") {
                tidied.append("…")
                continue
            }
            let marks = run.filter { terminators.contains($0) }
            var seen = Set<Character>()
            tidied.append(contentsOf: marks.isEmpty ? [run[0]] : marks.filter { seen.insert($0).inserted })
        }

        var line = String(tidied).trimmingCharacters(in: .whitespaces)
        guard let firstLetter = line.first else { return "" }
        line = firstLetter.uppercased() + line.dropFirst()

        // 3. Add a full stop only when the line ends in an actual word. Appending one
        //    after a comma is what produced ",.".
        if let last = line.last, last.isLetter || last.isNumber {
            line += "."
        }
        return line
    }

    /// Set LIVESUBTITLES_DUMP_SRT=/path/out.srt to mirror the session transcript to
    /// disk as it is recognised - handy for checking export without opening the panel.
    private func dumpSRTIfRequested() {
        guard let path = ProcessInfo.processInfo.environment["LIVESUBTITLES_DUMP_SRT"] else { return }
        try? transcript.srt().write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }

    private func presentInfo(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .informational
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func fileStamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter.string(from: Date())
    }
}
