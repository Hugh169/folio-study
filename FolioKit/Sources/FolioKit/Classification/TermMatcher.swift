import Foundation

/// Finds whole words and phrases, ignoring case and accents.
enum TermMatcher {
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacing("\u{2019}", with: "'")
            .replacing("\u{2018}", with: "'")
    }

    /// Whole-word occurrences of `term` in `text`, also counting simple plurals
    /// ("logarithm" matches "logarithms"). Both must already be normalised.
    ///
    /// `extraCharacters` lets a code match longer codes that start with it, such
    /// as "8461" in AQA's "84611H". Chinese, Japanese and Korean terms are found
    /// anywhere, since those languages don't separate words with spaces.
    static func count(of term: String, in text: String, extraCharacters: Int = 0) -> Int {
        ranges(of: term, in: text, extraCharacters: extraCharacters).count
    }

    /// Where `count(of:in:extraCharacters:)` finds the term, plural endings included.
    static func ranges(of term: String, in text: String, extraCharacters: Int = 0) -> [Range<String.Index>] {
        guard !term.isEmpty else { return [] }
        let startsInScript = term.first?.isUnspacedScript ?? false
        let endsInScript = term.last?.isUnspacedScript ?? false
        var found: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while let match = text.range(of: term, range: searchStart..<text.endIndex) {
            var end = match.upperBound
            if extraCharacters > 0 {
                var extra = 0
                while extra < extraCharacters, end < text.endIndex, text[end].isWordCharacter {
                    end = text.index(after: end)
                    extra += 1
                }
            } else if term.last?.isLetter == true && !endsInScript {
                for suffix in ["es", "s"] where text[end...].hasPrefix(suffix) {
                    let afterSuffix = text.index(end, offsetBy: suffix.count)
                    if afterSuffix == text.endIndex || !text[afterSuffix].isWordCharacter {
                        end = afterSuffix
                        break
                    }
                }
            }
            let before = match.lowerBound > text.startIndex ? text[text.index(before: match.lowerBound)] : nil
            let after = end < text.endIndex ? text[end] : nil
            if (startsInScript || !(before?.isWordCharacter ?? false)) && (endsInScript || !(after?.isWordCharacter ?? false)) {
                found.append(match.lowerBound..<end)
            }
            searchStart = match.upperBound
        }
        return found
    }

    static func contains(_ term: String, in text: String) -> Bool {
        count(of: term, in: text) > 0
    }

    /// Whether a name is an abbreviation in capitals, such as "IT", "PE" or
    /// "EAL/D". These are matched only in capitals, so "it" and "pe" don't count.
    static func isAbbreviation(_ term: String) -> Bool {
        let letters = term.filter(\.isLetter)
        return (2...5).contains(letters.count) && letters.allSatisfy(\.isUppercase) && !term.contains(where: \.isNumber)
    }

    /// Whole-word occurrences of an abbreviation in text that still has its
    /// capitals. With `ignoringCapitalisedRuns`, ones next to another word in
    /// capitals don't count, as in "DO NOT WRITE IT HERE" on an exam paper.
    static func count(ofAbbreviation term: String, in text: String, ignoringCapitalisedRuns: Bool) -> Int {
        guard !term.isEmpty else { return 0 }
        var count = 0
        var searchStart = text.startIndex
        while let found = text.range(of: term, range: searchStart..<text.endIndex) {
            searchStart = found.upperBound
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            guard !(before?.isWordCharacter ?? false), !(after?.isWordCharacter ?? false) else { continue }
            if ignoringCapitalisedRuns && isInCapitalisedRun(found, in: text) { continue }
            count += 1
        }
        return count
    }

    /// Whether the word just before or after a match is also in capitals.
    private static func isInCapitalisedRun(_ range: Range<String.Index>, in text: String) -> Bool {
        let lookBehind = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let lookAhead = text.index(range.upperBound, offsetBy: 30, limitedBy: text.endIndex) ?? text.endIndex
        let previous = text[lookBehind..<range.lowerBound].split(whereSeparator: { !$0.isLetter }).last
        let next = text[range.upperBound..<lookAhead].split(whereSeparator: { !$0.isLetter }).first
        return [previous, next].contains { word in
            guard let word, word.count >= 2 else { return false }
            return word.allSatisfy(\.isUppercase)
        }
    }
}

extension Character {
    var isWordCharacter: Bool { isLetter || isNumber }

    /// Chinese characters, Japanese kana and Korean Hangul.
    var isUnspacedScript: Bool {
        unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0x20000...0x2FA1F: true
            default: false
            }
        }
    }
}
