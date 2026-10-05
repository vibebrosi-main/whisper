import Foundation

/// Logika asystenta: co jest pytaniem i jak zbudować z transkrypcji prompt.
/// Czysta i testowalna — nie wie nic o HTTP ani o dostawcy modelu.
/// Port z `extension/src/core/assistant.js`.

/// Słowa otwierające pytanie. Pytajnika w mowie nie ma — ASR go nie zawsze daje.
private let questionOpenersPL = [
    "czy", "jak", "jaki", "jaka", "jakie", "jakim", "jakich", "ile", "kiedy", "gdzie",
    "kto", "komu", "kogo", "co", "czemu", "dlaczego", "po co", "skad", "dokad", "ktory",
    "ktora", "ktore", "czym", "w czym", "na czym",
    // Formy odmienione: bez nich „od której wersji" i „jakiego typu" przepadały.
    "której", "którego", "którym", "których", "jakiego", "jakiej", "jakimi", "ilu",
]
private let questionOpenersEN = [
    "is", "are", "was", "were", "do", "does", "did", "can", "could", "should", "would",
    "will", "what", "why", "how", "when", "where", "who", "which", "whose", "whom",
]
private let allOpeners: [[String]] = (questionOpenersPL + questionOpenersEN)
    .map { Text.fold($0).split(separator: " ").map(String.init) }

/// Zwroty, po których ktoś prosi o konkret — szukane w dowolnym miejscu.
/// Zapisane bez znaków diakrytycznych, bo porównujemy tekst złożony do ASCII.
private let askPhrases = [
    "mam pytanie", "pytanie do", "wie ktos", "wiesz moze", "czy ktos wie",
    "jak to dziala", "co to znaczy", "zastanawiam sie", "nie wiem czy",
    "ciekawi mnie", "wytlumacz", "przypomnij mi",
    "anyone know", "does anyone", "what does", "how do we", "quick question",
]

/// Pytania techniczno-organizacyjne, na które asystent nie ma czego odpowiedzieć.
private let smallTalkPatterns: [NSRegularExpression] = [
    #"\b(slychac|slyszysz|slyszycie|slysze|widac|widzisz|widzicie|widze)\b"#,
    #"\b(hear|see)\s+(me|my\s+screen|you)\b"#,
    #"\bhalo+\b"#,
    #"\bjestes\s+tam\b"#,
    #"\b(mozemy|to)\s+zaczyna(my|c)\b"#,
    #"\bwszyscy\s+(sa|juz\s+sa)\b"#,
    #"\b(dziala|dziela)\s+(mikrofon|kamera|dzwiek)\b"#,
].compactMap { try? NSRegularExpression(pattern: $0) }

private let minQuestionChars = 8
private let minQuestionWords = 3

public struct QuestionVerdict: Sendable, Equatable {
    public var isQuestion: Bool
    public var confidence: Double
    public var reason: String
    public var question: String
}

public enum QuestionDetector {
    /// Dzieli wypowiedź na frazy po interpunkcji, którą daje ASR.
    public static func splitClauses(_ text: String) -> [String] {
        var out: [String] = []
        var buffer = ""
        for ch in text {
            if ",.;!?".contains(ch) {
                let trimmed = buffer.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(trimmed) }
                buffer = ""
                continue
            }
            buffer.append(ch)
        }
        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    /// Twardy limit długości pytania. Prompt ma być krótki, nie kompletny.
    static let maxQuestionChars = 220

    /// Słówka, które w mowie stoją PRZED właściwym słowem pytającym: „od której
    /// wersji", „w czym piszesz". Dopuszczamy najwyżej jedno.
    static let leadingParticles: Set<String> = [
        "od", "do", "w", "na", "z", "za", "po", "przy", "dla", "o", "u",
    ]

