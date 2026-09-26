import XCTest
@testable import LiveSubtitlesKit

final class HistoryStoreTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-test-\(UUID().uuidString).sqlite")
    }

    override func tearDownWithError() throws {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }

    func testSessionLifecycleAndCues() async throws {
        let store = try HistoryStore(url: url)
        let session = try await store.startSession(source: "Netflix", modelID: "unified-320")
        try await store.appendCue(sessionID: session.id, startMs: 1760, endMs: 4280,
                                  text: "He would rather the meeting is scheduled for tomorrow.")
        try await store.appendCue(sessionID: session.id, startMs: 7800, endMs: 10_200,
                                  text: "I told him to wait outside until the police arrive.")
        try await store.endSession(session.id)

        let sessions = try await store.sessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].cueCount, 2)
        XCTAssertNotNil(sessions[0].endedAt)
        XCTAssertEqual(sessions[0].source, "Netflix")

        let cues = try await store.cues(in: session.id)
        XCTAssertEqual(cues.map(\.text).count, 2)
        XCTAssertEqual(cues[0].timestamp, "00:00:01")
        XCTAssertEqual(cues[1].startMs, 7800)
    }

    func testRenameRejectsBlankTitles() async throws {
        let store = try HistoryStore(url: url)
        let session = try await store.startSession(source: "VLC")
        try await store.rename(session.id, to: "  Severance S02E05  ")
        var sessions = try await store.sessions()
        XCTAssertEqual(sessions[0].title, "Severance S02E05")

        try await store.rename(session.id, to: "   ")
        sessions = try await store.sessions()
        XCTAssertEqual(sessions[0].title, "Severance S02E05", "a blank rename must not wipe the title")
    }

    func testSearchFindsCuesAcrossSessions() async throws {
        let store = try HistoryStore(url: url)
        let first = try await store.startSession(source: "A")
        let second = try await store.startSession(source: "B")
        try await store.appendCue(sessionID: first.id, startMs: 0, endMs: 1000,
                                  text: "The police arrived at dawn.")
        try await store.appendCue(sessionID: second.id, startMs: 0, endMs: 1000,
                                  text: "Nobody expected the police to come back.")
        try await store.appendCue(sessionID: second.id, startMs: 2000, endMs: 3000,
                                  text: "He waited outside.")

        let hits = try await store.search("police")
        XCTAssertEqual(hits.count, 2)
        XCTAssertTrue(hits.allSatisfy { $0.cue.text.lowercased().contains("police") })

        // A prefix should match while the word is still being typed.
        let prefix = try await store.search("outsi")
        XCTAssertEqual(prefix.count, 1)

        // Punctuation must not be read as FTS syntax.
        let punctuation = try await store.search("police AND (arrived)")
        XCTAssertNoThrow(punctuation)
    }

    func testNotesAttachToCuesAndSurviveTheSession() async throws {
        let store = try HistoryStore(url: url)
        let session = try await store.startSession(source: "C")
        try await store.appendCue(sessionID: session.id, startMs: 0, endMs: 1000,
                                  text: "It was not her fault.")
        let storedCues = try await store.cues(in: session.id)
        let cue = storedCues[0]

        try await store.addNote(sessionID: session.id, cueID: cue.id, kind: .word, text: "fault")
        try await store.addNote(sessionID: session.id, cueID: nil, kind: .note, text: "good episode")

        let notes = try await store.notes(in: session.id)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes.map(\.kind), [.word, .note])
        XCTAssertEqual(notes[0].cueID, cue.id)
    }

    func testDeleteSessionRemovesItsCues() async throws {
        let store = try HistoryStore(url: url)
        let session = try await store.startSession(source: "D")
        try await store.appendCue(sessionID: session.id, startMs: 0, endMs: 1000, text: "one")
        let inserted = try await store.cueCount()
        XCTAssertEqual(inserted, 1)

        try await store.deleteSession(session.id)
        let remainingCues = try await store.cueCount()
        let remainingSessions = try await store.sessions()
        XCTAssertEqual(remainingCues, 0, "cues must cascade with their session")
        XCTAssertTrue(remainingSessions.isEmpty)
    }

    func testExportFormats() async throws {
        let store = try HistoryStore(url: url)
        let session = try await store.startSession(source: "E", title: "Pilot")
        try await store.appendCue(sessionID: session.id, startMs: 1760, endMs: 4280, text: "Hello there.")
        let cues = try await store.cues(in: session.id)

        let srt = Exporter.render(cues: cues, session: session, format: .srt)
        XCTAssertTrue(srt.contains("00:00:01,760 --> 00:00:04,280"))
        XCTAssertTrue(srt.contains("Hello there."))
        XCTAssertTrue(srt.hasPrefix("1\n"))

        let text = Exporter.render(cues: cues, session: session, format: .text)
        XCTAssertEqual(text, "Hello there.\n")

        let markdown = Exporter.render(cues: cues, session: session, format: .markdown)
        XCTAssertTrue(markdown.contains("# Pilot"))
        XCTAssertTrue(markdown.contains("**00:00:01**"))
    }

    func testPersistenceAcrossReopen() async throws {
        let first = try HistoryStore(url: url)
        let session = try await first.startSession(source: "F")
        try await first.appendCue(sessionID: session.id, startMs: 0, endMs: 10, text: "persisted")

        let second = try HistoryStore(url: url)
        let cues = try await second.cues(in: session.id)
        XCTAssertEqual(cues.map(\.text), ["persisted"])
    }
}
