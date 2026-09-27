//
//  Review.swift
//  LiveSubtitlesKit
//
//  Spaced repetition for the vocabulary.
//
//  Without this the vocabulary list is a warehouse: words go in, nothing comes out, and
//  nothing is remembered. Saving a word is the easy half; being asked for it again later is
//  the half that does the work.
//
//  The schedule is a plain Leitner ladder rather than SM-2. Four grades map onto a small
//  number of steps, which is enough to be useful and simple enough to reason about when it
//  goes wrong.
//

import Foundation

/// How well the word was recalled.
public enum ReviewGrade: String, Sendable, CaseIterable {
    case forgot      // 忘记
    case hard        // 模糊
    case good        // 记得
    case easy        // 很简单

    var step: Int {
        switch self {
        case .forgot: return -2     // back down the ladder, and seen again today
        case .hard:   return -1
        case .good:   return 1
        case .easy:   return 2
        }
    }
}

/// A word with its review state.
public struct VocabularyCard: Identifiable, Hashable, Sendable {
    public let term: String
    public let gloss: String?
    public let occurrences: Int
    public let familiarity: Int      // 0…5
    public let dueAt: Date?
    public let reviewCount: Int

    public var id: String { term.lowercased() }

    public var isMastered: Bool { familiarity >= 5 }

    public var isDue: Bool {
        guard !isMastered else { return false }
        guard let dueAt else { return true }
        return dueAt <= Date()
    }

    /// The ladder, in words, for the list.
    public var state: String {
        if isMastered { return "Mastered" }
        if reviewCount == 0 { return "New" }
        return familiarity <= 1 ? "Learning" : "Familiar"
    }
}

extension HistoryStore {
    /// The vocabulary with its review state, newest words first when nothing is due.
    public func vocabularyCards() throws -> [VocabularyCard] {
        let saved = try connection.query("""
            SELECT LOWER(text) AS term, MIN(text), COUNT(*), MIN(createdAt)
            FROM notes WHERE kind IN ('word', 'phrase')
            GROUP BY LOWER(text);
            """) { row in
            (term: row.string(0), shown: row.string(1),
             count: Int(row.int(2)), first: row.double(3))
        }
        let state = try reviewState()

        return saved.map { entry in
            let saved = state[entry.term]
            return VocabularyCard(term: entry.shown,
                                  gloss: nil,
                                  occurrences: entry.count,
                                  familiarity: saved?.familiarity ?? 0,
                                  dueAt: saved?.dueAt,
                                  reviewCount: saved?.reviewCount ?? 0)
        }
        .sorted { left, right in
            // Due first, then never seen, then the rest.
            if left.isDue != right.isDue { return left.isDue }
            return left.term.localizedCaseInsensitiveCompare(right.term) == .orderedAscending
        }
    }

    /// The cards to work through now: anything due, oldest first.
    public func dueVocabulary(limit: Int = 20) throws -> [VocabularyCard] {
        Array(try vocabularyCards().filter(\.isDue).prefix(limit))
    }

    /// Records how a card went and schedules it again.
    public func recordReview(term: String, grade: ReviewGrade) throws {
        let key = term.lowercased()
        var state = try reviewState()[key] ?? ReviewState(familiarity: 0,
                                                          dueAt: nil,
                                                          reviewCount: 0)
        state.familiarity = min(5, max(0, state.familiarity + grade.step))
        state.reviewCount += 1
        state.dueAt = Self.nextDue(familiarity: state.familiarity, grade: grade)

        try connection.run("""
            INSERT INTO vocabulary (term, familiarity, dueAt, reviewCount, updatedAt)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(term) DO UPDATE SET
                familiarity = excluded.familiarity,
                dueAt       = excluded.dueAt,
                reviewCount = excluded.reviewCount,
                updatedAt   = excluded.updatedAt;
            """, [.text(key), .int(Int64(state.familiarity)),
                  .double(state.dueAt?.timeIntervalSince1970 ?? 0),
                  .int(Int64(state.reviewCount)),
                  .double(Date().timeIntervalSince1970)])
    }

    struct ReviewState {
        var familiarity: Int
        var dueAt: Date?
        var reviewCount: Int
    }

    private func reviewState() throws -> [String: ReviewState] {
        var states: [String: ReviewState] = [:]
        for row in try connection.query("SELECT term, familiarity, dueAt, reviewCount FROM vocabulary;") { row in
            (term: row.string(0), familiarity: Int(row.int(1)),
             due: row.double(2), count: Int(row.int(3)))
        } {
            states[row.term] = ReviewState(
                familiarity: row.familiarity,
                dueAt: row.due > 0 ? Date(timeIntervalSince1970: row.due) : nil,
                reviewCount: row.count)
        }
        return states
    }

    /// A ladder rather than a formula: a word answered well comes back in a day, then three,
    /// then a week, then a month; a word forgotten comes back today.
    private static func nextDue(familiarity: Int, grade: ReviewGrade) -> Date {
        if grade == .forgot { return Date().addingTimeInterval(10 * 60) }
        let days: [Double] = [0, 0.5, 1, 3, 7, 30]
        let index = min(familiarity, days.count - 1)
        return Date().addingTimeInterval(days[index] * 24 * 60 * 60)
    }
}