    /// Słowa wypełniające i wstępy, po których dopiero zaczyna się treść:
    /// „Okej, dobra, a powiedz mi, jak długo programujesz?". Fraza złożona
    /// wyłącznie z nich jest wstępem, a nie treścią.
    static let fillerWords: Set<String> = [
        "okej", "ok", "okay", "dobra", "dobrze", "no", "tak", "mhm", "hmm", "ehm", "eh", "yyy", "aha",
        "fajnie", "super", "jasne", "swietnie", "sluchaj", "wiesz", "czekaj", "hej",
        "a", "i", "to", "wiec", "ale", "czyli", "jeszcze", "jedno", "jakby", "teraz",
        "powiedz", "powiedzcie", "mi", "nam", "mam", "pytanie", "pytanko", "w", "sensie", "znaczy",
        "na", "przyklad", "generalnie", "ogolnie", "mozesz", "mozecie", "powiedziec",
        "so", "well", "alright", "right", "tell", "me", "question",
    ]

    /// Końcówki, które z oznajmienia robią prośbę o potwierdzenie: „…, tak?".
    static let confirmationTags: Set<String> = ["tak", "nie", "prawda", "no nie", "nie prawda", "right", "yeah"]

    public struct Sentence: Sendable, Equatable {
        public var text: String
        /// `?`, `.`, `!`, `…` (urwane) albo pusty (bez interpunkcji).
        public var end: String
    }

