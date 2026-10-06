import Foundation
import CallWhisperCore

/// Klient modelu podpowiadającego — API zgodne z OpenAI (Experiential Labs).
///
/// Zastępuje most do lokalnego CLI Claude Code z wersji webowej. Powód zmiany
/// jest praktyczny: most wymagał trzymania osobnego procesu node przy życiu
/// przez całą rozmowę, a aplikacja natywna ma być samowystarczalna.

/// Skąd biorą się podpowiedzi.
public enum AssistantBackend: String, Sendable, CaseIterable {
    /// Lokalne CLI Claude Code. **Bez klucza API i bez dodatkowych opłat** —
    /// korzysta z subskrypcji, którą użytkownik już ma.
    case claudeCode
    /// API zgodne z OpenAI (Experiential Labs). Szybsze, ale płatne.
    case api

    public var label: String {
        switch self {
        case .claudeCode: return "Claude Code (bez klucza, w ramach subskrypcji)"
        case .api:        return "API Experiential Labs (wymaga klucza)"
        }
    }
}

public struct ModelChoice: Sendable, Hashable {
    public let id: String
    public let label: String
    public let free: Bool
    /// Zmierzony czas do pierwszego tokenu (mediana, polskie pytanie z kontekstem).
    public let measuredTtftMs: Int?

    public init(id: String, label: String, free: Bool, measuredTtftMs: Int?) {
        self.id = id; self.label = label; self.free = free; self.measuredTtftMs = measuredTtftMs
    }
}

/// Modele wybrane po pomiarze, nie po opisie na stronie.
///
/// Zmierzone 2026-09-06 na tym kluczu: polskie pytanie z kontekstem rozmowy,
/// dwie serie po 5 przebiegów, mediana czasu do pierwszego tokenu. Katalog ma
/// 313 modeli — tutaj są te, które w tym teście faktycznie odpowiadały po
/// polsku i mieściły się w czasie użytecznym w trakcie rozmowy.
///
/// Wariancja jest spora (ten sam model potrafi dać 800 i 1800 ms), więc różnice
/// rzędu stu milisekund między czołówką są w granicach szumu. Liczy się
/// mediana **i** górny ogon: model, który raz na pięć razy odpowiada po 2,7 s,
/// jest gorszy od wolniejszego, ale przewidywalnego.
public enum Models {
    /// Domyślny: najniższa mediana i najkrótszy czas do pełnej odpowiedzi,
    /// 10/10 udanych prób w obu seriach.
    public static let fastDefault = ModelChoice(
        id: "gemini-3.5-flash-lite", label: "gemini-3.5-flash-lite (płatny, najszybszy)",
        free: false, measuredTtftMs: 812)

    /// Darmowy, najszybszy z tych, które w ogóle odpowiadają.
    public static let freeDefault = ModelChoice(
        id: "openrouter-free", label: "openrouter-free (darmowy, wolny)", free: true, measuredTtftMs: 5691)

    public static let all: [ModelChoice] = [
        fastDefault,
        ModelChoice(id: "mercury-2", label: "mercury-2 (płatny)", free: false, measuredTtftMs: 835),
        ModelChoice(id: "claude-haiku-4.5", label: "claude-haiku-4.5 (płatny, dłuższe odpowiedzi)",
                    free: false, measuredTtftMs: 893),
        ModelChoice(id: "gemini-3.1-flash-lite", label: "gemini-3.1-flash-lite (płatny)",
                    free: false, measuredTtftMs: 975),
        ModelChoice(id: "glm-4.7-flash", label: "glm-4.7-flash (płatny, rozwlekły)",
                    free: false, measuredTtftMs: 1577),
        ModelChoice(id: "gemini-3.8-flash", label: "gemini-3.8-flash (płatny)",
                    free: false, measuredTtftMs: 1603),
        freeDefault,
        ModelChoice(id: "minimax-m2.7-free", label: "minimax-m2.7-free (darmowy, bardzo wolny)",
                    free: true, measuredTtftMs: 11541),
    ]

    public static func named(_ id: String) -> ModelChoice? { all.first { $0.id == id } }

