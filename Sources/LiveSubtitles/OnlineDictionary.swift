//
//  OnlineDictionary.swift
//  LiveSubtitles
//
//  A second opinion when the Mac's own dictionary has nothing, or has a definition written
//  for people who already know the word.
//
//  Fetched and shown inside the card rather than handed to a browser: leaving the app to
//  read one definition, and then having to find your way back to the episode, is worse than
//  no lookup at all.
//
//  The source is Cambridge rather than a JSON dictionary API because that is what actually
//  resolves from here — api.dictionaryapi.dev and Wiktionary both time out on this network,
//  and a source that cannot be reached is not a feature. The markup is read tolerantly: if
//  Cambridge changes their class names the lookup reports that it found nothing, rather than
//  showing something wrong.
//

import Foundation

enum OnlineDictionaryError: LocalizedError {
    case notFound
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notFound:    return "No entry found online."
        case .unreachable: return "Couldn't reach Cambridge. Check the connection."
        }
    }
}

enum OnlineDictionary {
    static func lookup(_ word: String) async throws -> DictionaryEntry {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty,
              let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://dictionary.cambridge.org/dictionary/english/\(encoded)")
        else { throw OnlineDictionaryError.notFound }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        // Cambridge serves a stripped page to unknown agents.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent")

        var data = Data()
        var response: URLResponse?
        for attempt in 0..<2 {
            do {
                (data, response) = try await URLSession.shared.data(for: request)
                break
            } catch {
                if attempt == 1 { throw OnlineDictionaryError.unreachable }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        if let http = response as? HTTPURLResponse, http.statusCode == 404 {
            throw OnlineDictionaryError.notFound
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw OnlineDictionaryError.notFound
        }

        let entry = parse(html, headword: cleaned)
        guard !entry.senses.isEmpty else { throw OnlineDictionaryError.notFound }
        return entry
    }

    // MARK: - Reading the page

    private static func parse(_ html: String, headword: String) -> DictionaryEntry {
        let definitions = captures(of: #"<div class="def ddef_d db"[^>]*>(.*?)</div>"#, in: html)
        let examples = captures(of: #"<span class="examp dexamp"[^>]*>(.*?)</span>"#, in: html)
        let parts = captures(of: #"<span class="pos dpos"[^>]*>(.*?)</span>"#, in: html)
        let phonetics = captures(of: #"<span class="pron dpron"[^>]*>(.*?)</span>"#, in: html)

        // Cambridge nests an example inside the definition block; pairing by order is right
        // often enough, and a missing example costs nothing.
        var senses: [DictionaryEntry.Sense] = []
        for (index, definition) in definitions.prefix(4).enumerated() {
            senses.append(DictionaryEntry.Sense(
                definition: trim(definition),
                example: index < examples.count ? trim(examples[index]) : nil,
                label: nil))
        }

        return DictionaryEntry(headword: headword,
                               phonetics: phonetics.first.map(trim),
                               partOfSpeech: parts.first.map { trim($0).lowercased() },
                               senses: senses,
                               phrases: [])
    }

    private static func captures(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }

    /// Strips the markup Cambridge wraps around the interesting words, and the entities.
    private static func trim(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: #"<[^>]+>"#, with: "",
                                                 options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'",
                        "&lt;": "<", "&gt;": ">", "&rsquo;": "’", "&lsquo;": "‘",
                        "&ldquo;": "“", "&rdquo;": "”", "&mdash;": "—", "&hellip;": "…"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