    /// Dzieli wypowiedź na zdania, pamiętając, czym się kończyły.
    ///
    /// Kropka kończy zdanie tylko przed spacją albo na końcu: „Next.js" i „40 ml."
    /// to nie są dwa zdania. Dwie kropki i więcej to wielokropek.
    public static func splitSentences(_ text: String) -> [Sentence] {
        var out: [Sentence] = []
        let chars = Array(text)
        var buffer = ""
        func push(_ end: String) {
            let trimmed = buffer.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { out.append(Sentence(text: trimmed, end: end)) }
            buffer = ""
        }
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if ch == "?" || ch == "!" {
                var end = String(ch)
                while i + 1 < chars.count, chars[i + 1] == "?" || chars[i + 1] == "!" {
                    if chars[i + 1] == "?" { end = "?" }
                    i += 1
                }
                push(end)
            } else if ch == "…" {
                push("…")
            } else if ch == "." {
                var run = 1
                while i + run < chars.count, chars[i + run] == "." { run += 1 }
                if run >= 2 {
                    i += run
                    push("…")
                    continue
                }
                if i + 1 == chars.count || chars[i + 1].isWhitespace { push(".") } else { buffer.append(ch) }
            } else {
                buffer.append(ch)
            }
            i += 1
        }
        push("")
        return out
    }

    static func words(_ text: String) -> [String] {
        Text.fold(text)
            .split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber)) && $0 != "'" })
            .map(String.init)
    }

    static func isFillerClause(_ clause: String) -> Bool {
        words(clause).allSatisfy { fillerWords.contains($0) }
    }

    static func hasAskPhrase(_ text: String) -> Bool {
        let folded = words(text).joined(separator: " ")
        return askPhrases.contains { folded.contains($0) }
    }

    /// Czy fraza zaczyna się od słowa pytającego (po wypełniaczach i jednym przyimku).
    static func opensQuestion(_ clause: String) -> Bool {
        var all = words(clause)
        while let first = all.first, fillerWords.contains(first), !allOpeners.contains(where: { $0[0] == first }) {
            all.removeFirst()
        }
        guard let first = all.first else { return false }
        var starts = [all]
        if leadingParticles.contains(first) { starts.append(Array(all.dropFirst())) }
        return starts.contains { ws in
            guard !ws.isEmpty else { return false }
            return allOpeners.contains { parts in
                parts.count <= ws.count && parts.enumerated().allSatisfy { ws[$0.offset] == $0.element }
            }
        }
    }

    struct Clause { var text: String; var start: Int }

    /// Frazy zdania razem z miejscem (w znakach), w którym zaczynają się w tekście.
    static func clauses(of sentence: String) -> [Clause] {
        let chars = Array(sentence)
        var out: [Clause] = []
        var start = 0
        for i in 0...chars.count {
            if i == chars.count || chars[i] == "," || chars[i] == ";" {
                let text = String(chars[start..<i]).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { out.append(Clause(text: text, start: start)) }
                start = i + 1
            }
        }
        return out
    }

    struct Score { var confidence: Double; var reasons: [String]; var start: Int }

    /// Ocena jednego zdania.
    ///
    /// Słowo pytające liczy się tylko na początku zdania: po wypełniaczach
    /// („Okej, dobra, a jak…") albo po wstępie („mam pytanie, czym…",
    /// „powiedz mi, ile…"). Po zwykłej frazie to prawie zawsze zaimek względny
    /// albo spójnik: „Podobało mi się, jak zrobiłeś", „praca, która była".
    static func score(_ sentence: Sentence) -> Score {
        let parts = clauses(of: sentence.text)
        let first = parts.firstIndex { !isFillerClause($0.text) } ?? -1
        var head = first
        var opener = false
        var k = Swift.max(first, 0)
        while k < parts.count {
            let atStart = k == first
            let afterLead = k > 0 && (isFillerClause(parts[k - 1].text) || hasAskPhrase(parts[k - 1].text))
            if (atStart || afterLead) && opensQuestion(parts[k].text) {
                opener = true
                head = k
                break
            }
            k += 1
        }

        let asked = sentence.end == "?"
        let lastWords = parts.count > 1 ? words(parts[parts.count - 1].text).joined(separator: " ") : ""
        let confirmation = asked && !opener && confirmationTags.contains(lastWords)
        let phrase = hasAskPhrase(sentence.text)

        var confidence = 0.0
        var reasons: [String] = []
        if asked {
            confidence += confirmation ? 0.25 : 0.6
            reasons.append(confirmation ? "potwierdzenie" : "pytajnik")
        }
        if opener {
            // Kropka albo wykrzyknik od ASR to sygnał, że zdanie jest
            // oznajmujące, a wielokropek, że urwane.
            confidence += asked || sentence.end.isEmpty ? 0.4 : 0.2
            reasons.append("słowo-pytające")
        }
        if phrase {
            confidence += 0.4
            reasons.append("zwrot-pytający")
        }
        return Score(confidence: Swift.min(1, (confidence * 100).rounded() / 100),
                     reasons: reasons,
                     start: head >= 0 ? parts[head].start : 0)
    }

    /// Czy wypowiedź zawiera pytanie wymagające odpowiedzi merytorycznej.
    ///
    /// Oceniamy każde zdanie osobno i bierzemy najlepsze. Do modelu idzie samo
    /// pytanie: od jego początku (bez wstępu) do końca serii pytań po nim.
    public static func detect(_ text: String) -> QuestionVerdict {
        let raw = Text.stripHallucinations(text)
        let folded = Text.fold(raw)
        let allWords = folded.isEmpty ? [] : folded.split(separator: " ").map(String.init)

        func no(_ reason: String) -> QuestionVerdict {
            QuestionVerdict(isQuestion: false, confidence: 0, reason: reason, question: "")
        }

        if raw.count < minQuestionChars || allWords.count < minQuestionWords { return no("za-krótkie") }
        if smallTalkPatterns.contains(where: { matches($0, folded) }) { return no("small-talk") }

        let sentences = splitSentences(raw)
        let scored = sentences.map(score)
        guard !scored.isEmpty else { return no("brak-sygnałów") }
        var best = 0
        for (i, s) in scored.enumerated() where s.confidence > scored[best].confidence { best = i }
        let top = scored[best]
        guard top.confidence >= 0.35 else {
            return QuestionVerdict(isQuestion: false, confidence: top.confidence,
                                   reason: top.reasons.isEmpty ? "brak-sygnałów" : top.reasons.joined(separator: "+"),
                                   question: "")
        }

        // Seria pytań wokół najlepszego; wstecz także potwierdzenia, bo bez
        // „…, której nie ma w CV, tak?" pytanie „czy ona gdzieś jest" nic nie znaczy.
        var from = best
        while from > 0 && (scored[from - 1].confidence >= 0.35 || sentences[from - 1].end == "?") { from -= 1 }
        var to = best
        while to + 1 < sentences.count && sentences[to + 1].end == "?" && scored[to + 1].confidence >= 0.35 { to += 1 }

        func render(_ a: Int, _ b: Int) -> String {
            (a...b).map { i -> String in
                let s = sentences[i]
                let body = i == a
                    ? String(Array(s.text)[scored[a].start...]).trimmingCharacters(in: .whitespaces)
                    : s.text
                return body + s.end
            }.joined(separator: " ")
        }
        var question = render(from, to)
        if question.count > maxQuestionChars { question = render(best, best) }
        if question.count > maxQuestionChars { question = String(question.prefix(maxQuestionChars - 1)) + "…" }

        return QuestionVerdict(isQuestion: true, confidence: top.confidence,
                               reason: top.reasons.joined(separator: "+"), question: question)
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}

