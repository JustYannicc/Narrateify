import Foundation
import KokoroTTS
import NaturalLanguage

/// English text → Kokoro phonemes, following misaki (Kokoro's own G2P): the
/// misaki gold/silver dictionaries first, then its suffix rules, letter-by-
/// letter acronyms and spelled-out numbers; only unknown words go to
/// speech-swift's phonemizer (dictionary stemming + a small BART G2P).
/// speech-swift's English path alone mangles contractions ("here's" →
/// "here-ess") and acronyms ("API" → "A"), which voiceovers are full of.
final class KokoroEnglish {
    private enum Entry { case simple(String), heteronym([String: String]) }

    private let gold: [String: Entry]
    private let silver: [String: Entry]
    /// Built-in fixes plus the user's lexicon (word → misaki phonemes), checked first.
    private let overrides: [String: String]
    private let fallback: KokoroPhonemizer
    private let vocab: [String: Int]
    private let idToPhoneme: [Int: String]
    private let tagger = NLTagger(tagSchemes: [.lexicalClass])
    private let spell: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US")
        f.numberStyle = .spellOut
        return f
    }()

    /// Names the fallback G2P gets wrong (it loops on repeated syllables).
    static let builtInLexicon: [String: String] = [
        "kokoro": "kəkˈɔɹO", "qwen": "ʧwˈɛn", "narrateify": "nəɹˈAtᵻfˌI", "yannic": "jˈænɪk",
        "supertone": "sˈupəɹtˌOn", "remotion": "ɹᵻmˈOʃən", "nginx": "ˌɛnʤənˈɛks",
        "json": "ʤˈAsᵊn", "supabase": "sˈupəbˌAs", "wallee": "wˈɑli", "kubectl": "kjˈubkˌʌtᵊl",
    ]

    init(directory: URL, fallback: KokoroPhonemizer, lexicon: URL? = nil) throws {
        var overrides = Self.builtInLexicon
        if let lexicon, let data = try? Data(contentsOf: lexicon),
           let user = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            for (word, phonemes) in user { overrides[word.lowercased()] = phonemes }
        }
        self.overrides = overrides
        gold = try Self.load(directory.appendingPathComponent("us_gold.json"))
        silver = try Self.load(directory.appendingPathComponent("us_silver.json"))
        self.fallback = fallback
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("vocab_index.json"))) as? [String: Any]
        vocab = (json?["vocab"] as? [String: Int]) ?? [:]
        idToPhoneme = Dictionary(uniqueKeysWithValues: vocab.map { ($1, $0) })
    }

    private static func load(_ url: URL) throws -> [String: Entry] {
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        var out: [String: Entry] = [:]
        out.reserveCapacity(raw.count)
        for (word, value) in raw {
            if let s = value as? String { out[word] = .simple(s) }
            // Some heteronyms carry nulls ("IS": {"DEFAULT": "ɪz", "NOUN": null}); keep the strings.
            else if let d = value as? [String: Any] { out[word] = .heteronym(d.compactMapValues { $0 as? String }) }
        }
        return out
    }

    /// Kokoro token ids (no padding).
    func tokens(_ text: String) -> [Int] {
        tokens(phonemes: phonemes(text))
    }

    func tokens(phonemes: String) -> [Int] {
        phonemes.compactMap { vocab[String($0)] }
    }

    /// "1,000.5" first (so its commas don't split it), then words with inner
    /// apostrophes/hyphens/dots in any script, then single punctuation marks.
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"\d{1,3}(?:,\d{3})+(?:\.\d+)?|[\p{L}\p{N}]+(?:['’.\-][\p{L}\p{N}]+)*|[^\s\p{L}\p{N}]"#)

    func phonemes(_ text: String) -> String {
        let text = Self.normalize(text)
        let verbs = verbRanges(text)
        // Mostly capitals = shouting: read all-caps words as words, not letters.
        let letters = text.filter(\.isLetter)
        let shouting = letters.count >= 8 && Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.7
        var words: [(String, Bool)] = []   // phonemes, isPunctuation
        let ns = text as NSString
        for match in Self.tokenPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let token = ns.substring(with: match.range)
            if let first = token.unicodeScalars.first, !CharacterSet.alphanumerics.contains(first) {
                if let p = Self.punctuation[token], !p.isEmpty { words.append((p, true)) }
                continue
            }
            let clean = token.replacingOccurrences(of: "’", with: "'")
            // "A" is the article only at a sentence start; elsewhere it's the letter ("Plan A").
            let sentenceStart = words.last.map { $0.1 && ".!?".contains($0.0) } ?? true
            let isArticle = Self.functionWords[clean.lowercased()] != nil && (clean != "A" || sentenceStart)
            let ph = isArticle ? clean.lowercased() : word(clean, verb: verbs.contains(match.range.location), shouting: shouting)
            if !ph.isEmpty { words.append((ph, false)) }
        }
        // misaki: "the" is ði before a vowel sound, ðə otherwise; same idea for "to"/"a".
        for i in words.indices where !words[i].1 {
            guard let forms = Self.functionWords[words[i].0] else { continue }
            let next = words[(i + 1)...].first { !$0.1 }?.0
            let vowel = next.map { Self.startsWithVowel($0) } ?? false
            words[i].0 = vowel ? forms.beforeVowel : forms.beforeConsonant
        }
        var out = ""
        for (ph, isPunctuation) in words {
            if !out.isEmpty, !isPunctuation || ph == "—" { out += " " }
            out += ph
        }
        return out
    }

    private static let functionWords: [String: (beforeConsonant: String, beforeVowel: String)] = [
        "the": ("ðə", "ði"), "to": ("tə", "tʊ"), "a": ("ɐ", "ɐ"),
    ]

    private static func startsWithVowel(_ phonemes: String) -> Bool {
        guard let first = phonemes.first(where: { $0 != "ˈ" && $0 != "ˌ" }) else { return false }
        return "aeiouæɑɐɒɔəɛɜɪʊʌAIOWYᵊɚ".contains(first)
    }

    // MARK: Words

    private func word(_ w: String, verb: Bool, shouting: Bool = false) -> String {
        if let p = overrides[w.lowercased()] { return p }
        // All caps: only an exact-case entry counts ("US" yes, "APIs" ≠ "apis"),
        // unless the whole text is shouting ("THIS IS IMPORTANT").
        let plural = w.hasSuffix("s") && isAcronym(String(w.dropLast()))
        if isAcronym(w) || plural {
            if let entry = gold[w] ?? silver[w], let p = resolve(entry, verb: verb) { return p }
            if let n = number(w) { return n }
            if shouting, let p = lookup(w.lowercased(), verb: verb) ?? suffixed(w.lowercased(), verb: verb) { return p }
            return plural ? acronym(String(w.dropLast())) + "z" : acronym(w)
        }
        if let p = lookup(w, verb: verb) { return p }
        if w.contains("-") {
            return w.split(separator: "-").map { word(String($0), verb: verb) }.joined(separator: " ")
        }
        if let n = number(w) { return n }
        if let p = suffixed(w, verb: verb) { return p }
        if let p = compound(w) { return p }
        return unknown(w)
    }

    /// Exact, lowercase, then Capitalized, like misaki.
    private func lookup(_ w: String, verb: Bool) -> String? {
        if let p = overrides[w.lowercased()] { return p }
        let plain = Self.fold(w)   // "café" → "cafe": the dictionaries are ASCII
        for key in [w, w.lowercased(), w.prefix(1).uppercased() + w.dropFirst().lowercased(), plain, plain.lowercased()] {
            if let entry = gold[key] ?? silver[key] { return resolve(entry, verb: verb) }
        }
        return nil
    }

    private func resolve(_ entry: Entry, verb: Bool) -> String? {
        switch entry {
        case .simple(let p): return p
        case .heteronym(let options):
            if verb, let v = options["VERB"] ?? options["VBP"] { return v }
            return options["DEFAULT"] ?? options.values.first
        }
    }

    /// misaki's -s/-'s, -ed and -ing rules on a known stem.
    private func suffixed(_ w: String, verb: Bool) -> String? {
        let lower = w.lowercased()
        for (suffix, cut) in [("'s", 2), ("s", 1), ("es", 2)] where lower.hasSuffix(suffix) && lower.count > cut + 1 {
            if let stem = lookup(String(w.dropLast(cut)), verb: false) { return stem + sSuffix(after: stem) }
        }
        for (suffix, cut) in [("ed", 2), ("d", 1)] where lower.hasSuffix(suffix) && lower.count > cut + 2 {
            if let stem = lookup(String(w.dropLast(cut)), verb: true) { return stem + edSuffix(after: stem) }
        }
        if lower.hasSuffix("ing"), lower.count > 5 {
            let stem = String(w.dropLast(3))
            if let p = lookup(stem, verb: true) ?? lookup(stem + "e", verb: true) { return p + "ɪŋ" }
        }
        return nil
    }

    private func sSuffix(after stem: String) -> String {
        guard let last = stem.last else { return "z" }
        if "szʃʒʧʤ".contains(last) { return "ᵻz" }
        if "ptkfθ".contains(last) { return "s" }
        return "z"
    }

    private func edSuffix(after stem: String) -> String {
        guard let last = stem.last else { return "d" }
        if "td".contains(last) { return "ᵻd" }
        if "pkfθʃsʧ".contains(last) { return "t" }
        return "d"
    }

    private func isAcronym(_ w: String) -> Bool {
        w.count >= 2 && w.count <= 6 && w.allSatisfy { $0.isUppercase || $0.isNumber } && w.contains { $0.isLetter }
    }

    /// "API" → ˌAˌpˌiˈI: each letter's name, main stress on the last.
    private func acronym(_ w: String) -> String {
        let parts = w.map { c -> String in
            if c.isNumber { return number(String(c)) ?? "" }
            return lookup(String(c), verb: false) ?? ""
        }.filter { !$0.isEmpty }
        return parts.enumerated().map { i, p in
            i == parts.count - 1 ? p : p.replacingOccurrences(of: "ˈ", with: "ˌ")
        }.joined()
    }

    private func number(_ w: String) -> String? {
        let digits = w.replacingOccurrences(of: ",", with: "")
        if let year = Int(digits), digits.count == 4, digits == w, (1100...2099).contains(year), !(2000...2009).contains(year) {
            // 1984 → nineteen eighty-four, 1905 → nineteen oh five, 1900 → nineteen hundred,
            // 2026 → twenty twenty-six (2000–2009 stay "two thousand five")
            let century = spell.string(from: NSNumber(value: year / 100)) ?? ""
            let rest = year % 100
            let tail = rest == 0 ? "hundred" : rest < 10 ? "oh " + (spell.string(from: NSNumber(value: rest)) ?? "")
                : spell.string(from: NSNumber(value: rest)) ?? ""
            return phonemes(century + " " + tail)
        }
        guard let value = Double(digits), digits.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        guard let words = spell.string(from: NSNumber(value: value)) else { return nil }
        return phonemes(words)
    }

    /// Made-up names are often a word plus a productive suffix ("Narrateify"
    /// = narrate + ify) or two longer known words ("Supertonic"); the longest
    /// known head wins. Both halves of a two-word split are 4+ letters, so
    /// "Supabase" doesn't become "sup" + "abase".
    private func compound(_ w: String) -> String? {
        let chars = Array(w)
        guard chars.count >= 6 else { return nil }
        for cut in stride(from: chars.count - 2, through: 4, by: -1) {
            let head = String(chars[..<cut]), tail = String(chars[cut...]).lowercased()
            if let suffix = Self.suffixes[tail], let first = lookup(head, verb: false) ?? lookup(head + "e", verb: false) {
                return first + suffix
            }
            if tail.count >= 4, let first = lookup(head, verb: false), let second = lookup(tail, verb: false) {
                return first + Self.demote(second)
            }
        }
        return nil
    }

    private static let suffixes: [String: String] = [
        "ify": "əfˌI", "eify": "əfˌI", "ly": "li", "ness": "nəs", "able": "əbᵊl", "er": "əɹ", "ers": "əɹz",
        "ing": "ɪŋ", "ize": "ˌIz", "ized": "ˌIzd", "ism": "ˌɪzəm", "ist": "ɪst", "ful": "fəl", "less": "ləs",
    ]

    /// Primary stress → secondary, so a compound keeps one main stress.
    private static func demote(_ p: String) -> String { p.replacingOccurrences(of: "ˈ", with: "ˌ") }

    /// speech-swift's phonemizer, one word at a time.
    private static func fold(_ w: String) -> String {
        w.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US"))
    }

    /// speech-swift's phonemizer, one word at a time. Its G2P model sometimes
    /// collapses a word ("jose" → "ʤ"); then the halves are tried separately.
    private func unknown(_ w: String) -> String {
        let plain = Self.fold(w)
        let whole = g2p(plain)
        let sounds = whole.filter { $0 != "ˈ" && $0 != "ˌ" }.count
        guard sounds * 2 < plain.count, plain.count >= 4 else { return whole }
        let chars = Array(plain)
        let mid = chars.count / 2
        // Cut before a consonant that follows a vowel near the middle: "jo|se".
        let vowels = Set("aeiouyAEIOUY")
        let cut = (1..<chars.count - 1).filter { !vowels.contains(chars[$0]) && vowels.contains(chars[$0 - 1]) }
            .min { abs($0 - mid) < abs($1 - mid) } ?? mid
        let halves = [String(chars[..<cut]), String(chars[cut...])].map { lookup($0, verb: false) ?? g2p($0) }
        return halves[0] + Self.demote(halves[1])
    }

    private func g2p(_ w: String) -> String {
        let ids = fallback.tokenize(w, maxLength: 510, language: "en").dropFirst().dropLast()   // its bos/eos
        return ids.compactMap { idToPhoneme[$0] }.joined().trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;: "))
    }

    /// Word starts the tagger calls verbs, for heteronyms ("read", "live").
    private func verbRanges(_ text: String) -> Set<Int> {
        tagger.string = text
        var out = Set<Int>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .verb { out.insert(NSRange(range, in: text).location) }
            return true
        }
        return out
    }

    // MARK: Text

    private static let punctuation: [String: String] = [
        ".": ".", ",": ",", "!": "!", "?": "?", ";": ";", ":": ":", "—": "—", "–": "—", "…": "…",
        "(": ",", ")": ",", "\"": "", "“": "", "”": "",
    ]

    private static func normalize(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "&", with: " and ")
        t = t.replacingOccurrences(of: "%", with: " percent")
        t = t.replacingOccurrences(of: " - ", with: " — ")
        // "$5" → "5 dollars", "-5" → "minus 5", "5-10" → "5 to 10"
        t = t.replacingOccurrences(of: #"\$(\d[\d,]*(?:\.\d+)?)"#, with: "$1 dollars", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<![\p{L}\p{N}])-(?=\d)"#, with: "minus ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"(?<=\d)-(?=\d)"#, with: " to ", options: .regularExpression)
        // "Qwen3" → "Qwen 3" (but "MP3", "GPT4" stay acronyms).
        t = t.replacingOccurrences(of: #"(?<=[a-z])(?=[0-9])"#, with: " ", options: .regularExpression)
        return t
    }
}
