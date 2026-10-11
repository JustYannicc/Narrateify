import Foundation
import NaturalLanguage

/// Turns captured text into navigable sections, each tagged with one of the
/// user's reading languages.
///
/// Language detection is deliberately *closed-world*: the recognizer is
/// constrained to the languages the user reads, so a stray French phrase can
/// never route to a French voice — it's classified as whichever of the user's
/// languages it's closest to. Short or ambiguous sections inherit the language
/// of the text around them instead of flip-flopping.
enum ReadingPlanner {

    struct Options {
        /// Sentences shorter than this get merged with their neighbour.
        var minSectionLength = 40
        /// Sentences longer than this get split at clause/word boundaries.
        var maxSectionLength = 280
        /// The very first section is capped tighter so audio starts sooner.
        var maxFirstSectionLength = 120
        /// A first sentence at least this long is read on its own.
        var minFirstSplitLength = 20
        /// Below this length a section's own detection isn't trusted.
        var minDetectLength = 24
        /// Minimum probability for a section to override the document language.
        var overrideConfidence = 0.80
    }

    static func plan(_ text: String,
                     languages: [ReadingLanguage],
                     options: Options = Options()) -> [ReadingSection] {
        guard let primary = languages.first else { return [] }
        let pieces = sectionTexts(text, options: options)
        guard !pieces.isEmpty else { return [] }

        // One language → nothing to detect.
        guard languages.count > 1 else {
            return pieces.enumerated().map { ReadingSection(id: $0, text: $1, language: primary) }
        }

        let detector = ReadingLanguageDetector(languages: languages)
        let documentLanguage = detector.best(in: text)?.language ?? primary

        var sections: [ReadingSection] = []
        var context = documentLanguage
        for (i, piece) in pieces.enumerated() {
            var language = context
            if piece.count >= options.minDetectLength,
               let guess = detector.best(in: piece) {
                if guess.language == context || guess.confidence >= options.overrideConfidence {
                    language = guess.language
                }
            }
            sections.append(ReadingSection(id: i, text: piece, language: language))
            // Only confident, reasonably long sections move the context, so a
            // short quoted phrase doesn't drag the rest of the text with it.
            if piece.count >= options.minDetectLength * 2 { context = language }
        }
        return smoothIsolatedShortSwitches(sections, options: options)
    }

    // MARK: Sectioning

    /// Paragraphs → sentences → merged/split to sensible sizes.
    static func sectionTexts(_ text: String, options: Options = Options()) -> [String] {
        let paragraphs = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        var result: [String] = []
        for paragraph in paragraphs {
            let paragraphStart = result.count
            var pending = ""
            for sentence in sentences(in: paragraph) {
                let candidate = pending.isEmpty ? sentence : pending + " " + sentence
                if candidate.count < options.minSectionLength {
                    pending = candidate
                    continue
                }
                if !pending.isEmpty, candidate.count > options.maxSectionLength {
                    result.append(pending)
                    pending = sentence
                } else {
                    pending = candidate
                }
                if pending.count >= options.minSectionLength {
                    result.append(contentsOf: split(pending, maxLength: options.maxSectionLength))
                    pending = ""
                }
            }
            if !pending.isEmpty {
                // A short tail joins the previous section of the same paragraph
                // if it fits; otherwise it stands alone.
                if result.count > paragraphStart, let last = result.last,
                   last.count + pending.count + 1 <= options.maxSectionLength {
                    result[result.count - 1] = last + " " + pending
                } else {
                    result.append(pending)
                }
            }
        }

        // Shorter first section → faster time-to-first-audio: synthesis time
        // scales with length, so a merged pair of sentences gets its first
        // sentence split off when that sentence is long enough to stand alone.
        if let first = result.first, first.count > options.minFirstSplitLength * 2 {
            let parts = sentences(in: first)
            if parts.count > 1, parts[0].count >= options.minFirstSplitLength {
                result.replaceSubrange(0...0, with: [parts[0], parts.dropFirst().joined(separator: " ")])
            }
        }
        if let first = result.first, first.count > options.maxFirstSectionLength {
            let head = split(first, maxLength: options.maxFirstSectionLength)
            result.replaceSubrange(0...0, with: head)
        }
        return result
    }

    private static func sentences(in paragraph: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = paragraph
        var out: [String] = []
        tokenizer.enumerateTokens(in: paragraph.startIndex..<paragraph.endIndex) { range, _ in
            let s = paragraph[range].trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            return true
        }
        return out.isEmpty ? [paragraph] : out
    }

    /// Split an over-long piece at the last clause boundary (then space) that
    /// keeps each part under `maxLength`.
    static func split(_ text: String, maxLength: Int) -> [String] {
        var parts: [String] = []
        var rest = Substring(text)
        while rest.count > maxLength {
            let window = rest.prefix(maxLength)
            let cut = lastBoundary(in: window, from: [";", ":", ",", " –", " —", ")"])
                ?? window.lastIndex(of: " ").map { rest.index(after: $0) }
                ?? window.endIndex
            let head = rest[..<cut].trimmingCharacters(in: .whitespaces)
            if !head.isEmpty { parts.append(head) }
            rest = rest[cut...].drop { $0 == " " }
        }
        let tail = rest.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts
    }

    private static func lastBoundary(in window: Substring, from marks: [String]) -> Substring.Index? {
        // Don't cut in the first third — tiny fragments read badly.
        let minOffset = window.count / 3
        var best: Substring.Index?
        for mark in marks {
            guard let r = window.range(of: mark, options: .backwards) else { continue }
            if window.distance(from: window.startIndex, to: r.lowerBound) < minOffset { continue }
            if best == nil || r.upperBound > best! { best = r.upperBound }
        }
        return best
    }

    // MARK: Smoothing

    /// A short section whose neighbours on both sides agree on another language
    /// is almost always a misdetection (a name, a number, a heading).
    private static func smoothIsolatedShortSwitches(_ sections: [ReadingSection],
                                                    options: Options) -> [ReadingSection] {
        guard sections.count >= 3 else { return sections }
        var out = sections
        for i in 1..<(sections.count - 1) {
            let prev = sections[i - 1].language, next = sections[i + 1].language
            let s = sections[i]
            if prev == next, s.language != prev, s.text.count < options.minDetectLength * 2 {
                out[i] = ReadingSection(id: s.id, text: s.text, language: prev)
            }
        }
        return out
    }
}

/// `NLLanguageRecognizer` restricted to the user's languages.
struct ReadingLanguageDetector {
    let languages: [ReadingLanguage]

    struct Guess { let language: ReadingLanguage; let confidence: Double }

    func best(in text: String) -> Guess? {
        let sample = String(text.prefix(1000))
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map { NLLanguage(rawValue: $0.base) }
        recognizer.processString(sample)
        let hypotheses = recognizer.languageHypotheses(withMaximum: languages.count)
        guard let (lang, p) = hypotheses.max(by: { $0.value < $1.value }),
              let match = languages.first(where: { $0.base == lang.rawValue }) else { return nil }
        return Guess(language: match, confidence: p)
    }
}
