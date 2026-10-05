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
    /// Dzieli wypowiedź na frazy.
    ///
    /// W prawdziwej mowie pytanie prawie nigdy nie stoi na początku wypowiedzi:
    /// „Wracając do migracji, mam pytanie, czym różni się RPO od RTO". Sprawdzanie
    /// tylko pierwszego słowa całości gubiło takie przypadki — a to one dominują.
    public static func splitClauses(_ text: String) -> [String] {
        splitClausesWithEnd(text).map(\.text)
    }

    public struct Clause: Sendable {
        public var text: String
        public var endsQuestion: Bool
    }

    /// Jak `splitClauses`, ale zachowuje informację, czy fraza kończyła się
    /// pytajnikiem. Bez tego nie da się powiedzieć, GDZIE pytanie się kończy —
    /// a branie wszystkiego do końca wypowiedzi wciągało do promptu odpowiedź,
    /// która po nim padła.
    public static func splitClausesWithEnd(_ text: String) -> [Clause] {
        var out: [Clause] = []
        var buffer = ""
        for ch in text {
            if ",.;!?".contains(ch) {
                let trimmed = buffer.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { out.append(Clause(text: trimmed, endsQuestion: ch == "?")) }
                buffer = ""
                continue
            }
            buffer.append(ch)
        }
        let tail = buffer.trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { out.append(Clause(text: tail, endsQuestion: false)) }
        return out
    }

    /// Ile fraz doklejamy do pytania, gdy pytajnik nigdzie nie padł.
    static let maxQuestionClauses = 2
    /// Twardy limit długości pytania. Prompt ma być krótki, nie kompletny.
    static let maxQuestionChars = 220
    /// Jak daleko szukamy pytajnika, zanim uznamy, że go nie ma.
    static let questionLookahead = 6

    /// Wycina pytanie zaczynające się od frazy `openerIndex`.
    ///
    /// Koniec wyznacza pytajnik. Gdy go nie ma (mowa często go nie daje),
    /// bierzemy najwyżej `maxQuestionClauses` fraz — dalej to już nie jest
    /// pytanie, tylko odpowiedź na nie.
    static func extractQuestion(_ raw: String, from openerIndex: Int) -> String {
        let clauses = splitClausesWithEnd(raw)
        guard !clauses.isEmpty, openerIndex < clauses.count else { return raw }

        // Najpierw szukamy pytajnika w rozsądnym zasięgu. Pytanie z przecinkami
        // („co się dzieje, gdy mija północ?") ma kilka fraz i ucięcie go po
        // dwóch gubi właśnie tę część, o którą chodzi.
        var end = -1
        var i = openerIndex
        while i < clauses.count && i < openerIndex + questionLookahead {
            if clauses[i].endsQuestion { end = i; break }
            i += 1
        }
        // Bez pytajnika bierzemy dwie frazy — dalej to już zwykle odpowiedź,
        // która po pytaniu padła.
        if end < 0 { end = Swift.min(openerIndex + maxQuestionClauses - 1, clauses.count - 1) }

        let joined = clauses[openerIndex...end].map(\.text).joined(separator: ", ")
        return joined.count > maxQuestionChars
            ? String(joined.prefix(maxQuestionChars - 1)) + "…"
            : joined
    }

    /// Słówka, które w mowie stoją PRZED właściwym słowem pytającym.
    ///
    /// „A jak to wpłynie na czas budowania" i „Od której wersji jest dostępny"
    /// to najzwyklejszy polski szyk, a sprawdzanie wyłącznie pierwszego słowa
    /// frazy gubiło oba — bo `jak` i `ktorej` stały na drugiej pozycji. Bez
    /// pytajnika (a mowa go nie zawsze daje) takie pytanie przepadało bez śladu.
    static let leadingParticles: Set<String> = [
        "a", "no", "i", "to", "wiec", "ale", "czyli", "oraz",
        "od", "do", "w", "na", "z", "za", "po", "przy", "dla", "o", "u",
    ]

    /// Czy fraza zaczyna się od słowa pytającego, ewentualnie po jednym słówku.
    static func opensQuestion(_ clause: String) -> Bool {
        let all = Text.fold(clause).split(separator: " ").map(String.init)
        guard let first = all.first else { return false }

        // Dopuszczamy najwyżej jedno słówko przed pytaniem — dwa to już zdanie,
        // a nie wtrącenie, i zaczęłoby łapać zwykłe wypowiedzi.
        var starts = [all]
        if leadingParticles.contains(first) { starts.append(Array(all.dropFirst())) }

        return starts.contains { words in
            guard !words.isEmpty else { return false }
            return allOpeners.contains { parts in
                guard parts.count <= words.count else { return false }
                return parts.enumerated().allSatisfy { words[$0.offset] == $0.element }
            }
        }
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Czy wypowiedź wygląda na pytanie wymagające odpowiedzi merytorycznej.
    public static func detect(_ text: String) -> QuestionVerdict {
        let raw = Text.normalize(text)
        let folded = Text.fold(raw)
        let words = folded.isEmpty ? [] : folded.split(separator: " ").map(String.init)

        func no(_ reason: String) -> QuestionVerdict {
            QuestionVerdict(isQuestion: false, confidence: 0, reason: reason, question: "")
        }

        if raw.count < minQuestionChars || words.count < minQuestionWords { return no("za-krótkie") }
        if smallTalkPatterns.contains(where: { matches($0, folded) }) { return no("small-talk") }

        var confidence = 0.0
        var reasons: [String] = []
        let clauses = splitClauses(raw)

        if raw.hasSuffix("?") {
            confidence += 0.6
            reasons.append("pytajnik")
        }

        // Fraza otwarta słowem pytającym — i to od niej zaczyna się właściwe pytanie.
        let openerIndex = clauses.firstIndex(where: opensQuestion)
        if let idx = openerIndex {
            confidence += idx == 0 ? 0.35 : 0.45
            reasons.append(idx == 0 ? "słowo-pytające" : "słowo-pytające-w-środku")
        }

        // Jawny zwrot („mam pytanie", „quick question") jest jednoznaczny
        // i musi wystarczyć sam.
        if askPhrases.contains(where: { folded.contains($0) }) {
            confidence += 0.4
            reasons.append("zwrot-pytający")
        }

        confidence = Swift.min(1, confidence)

        // Do modelu wysyłamy właściwe pytanie — bez dygresji przed nim i bez
        // tego, co padło po nim. Przy długiej, niepodzielonej wypowiedzi branie
        // wszystkiego do końca wciągało do promptu odpowiedź na to samo pytanie,
        // prompt rósł do setek znaków, a odpowiedź szła 9 s zamiast 1,5 s.
        let question: String = {
            if let idx = openerIndex { return Self.extractQuestion(raw, from: idx) }
            return raw
        }()

        return QuestionVerdict(
            isQuestion: confidence >= 0.35,
            confidence: confidence,
            reason: reasons.isEmpty ? "brak-sygnałów" : reasons.joined(separator: "+"),
            question: question
        )
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