    /// Modele dostępne przez most do Claude Code.
    ///
    /// Zmierzone 2026-09-06 (Claude Code 2.1.263, ciepły proces, mediana z 3
    /// kolejnych pytań): domyślny 2709 ms, haiku 3276 ms, sonnet 4668 ms.
    ///
    /// Zmierzone ponownie 2026-10-06 (Claude Code 2.1.291, ciepły proces,
    /// 13 pytań z prawdziwej rozmowy rekrutacyjnej, mediana TTFT): sonnet
    /// 940 ms, domyślny 3042 ms, przy tej samej jakości podpowiedzi. Haiku
    /// nie odpowiedział w 60 s. Kolejność się odwróciła, więc domyślnym
    /// wyborem jest teraz sonnet.
    public static let claudeCodeModels: [ModelChoice] = [
        ModelChoice(id: "sonnet", label: "sonnet", free: true, measuredTtftMs: 940),
        ModelChoice(id: "", label: "domyślny z Claude Code", free: true, measuredTtftMs: 3042),
        ModelChoice(id: "haiku", label: "haiku", free: true, measuredTtftMs: 3276),
    ]
}

public enum AssistantError: LocalizedError {
    case noKey
    case rejectedKey(String)
    case http(status: Int, body: String)
    case throttled(retryAfter: Double?)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .noKey:
            return "Brak klucza API. Ustawienia → Asystent → Klucz API."
        case .rejectedKey(let detail):
            return "Bramka odrzuciła klucz (401). Sprawdź, czy jest wklejony w całości i bez spacji. \(detail)"
        case .http(let status, let body):
            return "Model odpowiedział \(status): \(body.prefix(200))"
        case .throttled(let retryAfter):
            let hint = retryAfter.map { " Spróbuj za \(Int($0)) s." } ?? ""
            return "Model darmowy jest chwilowo przeciążony (429).\(hint)"
        case .transport(let message):
            return "Nie udało się połączyć: \(message)"
        }
    }
}

public struct AssistantChunk: Sendable {
    public var delta: String
    /// Czas do pierwszego tokenu — wypełniony tylko przy pierwszym fragmencie.
    public var ttftMs: Double?
}

