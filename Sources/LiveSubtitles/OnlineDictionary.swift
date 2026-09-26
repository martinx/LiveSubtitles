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
//  Wiktionary, because it is the only source that both resolves from this network and is
//  worth reading. The road here: api.dictionaryapi.dev and Wiktionary timed out before the
//  VPN was on; Cambridge answered, but only until Cloudflare noticed the requests and
//  started returning 403. Reading HTML classes would also have broken the first time
//  Cambridge re-titled a div. Wiktionary answers with JSON, which has none of those problems,
//  and — being a wiki — carries the senses a learner's dictionary leaves out.
//

import Foundation

enum OnlineDictionaryError: LocalizedError {
    case notFound
    case unreachable

    var errorDescription: String? {
        switch self {
        case .notFound:    return "No entry found on Wiktionary."
        case .unreachable: return "Couldn't reach Wiktionary. Check the connection."
        }
    }
}

enum OnlineDictionary {
    static func lookup(_ word: String) async throws -> DictionaryEntry {
        let cleaned = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty,
              let encoded = cleaned.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(encoded)")
        else { throw OnlineDictionaryError.notFound }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("LiveSubtitles/1.0 (macOS; on-device subtitle reader)",
                         forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

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
        guard let payload = try? JSONDecoder().decode([String: [Group]].self, from: data) else {
            throw OnlineDictionaryError.unreachable
        }
        // The endpoint answers in several languages; the English section is the one wanted.
        guard let groups = payload["en"], !groups.isEmpty else {
            throw OnlineDictionaryError.notFound
        }
        let entry = makeEntry(from: groups, headword: cleaned)
        guard !entry.senses.isEmpty else { throw OnlineDictionaryError.notFound }
        return entry
    }

    // MARK: - The wire format

    private struct Group: Decodable {
        let partOfSpeech: String?
        let definitions: [Definition]

        struct Definition: Decodable {
            let definition: String?
            let parsedExamples: [ParsedExample]?
            let examples: [String]?

            struct ParsedExample: Decodable {
                let example: String?
            }

            /// Wiktionary mixes plain and pre-parsed examples; take whichever is there.
            var firstExample: String? {
                if let parsed = parsedExamples?.first?.example, !parsed.isEmpty { return parsed }
                return examples?.first
            }
        }
    }

    private static func makeEntry(from groups: [Group], headword: String) -> DictionaryEntry {
        var senses: [DictionaryEntry.Sense] = []
        var partOfSpeech: String?

        for group in groups {
            let label = group.partOfSpeech?.lowercased()
            if partOfSpeech == nil { partOfSpeech = label }
            // Label each sense whenever the sense could belong to more than one part of
            // speech — either because a group has several senses, or because the page has
            // several groups. Without this, "soaked" showed a verb capsule above adjective
            // meanings, since the capsule comes from the first group and the senses do not.
            let needsLabel = groups.count > 1 || group.definitions.count > 1

            for definition in group.definitions.prefix(6) {
                guard let raw = definition.definition else { continue }
                let text = plain(raw)
                guard !text.isEmpty else { continue }
                senses.append(DictionaryEntry.Sense(
                    definition: text,
                    example: definition.firstExample.map(plain),
                    label: needsLabel ? label : nil))
            }
            if senses.count >= 8 { break }
        }

        return DictionaryEntry(headword: headword,
                               phonetics: nil,     // Wiktionary's definition endpoint omits IPA
                               // Only meaningful when every sense agrees; otherwise each
                               // sense carries its own label and this would contradict them.
                               partOfSpeech: groups.count == 1 ? partOfSpeech : nil,
                               senses: senses,
                               phrases: [])
    }

    /// Wiktionary returns HTML fragments — links around the headword, italics for register.
    /// `NSAttributedString` with the HTML importer is not available off the main actor, so
    /// this strips tags and decodes the entities that actually turn up.
    static func plain(_ fragment: String) -> String {
        var text = fragment.replacingOccurrences(of: #"<[^>]+>"#, with: "",
                                                 options: .regularExpression)
        let entities = ["&nbsp;": " ", "&amp;": "&", "&quot;": "\"", "&#39;": "'",
                        "&lt;": "<", "&gt;": ">", "&rsquo;": "’", "&lsquo;": "‘",
                        "&ldquo;": "“", "&rdquo;": "”", "&mdash;": "—", "&ndash;": "–",
                        "&hellip;": "…", "&apos;": "'"]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
