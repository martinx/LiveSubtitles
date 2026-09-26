//
//  CaptionController.swift
//  LiveSubtitles
//
//  Wires capture -> transcriber -> captions, keeps the session transcript, and
//  serves the menu actions (restart, export, settings).
//

import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor
final class CaptionController {
    let settings: Settings
    let captions: CaptionModel
    let transcript = TranscriptStore()

    private var capture: SystemAudioCapture?
    private var transcriber: StreamingTranscriber?
    private var panel: CaptionPanel?
    private var consumer: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    private lazy var settingsWindow = SettingsWindow()

    /// Fired whenever capture starts or stops, so the menu bar and Dock can show it.
    var onListeningChanged: ((Bool) -> Void)?
    private var isListening = false {
        didSet { if isListening != oldValue { onListeningChanged?(isListening) } }
    }

    init() {
        let settings = Settings()
        self.settings = settings
        self.captions = CaptionModel(settings: settings)

        // Re-apply the overlay whenever a setting changes. `objectWillChange` fires
        // before the value is stored, hence the hop to the next runloop turn.
        settings.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.applyActivationPolicy()
                    guard let panel = self.panel else { return }
                    panel.applyLayout(settings: self.settings)
                    panel.applyInteraction(settings: self.settings)
                }
            }
            .store(in: &cancellables)
    }

    /// Menu-bar only by default; the Dock icon is opt-in so the app can never take
    /// activation away from whatever is playing.
    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)
    }

    func start() {
        applyActivationPolicy()
        showPanel()
        restart()

        // LIVESUBTITLES_OPEN_SETTINGS=1 opens the settings window on launch.
        if ProcessInfo.processInfo.environment["LIVESUBTITLES_OPEN_SETTINGS"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.openSettings()
            }
        }
    }

    func restart() {
        engineTask?.cancel()
        engineTask = Task { [weak self] in
            guard let self else { return }
            await self.teardown()
            guard !Task.isCancelled else { return }
            await self.run()
        }
    }

    func clearSession() {
        transcript.clear()
        captions.clear()
    }

    func openSettings() {
        settingsWindow.show(
            settings: settings,
            transcript: transcript,
            onApplyEngine: { [weak self] in self?.restart() },
            onExport: { [weak self] in self?.exportTranscript() },
            onCopy: { [weak self] in self?.copyTranscript() },
            onClear: { [weak self] in self?.clearSession() }
        )
    }

    // MARK: - Pipeline

    private func showPanel() {
        guard panel == nil else { return }
        let panel = CaptionPanel(model: captions, settings: settings)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func run() async {
        captions.setStatus("Loading speech model… (first use downloads it)")
        captions.clear()

        let model = SpeechModel(rawValue: settings.modelID) ?? .default
        let transcriber = StreamingTranscriber(
            model: model,
            eouDebounceMs: settings.eouDebounceMs,
            pauseMs: Int(settings.newLineAfterSilence * 1000)
        )
        self.transcriber = transcriber

        let capture = SystemAudioCapture()
        self.capture = capture

        do {
            let audio = capture.makeAudioStream()
            let updates = try await transcriber.updates(from: audio)
            try await capture.start()
            isListening = true

            // Nothing to show while listening quietly; the panel stays empty until
            // the first words arrive.
            captions.setStatus("")

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
                        self.transcript.append(TranscriptCue(startMs: update.startMs,
                                                             endMs: update.endMs,
                                                             text: line))
                        self.captions.applyUtterance(line)
                        self.dumpSRTIfRequested()
                    }
                }
            }
        } catch {
            captions.setStatus("Error: \(error.localizedDescription)")
            isListening = false
        }
    }

    private func teardown() async {
        isListening = false
        consumer?.cancel()
        consumer = nil
        await capture?.stop()
        capture = nil
        await transcriber?.stop()
        transcriber = nil
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
