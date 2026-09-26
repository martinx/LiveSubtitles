//
//  DictionaryEntry.swift
//  LiveSubtitles
//
//  The system dictionary hands back one long string with ` | ` between fields and the
//  examples mixed into the definitions. Readable if you are a parser; not if you are
//  looking a word up mid-episode. This turns it into the shape a card can lay out.
//

import Foundation

struct DictionaryEntry: Equatable {
    struct Sense: Equatable, Identifiable {
        let id = UUID()
        let definition: String
        let example: String?
        let label: String?      // "1", "2", or a register note such as "[no object]"
    }

    let headword: String
    let phonetics: String?
    let partOfSpeech: String?
    let senses: [Sense]
    let phrases: [String]

    /// The first definition, for a compact one-line summary.
    var lead: String? { senses.first?.definition }
}

enum DictionaryParser {
    private typealias Sense = DictionaryEntry.Sense

    private static let partsOfSpeech: Set<String> = [
        "noun", "verb", "adjective", "adverb", "pronoun", "preposition", "conjunction",
        "interjection", "determiner", "article", "numeral", "abbreviation", "exclamation",
        "modal", "auxiliary",
    ]

    /// Phonetic characters the ODE uses; their presence is how a field is recognised as the
    /// pronunciation rather than another fragment of the entry.
    private static let phoneticMarkers = CharacterSet(charactersIn: "ˈˌəɪʊɛɔæʌθðʃʒŋāēīōū")

    static func parse(_ raw: String) -> DictionaryEntry? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // The tail sections (PHRASES, ORIGIN…) are not what someone wants mid-episode.
        let body = text.components(separatedBy: " PHRASES ").first ?? text
        let fields = body.components(separatedBy: " | ")
        guard let first = fields.first, !first.isEmpty else { return nil }

        // "apologize a·pol·o·gize" — keep the plain headword, drop the syllable split.
        let headword = first.components(separatedBy: " ").first ?? first

        var phonetics: String?
        var remainder: [String] = []
        for (index, field) in fields.dropFirst().enumerated() {
            let trimmed = field.trimmingCharacters(in: .whitespaces)
            if index == 0, !trimmed.isEmpty,
               trimmed.rangeOfCharacter(from: phoneticMarkers) != nil || trimmed.count <= 12 {
                phonetics = trimmed
                continue
            }
            remainder.append(trimmed)
        }

        var rest = remainder.joined(separator: " | ")
            .trimmingCharacters(in: .whitespaces)

        // Leading part of speech, possibly after a parenthetical like "(British English also
        // apologise)".
        var partOfSpeech: String?
        let head = rest.components(separatedBy: " ").prefix(6).joined(separator: " ")
        for word in head.components(separatedBy: " ") {
            let candidate = word.trimmingCharacters(in: CharacterSet(charactersIn: "().,;"))
                .lowercased()
            if partsOfSpeech.contains(candidate) {
                partOfSpeech = candidate
                if let range = rest.range(of: word) {
                    rest = String(rest[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                }
                break
            }
        }

        let senses = splitSenses(rest)
        guard !senses.isEmpty else {
            return DictionaryEntry(headword: headword, phonetics: phonetics,
                                   partOfSpeech: partOfSpeech,
                                   senses: [Sense(definition: rest, example: nil, label: nil)],
                                   phrases: [])
        }
        return DictionaryEntry(headword: headword, phonetics: phonetics,
                               partOfSpeech: partOfSpeech, senses: senses, phrases: [])
    }

    /// " • " separates senses inside one part of speech; the first ": " in each is the
    /// definition and what follows is an example.
    private static func splitSenses(_ text: String) -> [Sense] {
        var senses: [Sense] = []
        for chunk in text.components(separatedBy: " • ") {
            var piece = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }

            // A leading sense number, and any bracketed register note before it.
            var label: String?
            if let match = piece.range(of: #"^(\[\w[^\]]*\]|\([^)]*\))\s*"#, options: .regularExpression) {
                label = String(piece[match]).trimmingCharacters(in: .whitespaces)
                piece = String(piece[match.upperBound...])
            }
            if let match = piece.range(of: #"^\d+\s+"#, options: .regularExpression) {
                let number = String(piece[match]).trimmingCharacters(in: .whitespaces)
                label = label.map { "\($0) \(number)" } ?? number
                piece = String(piece[match.upperBound...])
            }

            if let colon = piece.range(of: ": ") {
                let definition = String(piece[..<colon.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let example = String(piece[colon.upperBound...])
                    .components(separatedBy: " | ").first?
                    .trimmingCharacters(in: .whitespaces)
                senses.append(Sense(definition: definition,
                                    example: (example?.isEmpty ?? true) ? nil : example,
                                    label: label))
            } else {
                senses.append(Sense(definition: piece, example: nil, label: label))
            }
        }
        return senses
    }
}
