import Foundation

/// Scalanie strumieniowego tekstu z rozpoznawania na żywo.
///
/// Silniki ASR aktualizują ten sam blok tekstu w miejscu: tekst rośnie, bywa
/// poprawiany, a czasem przycinany od początku (przewijane okno). `reconcile`
/// sprowadza kolejne migawki do jednego, niezduplikowanego zdania.
///
/// Port 1:1 z `extension/src/core/text.js`. Różnica względem JS: operujemy na
/// `Character`, a nie na jednostkach UTF-16 — inaczej polskie znaki potrafiłyby
/// rozjechać indeksy przy liczeniu wspólnego prefiksu.
public enum Text {
    private static let zeroWidth: Set<Character> = ["\u{200B}", "\u{200C}", "\u{200D}", "\u{FEFF}", "\u{00AD}"]

    /// Normalizacja białych znaków + usunięcie znaków zerowej szerokości.
    public static func normalize(_ input: String?) -> String {
        guard let input else { return "" }
        var out = ""
        out.reserveCapacity(input.count)
        var pendingSpace = false
        var started = false
        for ch in input {
            if zeroWidth.contains(ch) { continue }
            if ch.isWhitespace {
                if started { pendingSpace = true }
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(ch)
            started = true
        }
        return out
    }

    /// Długość wspólnego prefiksu dwóch napisów (w znakach).
    public static func commonPrefixLength(_ a: [Character], _ b: [Character]) -> Int {
        let max = Swift.min(a.count, b.count)
        var i = 0
        while i < max && a[i] == b[i] { i += 1 }
        return i
    }

    /// Najdłuższy sufiks `a`, który jest prefiksem `b`.
    /// Okno ograniczone do `limit` znaków — chroni przed O(n²) na długich blokach.
    public static func overlapLength(_ a: [Character], _ b: [Character], limit: Int = 240) -> Int {
        let max = Swift.min(a.count, b.count, limit)
        guard max > 0 else { return 0 }
        var k = max
        while k > 0 {
            if Array(a.suffix(k)) == Array(b.prefix(k)) { return k }
            k -= 1
        }
        return 0
    }

    /// Minimalna liczba znaków nakładki, przy której ufamy sklejeniu.
    private static let minOverlap = 6
    /// Minimalny wspólny prefiks, przy którym uznajemy migawkę za poprawkę.
    private static let minRevisionPrefix = 12

    /// Łączy poprzedni stan segmentu z nową migawką tekstu.
    public static func reconcile(_ prev: String, _ next: String) -> String {
        let a = normalize(prev)
        let b = normalize(next)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if a == b { return a }

        // 1. Wzrost strumienia: nowa migawka to stara + ogon.
        if b.hasPrefix(a) { return b }

        let ac = Array(a), bc = Array(b)

        // 2. Poprawka in-place: wspólny początek, zmieniona końcówka.
        let cp = commonPrefixLength(ac, bc)
        if cp >= minRevisionPrefix || (!ac.isEmpty && Double(cp) >= Double(ac.count) * 0.6) {
            return bc.count >= ac.count ? b : a
        }

        // 3. Przewijane okno: koniec starego = początek nowego.
        let k = overlapLength(ac, bc)
        if k >= minOverlap { return a + String(bc.dropFirst(k)) }

        // 4. Zawieranie — nic nowego albo pełne rozszerzenie.
        if a.contains(b) { return a }
        if b.contains(a) { return b }

        // 5. Rozłączne fragmenty tej samej wypowiedzi — doklejamy.
        return "\(a) \(b)"
    }

    /// Zgrubna liczba słów (do heurystyk i statystyk).
    public static func wordCount(_ text: String) -> Int {
        let t = normalize(text)
        return t.isEmpty ? 0 : t.split(separator: " ").count
    }

    /// Ucina tekst do `max` znaków, dodając wielokropek.
    public static func truncate(_ text: String, max: Int = 120) -> String {
        let t = normalize(text)
        return t.count <= max ? t : String(t.prefix(max - 1)) + "…"
    }

    /// whisper.cpp zwraca tekst z twardymi łamaniami linii i znacznikami
    /// nie-mowy — w transkrypcie chcemy jedną, czystą linię.
    ///
    /// Bez tego `[BLANK_AUDIO]` i `(szum)` trafiałyby do notatki jako
    /// wypowiedzi, a whisper dokleja je chętnie na ciszy.
    public static func cleanWhisper(_ raw: String) -> String {
        var out = ""
        var square = 0
        var round = 0
        for ch in raw {
            switch ch {
            case "[": square += 1; out.append(" ")
            case "]": square = Swift.max(0, square - 1); out.append(" ")
            case "(": round += 1; out.append(" ")
            case ")": round = Swift.max(0, round - 1); out.append(" ")
            default:
                if square == 0 && round == 0 { out.append(ch) }
            }
        }
        return stripHallucinations(out)
    }

    /// Typowe halucynacje whispera na ciszy i szumie („Dziękuję za uwagę.",
    /// „Zdjękuje za oglądanie!"). W rozmowie padały co minutę, a doklejone do
    /// pytania psuły prompt.
    private static let hallucinations = try! NSRegularExpression(
        pattern: #"(?:^|(?<=[\s.,!?]))(?:z?dzi[eę]kuj[eę]|zdj[eę]kuj[eę]|dzi[eę]ki)\s+(?:bardzo\s+)?za\s+(?:uwag[eę]|ogl[aą]danie|obejrzenie)[.!]*|napisy\s+(?:stworzone|wykonane)\s+przez[^.!?]*[.!?]?"#,
        options: [.caseInsensitive])

    /// Usuwa znane halucynacje whispera.
    public static func stripHallucinations(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return normalize(hallucinations.stringByReplacingMatches(in: text, range: range, withTemplate: " "))
    }

    /// Składa tekst do ASCII: małe litery, bez znaków diakrytycznych.
    ///
    /// Bez tego wzorce są kruche: w mowie szyk jest swobodny, a `ł` nie rozkłada
    /// się przez NFD na literę + znak łączący, więc wymaga osobnego podstawienia.
    public static func fold(_ text: String) -> String {
        let lowered = text.lowercased().replacingOccurrences(of: "ł", with: "l")
        return lowered.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US"))
    }
}
