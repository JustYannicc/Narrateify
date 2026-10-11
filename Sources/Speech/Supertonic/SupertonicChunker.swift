// Long-text chunking for Supertonic 3 (the model degrades past ~300 chars).
//
// Ported and adapted from the official Supertonic Swift example
// (https://github.com/supertone-inc/supertonic, swift/Sources/Helper.swift).
// Original code: MIT License, Copyright (c) 2025 Supertone Inc.

import Foundation

enum SupertonicChunker {
    private static let abbreviations = [
        "Dr.", "Mr.", "Mrs.", "Ms.", "Prof.", "Sr.", "Jr.", "St.", "Ave.", "Rd.", "Blvd.", "Dept.",
        "Inc.", "Ltd.", "Co.", "Corp.", "etc.", "vs.", "i.e.", "e.g.", "Ph.D.",
    ]
    private static let paragraphBreak = try! NSRegularExpression(pattern: "\\n\\s*\\n")
    private static let sentenceEnd = try! NSRegularExpression(pattern: "([.!?])\\s+")

    /// Splits into paragraphs, then sentences, then commas, then words, so
    /// every chunk is at most `maxLength` characters. Empty input → [].
    static func chunk(_ text: String, maxLength: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var chunks: [String] = []
        for para in split(trimmed, by: paragraphBreak).map(trim) where !para.isEmpty {
            if para.count <= maxLength {
                chunks.append(para)
                continue
            }
            var packer = Packer(maxLength: maxLength)
            for sentence in splitSentences(para).map(trim) where !sentence.isEmpty {
                if sentence.count <= maxLength {
                    packer.add(sentence, separator: " ")
                    continue
                }
                packer.flush()
                for part in sentence.components(separatedBy: ",").map(trim) where !part.isEmpty {
                    if part.count <= maxLength {
                        packer.add(part, separator: ", ")
                    } else {
                        packer.flush()
                        var words = Packer(maxLength: maxLength)
                        for word in part.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                            words.add(String(word), separator: " ")
                        }
                        words.flush()
                        packer.chunks += words.chunks
                    }
                }
                packer.flush()
            }
            packer.flush()
            chunks += packer.chunks
        }
        return chunks
    }

    /// Greedily joins pieces until adding one more would exceed `maxLength`.
    private struct Packer {
        let maxLength: Int
        var chunks: [String] = []
        var current = ""

        mutating func add(_ piece: String, separator: String) {
            if !current.isEmpty, current.count + separator.count + piece.count > maxLength { flush() }
            current += current.isEmpty ? piece : separator + piece
        }

        mutating func flush() {
            let c = SupertonicChunker.trim(current)
            if !c.isEmpty { chunks.append(c) }
            current = ""
        }
    }

    private static func trim(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func split(_ text: String, by regex: NSRegularExpression) -> [String] {
        let ns = text as NSString
        var parts: [String] = []
        var last = 0
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            parts.append(ns.substring(with: NSRange(location: last, length: m.range.location - last)))
            last = m.range.location + m.range.length
        }
        parts.append(ns.substring(from: last))
        return parts
    }

    /// Sentence split on [.!?] + whitespace, except after known abbreviations.
    private static func splitSentences(_ text: String) -> [String] {
        let ns = text as NSString
        var sentences: [String] = []
        var last = 0
        for m in sentenceEnd.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let candidate = ns.substring(with: NSRange(location: last, length: m.range.location + 1 - last))
            let head = candidate.trimmingCharacters(in: .whitespaces)
            if abbreviations.contains(where: { head.hasSuffix($0) }) { continue }
            let end = m.range.location + m.range.length
            sentences.append(ns.substring(with: NSRange(location: last, length: end - last)))
            last = end
        }
        if last < ns.length { sentences.append(ns.substring(from: last)) }
        return sentences.isEmpty ? [text] : sentences
    }
}