public let defaultContextSegments = 6
private let maxContextChars = 1200
/// Twardy limit kontekstu projektu — dłuższy opis to wolniejsza odpowiedź.
private let maxProjectContextChars = 8000

/// Buduje prompt: pytanie + minimalny konieczny kontekst.
///
/// Kontekst trzymamy krótko celowo — każdy dodatkowy token to opóźnienie,
/// a odpowiedź ma paść, zanim rozmowa pójdzie dalej.
public func buildPrompt(question: String, segments: [Segment] = [], title: String = "",
                        projectContext: String = "",
                        maxSegments: Int = defaultContextSegments) -> String? {
    let asked = Text.normalize(question)
    guard !asked.isEmpty else { return nil }

    let recent = segments.suffix(maxSegments)
        .map { "\($0.speaker): \(Text.normalize($0.text))" }
        .filter { $0.count > 3 }

    var context = recent.joined(separator: "\n")
    if context.count > maxContextChars {
        context = "…" + String(context.suffix(maxContextChars))
    }

    var parts: [String] = []
    let t = Text.normalize(title)
    if !t.isEmpty { parts.append("Spotkanie: \(t)") }
    // Kontekst projektu idzie przed transkryptem: to tło, na którym toczy się
    // rozmowa, a nie to, co przed chwilą padło.
    if !projectContext.isEmpty {
        let trimmed = projectContext.count > maxProjectContextChars
            ? String(projectContext.prefix(maxProjectContextChars)) + "…"
            : projectContext
        parts.append("Kontekst projektu, o którym jest rozmowa:\n\(trimmed)")
    }
    if !context.isEmpty { parts.append("Ostatnie wypowiedzi:\n\(context)") }
    parts.append("Pytanie, na które masz odpowiedzieć:\n\(asked)")
    return parts.joined(separator: "\n\n")
}

public enum AnswerStatus: String, Sendable { case pending, streaming, done, error }

public struct AssistantItem: Sendable, Identifiable, Equatable {
    public var id: String
    public var question: String
    public var speaker: String?
    public var at: Double
    public var auto: Bool
    public var status: AnswerStatus
    public var answer: String
    public var error: String?
    public var durationMs: Double?
    /// Czas do pierwszego tokenu — mierzony, bo to jedyna latencja, którą widać.
    public var ttftMs: Double?
    /// Czy do pytania dołączono obrazek. Sam obrazek zostaje poza rdzeniem —
    /// tutaj wystarczy wiedzieć, że interfejs ma pokazać znacznik.
    public var hasImage: Bool = false
}

/// Stan pytań i odpowiedzi w trakcie rozmowy.
public final class AssistantSession {
    private var items: [String: AssistantItem] = [:]
    private var order: [String] = []
    private var sequence = 0
    public let maxItems: Int
    public private(set) var revision = 0

