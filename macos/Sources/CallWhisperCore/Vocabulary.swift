import Foundation

/// Słownictwo dla whispera wyciągane z kontekstu projektu.
///
/// Ręczne słownictwo z Ustawień pokrywa stałe nazwy (React, Next.js), ale
/// nie to, co jest specyficzne dla danej rozmowy. Zmierzone 2026-10-06 na
/// `small`: z terminami z pliku kontekstu whisper pisał „Playwright" zamiast
/// „PlayVrit", „software house" zamiast „Softwarehouse" i „outsourcingowym"
/// zamiast „o utsourcingowym". Plik kontekstu już te nazwy ma, więc nie ma
/// powodu przepisywać ich ręcznie.
public enum Vocabulary {
    /// Ile znaków słownictwa idzie do promptu whispera. Prompt ma ~224 tokeny
    /// i whisper.cpp przy nadmiarze ucina go od początku, czyli od słownictwa.
    public static let maxChars = 350

    /// Nazwy własne i technologie z tekstu, od najczęstszych.
    ///
    /// Bierzemy słowa, które wyglądają na nazwę: z wielką literą w środku
    /// zdania (Python, Playwright), z wielką literą w środku słowa
    /// (TypeScript), z kropką lub cyfrą (Next.js, B2B) albo skróty (DPP).
    /// Kod w backtickach pomijamy: identyfikatory ze ściągi (`defineModel`)
    /// w mowie nie padają, a zjadałyby limit.
    public static func terms(from context: String) -> [String] {
        let chars = Array(stripCode(context))
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var order = 0
        func add(_ term: String) {
            counts[term, default: 0] += 1
            if firstSeen[term] == nil { firstSeen[term] = order; order += 1 }
        }

        // Sąsiednie nazwy rozdzielone jedną spacją to jedna nazwa:
        // „React Native", „Claude Code". Osobno „Native" nic whisperowi nie mówi.
        var phrase: [String] = []
        var phraseEnd = -1
        func flush() {
            if !phrase.isEmpty { add(phrase.joined(separator: " ")) }
            phrase = []
        }

        var i = 0
        while i < chars.count {
            guard chars[i].isLetter else { i += 1; continue }
            var j = i
            while j < chars.count, chars[j].isLetter || chars[j].isNumber || "+#".contains(chars[j])
                    || (".-".contains(chars[j]) && j + 1 < chars.count && chars[j + 1].isLetter) {
                j += 1
            }
            let word = String(chars[i..<j])
            // Zdanie zaczynające się od nazwy („Python jest…") też ją liczy,
            // jeśli zaraz po niej idzie kolejna („Google Cloud").
            let continues = !phrase.isEmpty && phraseEnd == i - 1 && chars[i - 1] == " " && phrase.count < 3
            if isTerm(word, sentenceStart: atSentenceStart(chars, i) && !continues) {
                if !continues { flush() }
                phrase.append(word)
                phraseEnd = j
            } else {
                flush()
            }
            i = j
        }
        flush()

        let ranked = counts.keys.sorted {
            let (ta, tb) = (tier($0), tier($1))
            if ta != tb { return ta < tb }
            return counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : firstSeen[$0]! < firstSeen[$1]!
        }
        // Odmiany tej samej nazwy („Figma", „Figmy") zostają raz, w częstszej formie.
        var out: [String] = []
        for term in ranked where !out.contains(where: { isInflection(term, of: $0) }) {
            out.append(term)
        }
        return out
    }

    /// Słownictwo z Ustawień, a po nim terminy z kontekstu, których jeszcze
    /// nie ma, do limitu znaków.
    public static func merge(_ user: String, context: String, maxChars: Int = maxChars) -> String {
        var out = Text.normalize(user)
        if out.hasSuffix(".") { out.removeLast() }
        var known: [String] = []
        for entry in out.split(whereSeparator: { ",;".contains($0) }) {
            let phrase = entry.trimmingCharacters(in: .whitespaces)
            known.append(phrase)
            known.append(contentsOf: phrase.split(separator: " ").map(String.init))
        }
        for term in terms(from: context) {
            guard !known.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame || isInflection(term, of: $0) }) else { continue }
            let next = out.isEmpty ? term : "\(out), \(term)"
            guard next.count <= maxChars else { continue }
            out = next
            known.append(term)
        }
        return out
    }

    /// Kolejność przy ograniczonym miejscu: najpierw to, co wygląda na
    /// technologię (TypeScript, Next.js, B2B), potem zwykłe nazwy (Python,
    /// Playwright), na końcu słowa odmienione po polsku albo z polskimi
    /// znakami („Brazylii", „Wrocław"). Whisper zna polskie słowa, a nazw
    /// technologii bez podpowiedzi nie.
    static func tier(_ term: String) -> Int {
        let word = term.split(separator: " ").last.map(String.init) ?? term
        // Identyfikatory z kodu („useState") w mowie padają rzadko.
        if word.first?.isLowercase == true, word.contains(where: \.isUppercase) { return 2 }
        // Same wielkie litery („SEO", „AWS") whisper zwykle zna: jak zwykłe nazwy.
        let acronym = word.allSatisfy { $0.isUppercase || $0.isNumber } && !word.contains(where: \.isNumber)
        if !acronym, word.dropFirst().contains(where: \.isUppercase) || word.contains(".") || word.contains(where: \.isNumber) {
            return 0
        }
        let lower = word.lowercased()
        if lower.contains(where: { "ąćęłńóśźż".contains($0) }) { return 2 }
        if ["ii", "ji", "ie", "ce", "owi", "ach", "ami", "ego", "emu", "ych", "ów"].contains(where: { lower.hasSuffix($0) }) {
            return 2
        }
        return 1
    }

    /// „Figmy" to odmiana „Figma", „Reacta" odmiana „React": ten sam rdzeń,
    /// inna końcówka, najwyżej trzy znaki różnicy.
    static func isInflection(_ a: String, of b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        guard x != y, !x.contains(" "), !y.contains(" "), x.count >= 4, y.count >= 4,
              abs(x.count - y.count) <= 3 else { return false }
        let stem = min(x.count, y.count) - 1
        return stem >= 4 && x.prefix(stem) == y.prefix(stem)
    }

    private static func stripCode(_ text: String) -> String {
        var out = ""
        var inCode = false
        for ch in text {
            if ch == "`" { inCode.toggle(); out.append(" "); continue }
            out.append(inCode ? " " : ch)
        }
        return out
    }

    private static func atSentenceStart(_ chars: [Character], _ index: Int) -> Bool {
        var k = index - 1
        while k >= 0, chars[k] == " " || chars[k] == "*" { k -= 1 }
        return k < 0 || ".!?:\n#(-\"„".contains(chars[k])
    }

    private static func isTerm(_ word: String, sentenceStart: Bool) -> Bool {
        // „UI", „CV", „B2": krótkie skróty whisper zna i bez podpowiedzi.
        guard word.count >= 3, word.count <= 30 else { return false }
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        let inner = word.dropFirst()
        if inner.contains(where: \.isUppercase) { return true }                    // TypeScript, DPP, B2B
        // Next.js, example.com; ale nie „m.in" ani „np".
        if word.contains("."), word.split(separator: ".").allSatisfy({ $0.count >= 2 }) { return true }
        if word.contains(where: \.isNumber) && word.first!.isUppercase { return true }
        // Wielka litera w środku zdania: nazwa własna (Python, Playwright).
        return word.first!.isUppercase && !sentenceStart
    }
}
