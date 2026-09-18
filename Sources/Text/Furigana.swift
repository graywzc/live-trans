import Foundation

/// A run of text with the reading to print above it, if it needs one.
struct RubyToken: Equatable {
    var base: String
    var reading: String?
    /// Punctuation: must not be wrapped onto the start of a new line.
    var gluesToPrevious = false
}

/// Kanji readings from the system's Japanese tokenizer. It works offline and
/// needs no dictionary shipped with the app: right for ordinary vocabulary,
/// occasionally wrong on names and on kanji whose reading depends on the
/// neighbouring word.
enum Furigana {
    static func annotate(_ text: String) -> [RubyToken] {
        let string = text as NSString
        guard
            let tokenizer = CFStringTokenizerCreate(
                nil, text as CFString, CFRangeMake(0, string.length),
                kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale
            )
        else {
            return [RubyToken(base: text)]
        }

        var tokens: [RubyToken] = []
        var cursor = 0
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location != kCFNotFound, range.length > 0 else { continue }
            // The tokenizer steps over punctuation and spaces without
            // reporting them; they are still part of the caption.
            if range.location > cursor {
                let gap = string.substring(with: NSRange(location: cursor, length: range.location - cursor))
                tokens.append(RubyToken(base: gap, gluesToPrevious: true))
            }
            let surface = string.substring(with: NSRange(location: range.location, length: range.length))
            tokens.append(contentsOf: annotate(word: surface, reading: reading(of: tokenizer)))
            cursor = range.location + range.length
        }
        if cursor < string.length {
            tokens.append(RubyToken(base: string.substring(from: cursor), gluesToPrevious: true))
        }
        return tokens
    }

    /// The only reading the tokenizer exposes is a romanization, so go
    /// kanji -> romaji -> hiragana.
    private static func reading(of tokenizer: CFStringTokenizer) -> String? {
        guard
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String
        else { return nil }
        let reading = NSMutableString(string: latin)
        guard CFStringTransform(reading, nil, kCFStringTransformLatinHiragana, false) else {
            return nil
        }
        return reading as String
    }

    /// Put the reading over the kanji only: 食べる(たべる) becomes 食(た) + べる.
    private static func annotate(word: String, reading: String?) -> [RubyToken] {
        guard let reading, word.unicodeScalars.contains(where: isKanji) else {
            return [RubyToken(base: word)]
        }
        var base = Array(word)
        var kana = Array(reading)

        var suffix: [Character] = []
        while let last = base.last, let lastKana = kana.last, kana.count > 1,
              !last.unicodeScalars.contains(where: isKanji), hiragana(last) == lastKana {
            suffix.insert(base.removeLast(), at: 0)
            kana.removeLast()
        }
        var prefix: [Character] = []
        while let first = base.first, let firstKana = kana.first, kana.count > 1,
              !first.unicodeScalars.contains(where: isKanji), hiragana(first) == firstKana {
            prefix.append(base.removeFirst())
            kana.removeFirst()
        }

        var tokens: [RubyToken] = []
        if !prefix.isEmpty { tokens.append(RubyToken(base: String(prefix))) }
        tokens.append(RubyToken(base: String(base), reading: String(kana)))
        if !suffix.isEmpty { tokens.append(RubyToken(base: String(suffix))) }
        return tokens
    }

    private static func isKanji(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF, 0x3005, 0x3007: true
        default: false
        }
    }

    /// Katakana -> hiragana, so okurigana written either way matches the reading.
    private static func hiragana(_ character: Character) -> Character {
        guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
              (0x30A1...0x30F6).contains(scalar.value),
              let shifted = Unicode.Scalar(scalar.value - 0x60)
        else { return character }
        return Character(shifted)
    }
}
