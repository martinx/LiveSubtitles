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
                        let line = Self.readable(update.text)
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
        }
    }

    private func teardown() async {
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

    /// The streaming model emits lowercase text without punctuation; a light touch
    /// makes exported subtitles readable.
    private static func readable(_ text: String) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return line }
        line = line.prefix(1).uppercased() + line.dropFirst()
        if let last = line.last, !".!?…".contains(last) {
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
