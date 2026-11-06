import Foundation

/// A rough "sounds like" key for English spellings, so words a learner spells by ear still find the
/// real word: fonetic and phonetic → FNTK, kat and cat → KT, nolij and knowledge → NLJ.
///
/// Loosely follows Metaphone: vowels after the first letter are dropped, letters that sound alike
/// share a code, silent letters are skipped, and repeated codes collapse to one.
/// Tools/build_dictionaries.py has the same function (`sound_key`); keep the two identical.
enum SoundKey {
    static func make(_ word: String) -> String {
        var s = Array(word.lowercased().unicodeScalars.filter { $0.value >= 97 && $0.value <= 122 }.map { Character($0) })
        guard !s.isEmpty else { return "" }
        for silent in ["kn", "gn", "pn", "wr", "ps"] where s.starts(with: Array(silent)) {
            s.removeFirst()
            break
        }
        if s.first == "x" { s[0] = "s" }
        if s.starts(with: ["w", "h"]) { s.remove(at: 1) }

        func isVowel(_ c: Character?) -> Bool { c.map { "aeiouy".contains($0) } ?? false }
        func at(_ i: Int) -> Character? { i >= 0 && i < s.count ? s[i] : nil }
        func followedBy(_ i: Int, _ text: String) -> Bool {
            let t = Array(text)
            guard i + t.count <= s.count else { return false }
            return Array(s[i..<(i + t.count)]) == t
        }

        var out: [Character] = []
        var i = 0
        while i < s.count {
            let c = s[i], next = at(i + 1), prev = at(i - 1)
            switch c {
            case "a", "e", "i", "o", "u", "y":
                if i == 0 { out.append(c == "y" && isVowel(next) ? "Y" : "A") }
            case "b":
                if !(prev == "m" && i == s.count - 1) { out.append("B") }
            case "c":
                if next == "h" { out.append("X"); i += 1 }
                else if next.map({ "eiy".contains($0) }) ?? false { out.append("S") }
                else if next == "k" { out.append("K"); i += 1 }
                else { out.append("K") }
            case "d":
                if next == "g", at(i + 2).map({ "eiy".contains($0) }) ?? false { out.append("J"); i += 1 }
                else { out.append("T") }
            case "g":
                if next == "h" {
                    if i == 0 { out.append("K") }
                    i += 1   // "gh" is silent inside a word (night, though)
                } else if next == "n", i + 2 == s.count || (followedBy(i + 2, "ed") && i + 4 == s.count) {
                    // silent: sign, signed
                } else if next.map({ "eiy".contains($0) }) ?? false {
                    out.append("J")
                } else {
                    out.append("K")
                }
            case "h":
                if isVowel(next) && (i == 0 || isVowel(prev)) { out.append("H") }
            case "k":
                out.append("K")
            case "p":
                if next == "h" { out.append("F"); i += 1 } else { out.append("P") }
            case "q":
                out.append("K")
            case "s":
                if next == "h" { out.append("X"); i += 1 }
                else if followedBy(i + 1, "ch") { out.append("S"); out.append("K"); i += 2 }
                else if followedBy(i + 1, "io") || followedBy(i + 1, "ia") { out.append("X") }
                else { out.append("S") }
            case "t":
                if next == "h" { out.append("0"); i += 1 }
                else if followedBy(i + 1, "io") || followedBy(i + 1, "ia") { out.append("X") }
                else if followedBy(i + 1, "ch") { /* silent: watch */ }
                else { out.append("T") }
            case "v":
                out.append("F")
            case "w":
                if isVowel(next) { out.append("W") }
            case "x":
                out.append("K"); out.append("S")
            case "z":
                out.append("S")
            default:
                out.append(Character(c.uppercased()))
            }
            i += 1
        }

        var collapsed: [Character] = []
        for code in out where code != collapsed.last { collapsed.append(code) }
        return String(collapsed)
    }

    /// Whether `word` is a single English word that gets a sound key (letters, apostrophes, hyphens).
    static func isSingleWord(_ word: String) -> Bool {
        guard let first = word.unicodeScalars.first, first.isASCIILetter else { return false }
        return word.unicodeScalars.allSatisfy { $0.isASCIILetter || $0 == "'" || $0 == "-" }
    }
}

private extension Unicode.Scalar {
    var isASCIILetter: Bool { (value >= 65 && value <= 90) || (value >= 97 && value <= 122) }
}
