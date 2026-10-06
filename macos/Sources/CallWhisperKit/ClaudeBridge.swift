import Foundation

/// Most do lokalnego CLI Claude Code.
///
/// Powód istnienia: **nie wymaga klucza API ani płatności** — korzysta
/// z subskrypcji, którą użytkownik już ma. To jedyna darmowa opcja, która
/// nadąża za rozmową: modele z sufiksem `-free` w Experiential Labs dają
/// 5,7 s do pierwszego tokenu i bywają odrzucane błędem 429, a most ~1,8 s.
///
/// Zmierzone 2026-09-06, Claude Code 2.1.263, macOS:
///
///   zimny start          3856 ms do pierwszego tokenu
///   pierwsze ciepłe      1265-1975 ms
///   kolejne w tej samej sesji  2,7-4,7 s (kontekst rozmowy z CLI narasta)
///
/// Wąskim gardłem nie jest inferencja, tylko start procesu: konfiguracja,
/// autoryzacja, hooki, serwery MCP. Z tego samego powodu Haiku **nie** jest
/// szybszy od modelu domyślnego — sprawdzone dwa razy, mediana 3276 ms vs 2709 ms.
///
/// Jeden ciepły proces obsługuje kilka pytań, ale **nie całą rozmowę**: sesja
/// CLI kumuluje historię, a nasze prompty i tak niosą własny kontekst
/// z transkryptu, więc ta historia jest czystym narzutem. Zmierzone na pięciu
/// kolejnych pytaniach w jednej sesji:
///
///   pytanie 1  1727 ms      pytanie 4  4659 ms
///   pytanie 2  1200 ms      pytanie 5  6107 ms
///   pytanie 3  1343 ms
///
/// Stąd wymiana sesji co `maxUses` pytań, z zapasową rozgrzewaną **w czasie
/// bezczynności**. Próbowałem świeżej sesji na każde pytanie — wyszło gorzej
/// (4,5-8,6 s), bo ciągłe startowanie procesów `claude` konkuruje o procesor
/// z tym, który właśnie odpowiada.
///
/// Port z `assistant/claude-process.mjs`.
public actor ClaudeBridge {
    /// Narzędzia wyłączamy: chcemy odpowiedzi, nie pracy agentowej na plikach.
    private static let disabledTools = [
        "Bash", "Read", "Write", "Edit", "Glob", "Grep",
        "WebFetch", "WebSearch", "Task", "TodoWrite", "NotebookEdit",
    ].joined(separator: ",")

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

    public enum BridgeError: LocalizedError {
        case cliMissing
        case processDied(Int32)
        case timeout(Int)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .cliMissing:
                return "Nie znalazłem CLI `claude`. Zainstaluj Claude Code albo wybierz model przez API."
            case .processDied(let code):
                return "Proces claude zakończył się (kod \(code))."
            case .timeout(let seconds):
                return "Claude nie odpowiedział w \(seconds) s."
            case .failed(let message):
                return message.isEmpty ? "Claude zwrócił błąd." : message
            }
        }
    }

    /// Aplikacja uruchomiona z Findera nie dziedziczy `PATH` z powłoki.
    static let searchPaths = [
        "\(NSHomeDirectory())/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
    ]

    public static func locateCLI() -> URL? {
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    public static var isAvailable: Bool { locateCLI() != nil }

    private final class Job {
        let prompt: String
        let image: AssistantImage?
        let onDelta: @Sendable (String) -> Void
        var text = ""
        var finished = false
        let continuation: CheckedContinuation<String, Error>
        init(prompt: String, image: AssistantImage? = nil,
             onDelta: @escaping @Sendable (String) -> Void,
             continuation: CheckedContinuation<String, Error>) {
            self.prompt = prompt
            self.image = image
            self.onDelta = onDelta
            self.continuation = continuation
        }
    }

    /// Jedna sesja CLI: proces, jego wejście i jedno pytanie w locie.
    private final class Session {
        let process: Process
        let stdin: Pipe
        var buffer = ""
        var current: Job?
        var isReady = false
        var used = false
        /// Ile pytań ta sesja już obsłużyła.
        var uses = 0

        init(process: Process, stdin: Pipe) {
            self.process = process
            self.stdin = stdin
        }

        func terminate() {
            try? stdin.fileHandleForWriting.close()
            process.terminate()
        }
    }

    private var sessions: [ObjectIdentifier: Session] = [:]
    /// Sesja obsługująca bieżące pytania.
    private var active: Session?
    /// Rozgrzana sesja czekająca na wymianę.
    private var spare: Session?
    private var warming = false
    private var model: String?
    private var stopped = false

    public private(set) var reportedModel: String?
    public var isReady: Bool { (active ?? spare)?.isReady ?? false }

    public init() {}

    static let debug = ProcessInfo.processInfo.environment["CW_DEBUG"] == "1"
    private func trace(_ m: String) {
        guard Self.debug else { return }
        FileHandle.standardError.write(Data("[bridge] \(m)\n".utf8))
    }

    // MARK: - cykl życia

    /// Zapamiętuje konfigurację. Procesu **nie** startuje — od tego jest
    /// `warmup()`.
    ///
    /// Wcześniej `start()` odpalał rozgrzewanie w oderwanym `Task`, a wołany
    /// zaraz po nim `warmup()` trafiał na podniesioną flagę `warming`
    /// i wychodził natychmiast, nie czekając na nic. Rozgrzewka nigdy się więc
    /// nie kończyła przed pierwszym pytaniem i każde pytanie płaciło zimny
    /// start — w interfejsie wyglądało to na 9 s do pierwszego tokenu.
    public func start(model: String? = nil) throws {
        self.model = model
        stopped = false
        guard ClaudeBridge.locateCLI() != nil else { throw BridgeError.cliMissing }
    }

    public func stop() {
        stopped = true
        for session in sessions.values {
            session.current.map { finish($0, .failure(CancellationError())) }
            session.terminate()
        }
        sessions.removeAll()
        spare = nil
        active = nil
    }

    /// Po tylu pytaniach wymieniamy sesję — zanim historia zacznie kosztować.
    private static let maxUses = 3

    /// Przygotowuje zapasową sesję i rozgrzewa ją. Wołane w bezczynności.
    private func replenish() async {
        guard !stopped, spare == nil, !warming else { trace("replenish: pomijam"); return }
        trace("replenish: start")
        warming = true
        defer { warming = false }
        guard let session = try? spawnSession() else { return }
        // Rozgrzewka: pierwszy strzał w nowym procesie kosztuje ~4 s i ma
        // paść między pytaniami, a nie w środku rozmowy.
        _ = try? await run(on: session, prompt: "Odpowiedz dokładnie jednym słowem: gotowy",
                           timeout: 90) { _ in }
        guard !stopped else { session.terminate(); return }
        session.used = false
        spare = session
        trace("replenish: rozgrzana")
    }

    private func spawnSession() throws -> Session {
        guard let cli = Self.locateCLI() else { throw BridgeError.cliMissing }

        var args = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--no-session-persistence",
            "--permission-mode", "dontAsk",
            "--disallowed-tools", Self.disabledTools,
            "--append-system-prompt", Self.systemPrompt,
        ]
        if let model, !model.isEmpty { args += ["--model", model] }

        let task = Process()
        task.executableURL = cli
        task.arguments = args
        // Katalog neutralny celowo: start w katalogu projektu wciągnąłby jego
        // CLAUDE.md i kontekst repo do odpowiedzi na pytania z rozmowy.
        task.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        task.standardInput = stdin
        task.standardOutput = stdout
        task.standardError = stderr

        let session = Session(process: task, stdin: stdin)
        let id = ObjectIdentifier(session)

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let chunk = String(data: data, encoding: .utf8) else { return }
            Task { await self?.consume(chunk, sessionID: id) }
        }
        // stderr też trzeba czytać — potok, którego nikt nie opróżnia, blokuje
        // proces potomny po zapełnieniu 64 kB bufora.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            _ = handle.availableData
        }
        task.terminationHandler = { [weak self] finished in
            Task { await self?.handleExit(id, status: finished.terminationStatus) }
        }

        try task.run()
        sessions[id] = session
        return session
    }

    private func handleExit(_ id: ObjectIdentifier, status: Int32) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        if let job = session.current {
            session.current = nil
            finish(job, .failure(BridgeError.processDied(status)))
        }
        if spare === session { spare = nil }
        if active === session { active = nil }
        if !stopped { Task { await self.replenish() } }
    }

    // MARK: - protokół

    private func consume(_ chunk: String, sessionID: ObjectIdentifier) {
        guard let session = sessions[sessionID] else { return }
        session.buffer += chunk
        while let newline = session.buffer.firstIndex(of: "\n") {
            let line = String(session.buffer[session.buffer.startIndex..<newline])
                .trimmingCharacters(in: .whitespaces)
            session.buffer = String(session.buffer[session.buffer.index(after: newline)...])
            guard !line.isEmpty, let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            route(message, session: session)
        }
    }

    private func route(_ message: [String: Any], session: Session) {
        if message["type"] as? String == "system", message["subtype"] as? String == "init" {
            trace("init")
            session.isReady = true
            reportedModel = message["model"] as? String
            return
        }

        guard let job = session.current else { return }

        // Strumień tokenów: kształt zdarzenia różni się między wersjami CLI.
        let delta = ((message["event"] as? [String: Any])?["delta"] as? [String: Any])?["text"] as? String
            ?? (message["delta"] as? [String: Any])?["text"] as? String
        if let delta, !delta.isEmpty {
            job.text += delta
            job.onDelta(delta)
            return
        }

        if message["type"] as? String == "result" {
            trace("result")
            let failed = message["is_error"] as? Bool == true
            let text = job.text.isEmpty ? (message["result"] as? String ?? "") : job.text
            session.current = nil
            finish(job, failed
                   ? .failure(BridgeError.failed(text))
                   : .success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    private func finish(_ job: Job, _ result: Result<String, Error>) {
        guard !job.finished else { return }
        job.finished = true
        job.continuation.resume(with: result)
    }

    // MARK: - pytania

    /// Zadaje pytanie w świeżej sesji i strumieniuje odpowiedź przez `onDelta`.
    ///
    /// Sesja jest po odpowiedzi wyrzucana, a w tle rusza rozgrzewanie nowej —
    /// dzięki temu każde pytanie startuje z pustą historią, a i tak nie płaci
    /// za zimny start.
    public func ask(_ prompt: String, image: AssistantImage? = nil, timeout: TimeInterval = 60,
                    onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        guard !stopped else { throw CancellationError() }

        // Sesja zużyta — wymieniamy ją na rozgrzaną zapasową.
        if let session = active, session.uses >= Self.maxUses || session.process.isRunning == false {
            trace("wymieniam sesję po \(session.uses) pytaniach")
            retire(session)
        }

        let session: Session
        if let existing = active {
            session = existing
        } else if let warm = spare {
            spare = nil
            session = warm
            active = warm
        } else {
            trace("brak rozgrzanej — zimny start")
            session = try spawnSession()
            active = session
        }

        defer {
            session.uses += 1
            // Zapasową rozgrzewamy dopiero po oddaniu odpowiedzi. Robione
            // równolegle z pytaniem, konkurowało z nim o procesor i podnosiło
            // czas pierwszego tokenu z ~1,7 s do ~4,5 s.
            if !stopped { Task { await self.replenish() } }
        }
        return try await run(on: session, prompt: prompt, image: image,
                             timeout: timeout, onDelta: onDelta)
    }

    private func retire(_ session: Session) {
        if active === session { active = nil }
        session.terminate()
        sessions.removeValue(forKey: ObjectIdentifier(session))
    }

    private func run(on session: Session, prompt: String, image: AssistantImage? = nil,
                     timeout: TimeInterval,
                     onDelta: @escaping @Sendable (String) -> Void) async throws -> String {
        // Przez granicę zadania przekazujemy identyfikator, nie obiekt sesji:
        // `Session` jest izolowana aktorem i nie jest `Sendable`.
        let sessionID = ObjectIdentifier(session)
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            await self?.timeOut(sessionID, seconds: Int(timeout))
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { continuation in
            let job = Job(prompt: prompt, image: image, onDelta: onDelta, continuation: continuation)
            session.current = job
            session.used = true

            // Obraz idzie PRZED tekstem — Anthropic zaleca taką kolejność,
            // bo model widzi wtedy, do czego odnosi się pytanie.
            var content: [[String: Any]] = []
            if let image {
                content.append([
                    "type": "image",
                    "source": ["type": "base64", "media_type": image.mediaType, "data": image.base64],
                ])
            }
            content.append(["type": "text", "text": prompt])

            let payload: [String: Any] = [
                "type": "user",
                "message": ["role": "user", "content": content],
            ]
            guard var line = try? JSONSerialization.data(withJSONObject: payload) else {
                session.current = nil
                finish(job, .failure(BridgeError.failed("Nie mogę zserializować pytania.")))
                return
            }
            line.append(0x0A)
            do {
                try session.stdin.fileHandleForWriting.write(contentsOf: line)
            } catch {
                session.current = nil
                finish(job, .failure(BridgeError.failed(error.localizedDescription)))
            }
        }
    }

    private func timeOut(_ id: ObjectIdentifier, seconds: Int) {
        guard let session = sessions[id], let job = session.current else { return }
        session.current = nil
        finish(job, .failure(BridgeError.timeout(seconds)))
        // Sesji i tak nie użyjemy ponownie — CLI dośle `result` dla porzuconego
        // promptu i rozjechałby strumień następnego pytania.
        session.terminate()
        sessions.removeValue(forKey: id)
        if spare === session { spare = nil }
        if active === session { active = nil }
        if !stopped { Task { await self.replenish() } }
    }

    /// Rozgrzewka: podnosi i rozgrzewa pierwszą sesję, zanim padnie pytanie.
    ///
    /// Czeka na zakończenie — wołający ma wiedzieć, kiedy most jest gotowy.
    @discardableResult
    public func warmup() async -> Bool {
        await replenish()
        return spare != nil || active != nil
    }
}
