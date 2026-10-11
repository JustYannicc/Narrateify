import Foundation

/// Maps the service's word boundaries back onto the section text the reader
/// highlights. The service only tells us *what* word it spoke, not where, so we
/// search forward from the previous match. Words we can't place (rewritten by
/// the service, or too far ahead to trust) are dropped rather than guessed —
/// a missing highlight beats one on the wrong word.
enum EdgeWordAligner {
    /// How far past the cursor a match may start. Keeps one unplaceable short
    /// word ("a") from jumping to a far-away occurrence and dragging every
    /// following word with it.
    static let maxGap = 80

    static func align(_ boundaries: [EdgeProtocol.Boundary], in text: String) -> [WordTiming] {
        let original = text as NSString
        let normalized = normalize(text) as NSString
        var cursor = 0
        var out: [WordTiming] = []

        for b in boundaries {
            switch b.kind {
            case .word, .other: break
            case .punctuation, .sentence: continue
            }
            let word = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Punctuation-only "words" show up when punctuation boundaries are on.
            guard word.unicodeScalars.contains(where: isSpeakable) else { continue }

            let window = NSRange(location: cursor,
                                 length: min(original.length - cursor, maxGap + (word as NSString).length))
            guard window.length > 0 else { continue }

            var found = original.range(of: word, options: [.literal], range: window)
            if found.location == NSNotFound {
                found = normalized.range(of: normalize(word),
                                         options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                         range: window)
            }
            guard found.location != NSNotFound else { continue }

            out.append(WordTiming(range: found, start: b.start, duration: b.seconds))
            cursor = found.location + found.length
        }
        return out
    }

    /// Same-length (UTF-16) folding of typographic quotes/dashes so ranges in
    /// the normalized string are valid in the original.
    static func normalize(_ s: String) -> String {
        var units = Array(s.utf16)
        for i in units.indices {
            switch units[i] {
            case 0x2018, 0x2019, 0x201B, 0x02BC, 0x2032: units[i] = 0x27   // ' variants
            case 0x201C, 0x201D, 0x201E, 0x2033: units[i] = 0x22           // " variants
            case 0x2010, 0x2011, 0x2012, 0x2013, 0x2014: units[i] = 0x2D   // dashes
            case 0x00A0, 0x202F: units[i] = 0x20                           // nbsp
            default: break
            }
        }
        return String(decoding: units, as: UTF16.self)
    }

    private static func isSpeakable(_ u: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(u) || u.properties.isEmojiPresentation
    }
}