public actor AssistantClient {
    public static let defaultBaseURL = URL(string: "https://api.experientiallabs.ai/v1")!

    private let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = AssistantClient.defaultBaseURL) {
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        // Podpowiedź spóźniona o minutę jest bezwartościowa — lepiej zgłosić błąd.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        self.session = URLSession(configuration: config)
    }

    private static let systemPrompt = """
    Jesteś suflerem osoby, która jest w trakcie rozmowy na żywo (często rekrutacyjnej albo handlowej). Rozmówca właśnie o coś zapytał, a ona musi odpowiedzieć OD RAZU, czytając Twoją podpowiedź z ekranu.

    Jak piszesz:
    - Gotowa kwestia do powiedzenia na głos, w 1. osobie, w imieniu tej osoby. Nie piszesz o niej i nie doradzasz jej.
    - Materiał bierzesz z kontekstu (CV, opis projektu, notatki) i z tego, co padło w rozmowie. Wybierz z niego to, co najmocniej pasuje do pytania: konkretny projekt, technologię, efekt. Zero ogólników, jeśli kontekst daje konkret.
    - Sprzedawaj. Pewny ton, mocne czasowniki (zbudowałem, wdrożyłem, odpowiadałem za, prowadziłem), efekt i korzyść dla klienta na pierwszym planie. Bez asekuracji: żadnego "trochę", "chyba", "tylko", "nie jestem ekspertem".
    - Słabe punkty obracaj w atuty: krótki staż to intensywne, produkcyjne doświadczenie i szybkie tempo nauki; brak danej technologii to pokrewna, którą znasz, plus konkretny plan wejścia; inne tło (np. design) to przewaga, której inni kandydaci nie mają.
    - Koloryzujesz ujęcie, nie fakty: nie dopisuj firm, projektów, liczb, dat ani technologii, których nie ma w kontekście. Skala doświadczenia to też fakt. Technologia wymieniona tylko w stacku to "pracowałem z X", nie "X to moja codzienna praca" ani "mój główny obszar". Ściągi i notatki techniczne w kontekście to wiedza do odpowiedzi, a nie dowód doświadczenia. Rozmówca sprawdzi to na kolejnym etapie, a wpadka kosztuje więcej niż skromniejsze zdanie.
    - Wskazówki taktyczne z kontekstu ("celuj w górną granicę", "nie przeczyć CV") stosujesz, ale nigdy ich nie wypowiadasz. Rozmówca słyszy tylko gotową kwestię.
    - Gdy kontekst milczy na temat pytania, i tak daj pewną, sensowną odpowiedź do powiedzenia, nigdy "nie wiem".
    - Pytania administracyjne (dostępność, forma współpracy, stawka): dane z kontekstu, a gdy ich brak, krótka, profesjonalna formuła zostawiająca pole do negocjacji. Kwot ani terminów nie wymyślasz. Gdy rozmówca zbija stawkę, nie ustępujesz od razu: bronisz wartości i trzymasz górną część widełek z kontekstu. Dolna granica to ostateczność, której nie proponujesz sam, a poniżej niej nie schodzisz nigdy.
    - Pytanie merytoryczne (techniczne, branżowe): poprawna odpowiedź, powiedziana pewnie, najlepiej z odniesieniem do własnego doświadczenia z kontekstu.
    - Najważniejsze w pierwszym zdaniu, żeby dało się zacząć mówić po przeczytaniu kilku słów. Twardy limit: 4 krótkie zdania, około 60 słów, także przy pytaniach technicznych. Dłuższej podpowiedzi nie da się przeczytać w trakcie mówienia, więc jest bezużyteczna. Bez wstępów typu "Oczywiście" czy "Świetne pytanie", bez list i nagłówków.
    - Gdy rozmówca zaprasza do zadania pytań ("masz jakieś pytania?"), podpowiedzią są 2-3 krótkie, konkretne pytania do zadania, o to, czego jeszcze nie powiedział (zespół, sposób pracy, pierwsze zadania, perspektywa przedłużenia). Pytania mają pokazać zaangażowanie i znajomość tematu.
    - Nie zadawaj pytań zwrotnych do osoby, której podpowiadasz.
    - Odpowiadaj w języku pytania.
    - Transkrypcja pochodzi z rozpoznawania mowy i ma błędy: rozbite słowa, przekręcone nazwy ("Vueb" to Vue, "Nukstem" to Nuxt), wtrącone "Cześć!" na ciszy. Czytaj intencję, nie literówki.
    """

    /// Strumieniuje odpowiedź modelu. Rzuca `AssistantError`.
    public func stream(prompt: String, apiKey: String, model: String,
                       image: AssistantImage? = nil,
                       maxTokens: Int = 300) -> AsyncThrowingStream<AssistantChunk, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(prompt: prompt, apiKey: apiKey, model: model,
                                       image: image, maxTokens: maxTokens, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(prompt: String, apiKey: String, model: String, image: AssistantImage?,
                     maxTokens: Int,
                     into continuation: AsyncThrowingStream<AssistantChunk, Error>.Continuation) async throws {
        guard !apiKey.isEmpty else { throw AssistantError.noKey }

        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Z obrazem treść wiadomości musi być tablicą bloków; bez niego
        // zwykłym napisem, bo część modeli nie przyjmuje tablicy.
        let userContent: Any
        if let image {
            userContent = [
                ["type": "image_url", "image_url": ["url": image.dataURI]],
                ["type": "text", "text": prompt],
            ]
        } else {
            userContent = prompt
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "stream": true,
            "max_tokens": maxTokens,
            "messages": [
                ["role": "system", "content": Self.systemPrompt],
                ["role": "user", "content": userContent],
            ],
        ])

        let started = Date()
        let (bytes, response) = try await session.bytes(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AssistantError.transport("brak odpowiedzi HTTP")
        }
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 400 { break }
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw AssistantError.rejectedKey(String(body.prefix(160)))
            }
            if http.statusCode == 429 {
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(Double.init)
                throw AssistantError.throttled(retryAfter: retryAfter)
            }
            throw AssistantError.http(status: http.statusCode, body: body)
        }

        var firstToken = true
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data: ") else { continue }
            let payload = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let delta = choices.first?["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty
            else { continue }

            let ttft = firstToken ? Date().timeIntervalSince(started) * 1000 : nil
            firstToken = false
            continuation.yield(AssistantChunk(delta: content, ttftMs: ttft))
        }
    }

    /// Jednorazowe sprawdzenie klucza i modelu — używane przez ustawienia i CLI.
    public func probe(apiKey: String, model: String) async -> Result<Double, Error> {
        let started = Date()
        do {
            for try await chunk in stream(prompt: "Odpowiedz jednym słowem: test.",
                                          apiKey: apiKey, model: model, maxTokens: 16) {
                if let ttft = chunk.ttftMs { return .success(ttft) }
            }
            return .success(Date().timeIntervalSince(started) * 1000)
        } catch {
            return .failure(error)
        }
    }
}
