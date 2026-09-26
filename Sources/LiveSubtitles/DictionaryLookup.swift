//
//  DictionaryLookup.swift
//  LiveSubtitles
//
//  The system's own dictionaries, offline and free. `DCSCopyTextDefinition` gives a real
//  entry — headword, pronunciation, part of speech, senses — for any word the user's Mac
//  has a dictionary for, with no model and no network.
//

import CoreServices
import Foundation
import NaturalLanguage

enum DictionaryLookup {
    /// The full entry, or nil when no installed dictionary knows the word.
    static func entry(for word: String) -> String? {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let raw = DCSCopyTextDefinition(nil, trimmed as CFString,
                                              CFRange(location: 0, length: trimmed.utf16.count)) else {
            return nil
        }
        let text = raw.takeRetainedValue() as String
        return text.isEmpty ? nil : text
    }

    /// Splits a line into the words worth looking up: no punctuation, no stray spaces.
    static func words(in text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        var words: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let word = String(text[range]).trimmingCharacters(in: .punctuationCharacters)
            if !word.isEmpty { words.append(word) }
            return true
        }
        return words
    }

    /// The canonical form to look up and to count occurrences with. "apologised" and
    /// "apologise" should be one vocabulary entry, not two.
    static func lemma(of word: String) -> String {
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = word
        let (tag, _) = tagger.tag(at: word.startIndex, unit: .word, scheme: .lemma)
        guard let lemma = tag?.rawValue, !lemma.isEmpty else { return word }
        return lemma
    }
}
