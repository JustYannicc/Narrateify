// Text preprocessing + tokenization for Supertonic 3.
//
// Ported and adapted from the official Supertonic Swift example
// (https://github.com/supertone-inc/supertonic, swift/Sources/Helper.swift).
// Original code: MIT License, Copyright (c) 2025 Supertone Inc.
//
// Changes: throws instead of fatalError, deterministic replacement order,
// precompiled regexes, flat token buffers, unknown characters dropped instead
// of being fed to the model as -1.

import Foundation

enum SupertonicText {
    /// The 31 languages Supertonic 3 was trained on (ISO 639-1). Upstream also
    /// accepts "na" (unknown-language fallback); we don't route to it.
    static let languages: [String] = [
        "en", "ko", "ja", "ar", "bg", "cs", "da", "de", "el", "es", "et", "fi", "fr", "hi", "hr", "hu",
        "id", "it", "lt", "lv", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "tr", "uk", "vi",
    ]
    static let languageSet = Set(languages)

    /// Languages the model accepts as a tag, including the neutral "na".
    private static let acceptedTags = languageSet.union(["na"])

    /// Upstream uses shorter chunks for CJK scripts.
    static func maxChunkLength(for lang: String) -> Int {
        (lang == "ko" || lang == "ja") ? 120 : 300
    }

    // Applied in order (upstream iterates a dict, which is unordered in Swift).
    private static let replacements: [(String, String)] = [
        ("–", "-"), ("‑", "-"), ("—", "-"), ("\u{00AF}", " "), ("_", " "),
        ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"),
        ("´", "'"), ("`", "'"), ("[", " "), ("]", " "), ("|", " "), ("/", " "), ("#", " "),
        ("→", " "), ("←", " "),
        ("♥", ""), ("☆", ""), ("♡", ""), ("©", ""), ("\\", ""),
        ("@", " at "), ("e.g.,", "for example, "), ("i.e.,", "that is, "),
        (" ,", ","), (" .", "."), (" !", "!"), (" ?", "?"), (" ;", ";"), (" :", ":"), (" '", "'"),
    ]

    private static let whitespace = try! NSRegularExpression(pattern: "\\s+")
    private static let trailingPunctuation = try! NSRegularExpression(
        pattern: "[.!?;:,'\"\\u201C\\u201D\\u2018\\u2019)\\]}…。」』】〉》›»]$")

    private static func isEmoji(_ v: UInt32) -> Bool {
        (0x1F600...0x1F64F).contains(v) || (0x1F300...0x1F5FF).contains(v)
            || (0x1F680...0x1F6FF).contains(v) || (0x1F700...0x1F77F).contains(v)
            || (0x1F780...0x1F7FF).contains(v) || (0x1F800...0x1F8FF).contains(v)
            || (0x1F900...0x1F9FF).contains(v) || (0x1FA00...0x1FA6F).contains(v)
            || (0x1FA70...0x1FAFF).contains(v) || (0x2600...0x26FF).contains(v)
            || (0x2700...0x27BF).contains(v) || (0x1F1E6...0x1F1FF).contains(v)
    }

    /// Normalizes `text` and wraps it in `<lang>…</lang>`, matching upstream v3.
    static func preprocess(_ text: String, lang: String) throws -> String {
        guard acceptedTags.contains(lang) else {
            throw SpeechEngineError.unsupportedLanguage("Supertonic 3 doesn't speak '\(lang)'")
        }
        // NFKD so Hangul / accented letters decompose into indexable scalars.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.decomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { !isEmoji($0.value) })
        var s = String(scalars)

        for (old, new) in replacements {
            s = s.replacingOccurrences(of: old, with: new)
        }
        for dup in ["\"", "'", "`"] {
            while s.contains(dup + dup) { s = s.replacingOccurrences(of: dup + dup, with: dup) }
        }
        s = whitespace.stringByReplacingMatches(
            in: s, range: NSRange(s.startIndex..., in: s), withTemplate: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)

        if !s.isEmpty,
           trailingPunctuation.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) == nil {
            s += "."
        }
        return "<\(lang)>\(s)</\(lang)>"
    }
}

/// Maps preprocessed text to the model's character ids via `unicode_indexer.json`.
struct SupertonicTokenizer {
    private let indexer: [Int64]

    init(indexerURL: URL) throws {
        let data = try Data(contentsOf: indexerURL)
        indexer = try JSONDecoder().decode([Int64].self, from: data)
    }

    /// Token ids for one utterance. Characters the model has no id for are
    /// dropped (upstream passes -1, which is out of range for the embedding).
    func encode(_ text: String, lang: String) throws -> [Int64] {
        let processed = try SupertonicText.preprocess(text, lang: lang)
        var ids: [Int64] = []
        ids.reserveCapacity(processed.unicodeScalars.count)
        for scalar in processed.unicodeScalars {
            let v = Int(scalar.value)
            guard v < indexer.count, indexer[v] >= 0 else { continue }
            ids.append(indexer[v])
        }
        return ids
    }
}