    public init(maxItems: Int = 30) { self.maxItems = maxItems }

    @discardableResult
    public func add(question: String, speaker: String? = nil, at: Double = nowMs(),
                    auto: Bool = false, hasImage: Bool = false) -> AssistantItem {
        sequence += 1
        let id = "q\(sequence)"
        let item = AssistantItem(id: id, question: Text.normalize(question), speaker: speaker, at: at,
                                 auto: auto, status: .pending, answer: "", error: nil,
                                 durationMs: nil, ttftMs: nil, hasImage: hasImage)
        items[id] = item
        order.append(id)
        trim()
        revision += 1
        return item
    }

    @discardableResult
    public func append(_ id: String, delta: String, ttftMs: Double? = nil) -> AssistantItem? {
        guard var item = items[id] else { return nil }
        if item.answer.isEmpty, let ttft = ttftMs, item.ttftMs == nil { item.ttftMs = ttft }
        item.answer += delta
        item.status = .streaming
        items[id] = item
        revision += 1
        return item
    }

    @discardableResult
    public func complete(_ id: String, answer: String? = nil, durationMs: Double? = nil) -> AssistantItem? {
        guard var item = items[id] else { return nil }
        if let answer { item.answer = answer }
        item.status = .done
        item.durationMs = durationMs
        items[id] = item
        revision += 1
        return item
    }

    @discardableResult
    public func fail(_ id: String, error: String) -> AssistantItem? {
        guard var item = items[id] else { return nil }
        item.status = .error
        item.error = error
        items[id] = item
        revision += 1
        return item
    }

    public func get(_ id: String) -> AssistantItem? { items[id] }
    public var all: [AssistantItem] { order.compactMap { items[$0] } }

    private func trim() {
        while order.count > maxItems {
            items.removeValue(forKey: order.removeFirst())
        }
    }
}

/// Wyławia pytania z napływających segmentów transkryptu.
///
/// Sprawdza wyłącznie segmenty domknięte: wypowiedź w trakcie jeszcze się
/// zmienia, a zadanie pytania w połowie zdania kosztuje czas i daje odpowiedź
/// na coś, co nie padło.
public final class QuestionWatcher {
    public struct Found: Sendable {
        public var segmentId: String
        public var question: String
        public var utterance: String
        public var speaker: String
        public var at: Double
        public var confidence: Double
        public var reason: String
    }

    private var seen: Set<String> = []
    private var seenOrder: [String] = []
    public var minConfidence: Double
    public var maxSeen: Int
    public var onQuestion: (Found) -> Void

    public init(minConfidence: Double = 0.35, maxSeen: Int = 500, onQuestion: @escaping (Found) -> Void = { _ in }) {
        self.minConfidence = minConfidence
        self.maxSeen = maxSeen
        self.onQuestion = onQuestion
    }

    @discardableResult
    public func scan(_ segments: [Segment]) -> [Found] {
        var found: [Found] = []
        for segment in segments {
            guard segment.final, !seen.contains(segment.id) else { continue }
            seen.insert(segment.id)
            seenOrder.append(segment.id)

            let verdict = QuestionDetector.detect(segment.text)
            guard verdict.isQuestion, verdict.confidence >= minConfidence else { continue }

            let item = Found(
                segmentId: segment.id,
                // Właściwe pytanie, bez dygresji przed nim — mniej tokenów, szybsza odpowiedź.
                question: verdict.question.isEmpty ? segment.text : verdict.question,
                utterance: segment.text,
                speaker: segment.speaker,
                at: segment.startedAt,
                confidence: verdict.confidence,
                reason: verdict.reason
            )
            found.append(item)
            onQuestion(item)
        }
        trim()
        return found
    }

    private func trim() {
        while seenOrder.count > maxSeen {
            seen.remove(seenOrder.removeFirst())
        }
    }

    public func reset() { seen.removeAll(); seenOrder.removeAll() }
}
