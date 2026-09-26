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
    case blocked

    var errorDescription: String? {
        switch self {
        case .notFound:    return "No entry found online."
        case .unreachable: return "Couldn't reach Cambridge. Check the connection."
        case .blocked:     return "Cambridge is refusing requests from this Mac for now. Try again later."
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
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 404:              throw OnlineDictionaryError.notFound
            case 403, 429:         throw OnlineDictionaryError.blocked
            default:               break
            }
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw OnlineDictionaryError.notFound
        }

        let entry = parse(html, headword: cleaned)
        guard !entry.senses.isEmpty else { throw OnlineDictionaryError.notFound }
        return entry
    }

    // MARK: - Reading the page

    static func parse(_ html: String, headword: String) -> DictionaryEntry {
        let phonetics = captures(of: #"<span class="pron dpron"[^>]*>(.*?)</span>"#, in: html)
        let partsOfSpeech = captures(of: #"<span class="pos dpos"[^>]*>(.*?)</span>"#, in: html)
            .map { trim($0).lowercased() }

        // Walk the page one definition block at a time. Pairing all the definitions with all
        // the examples by index — which is what this did first — mismatches them as soon as a
        // sense has two examples or none, and a definition shown with someone else's example
        // is worse than no example.
        var senses: [DictionaryEntry.Sense] = []
        for (index, block) in definitionBlocks(in: html).enumerated() {
            let definitions = captures(of: #"<div class="def ddef_d db"[^>]*>(.*?)</div>"#, in: block)
                .map(trim)
                .filter { !$0.isEmpty }
            let examples = captures(of: #"<span class="examp dexamp"[^>]*>(.*?)</span>"#, in: block)
                .map(trim)
                .filter { !$0.isEmpty }

            for definition in definitions {
                senses.append(DictionaryEntry.Sense(
                    definition: definition,
                    example: examples.first,
                    label: nil))
            }
            // A block can hold phrases rather than a numbered sense; keep them as senses too.
            if definitions.isEmpty, let first = examples.first {
                senses.append(DictionaryEntry.Sense(definition: first, example: nil, label: nil))
            }
            if senses.count >= 8 { break }
            _ = index
        }

        // Cambridge lists several dictionaries per page; take the part of speech that belongs
        // to the first definition block rather than the first one on the page.
        let lead = definitionBlocks(in: html).first ?? html
        let partOfSpeech = captures(of: #"<span class="pos dpos"[^>]*>(.*?)</span>"#, in: lead)
            .first.map { trim($0).lowercased() } ?? partsOfSpeech.first

        return DictionaryEntry(headword: headword,
                               phonetics: phonetics.first.map(trim),
                               partOfSpeech: partOfSpeech,
                               senses: senses,
                               phrases: [])
    }

    /// Splits the page at each definition block, so a definition can be read together with the
    /// examples that follow it rather than with every example on the page.
    private static func definitionBlocks(in html: String) -> [String] {
        let marker = "def-block ddef_block" 
        guard html.contains(marker) else { return [html] }
        var blocks: [String] = []
        var rest = Substring(html)
        while let start = rest.range(of: marker) {
            let tail = rest[start.lowerBound...]
            if let next = tail.dropFirst(marker.count).range(of: marker) {
                blocks.append(String(tail[..<next.lowerBound]))
                rest = tail[next.lowerBound...]
            } else {
                blocks.append(String(tail))
                break
            }
        }
        return blocks
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
