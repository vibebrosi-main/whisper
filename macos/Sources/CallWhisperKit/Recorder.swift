import Foundation
import CallWhisperCore

/// Spina wszystko w całość: dźwięk -> diaryzacja + ASR -> transkrypt ->
/// wykrywanie pytań -> model podpowiadający.
///
/// Jedyny obiekt na głównym aktorze; DSP siedzi w `SourcePipeline`.
@MainActor
public final class Recorder: ObservableObject {
    @Published public private(set) var segments: [Segment] = []
    @Published public private(set) var answers: [AssistantItem] = []
    @Published public private(set) var isRunning = false
    @Published public private(set) var status = "Gotowy"
    @Published public private(set) var lastError: String?
    @Published public private(set) var speakerCount = 0
    @Published public private(set) var startedAt: Double?
    /// Praca po rozmowie albo import — przycisk „Słuchaj" ma wtedy czekać.
    @Published public private(set) var isProcessing = false
    /// Metadane sesji z importu; `nil` = rozmowa nagrana na żywo.
    @Published public private(set) var importedMeta: SessionMeta?

    private var store = TranscriptStore()
    private var watcher: QuestionWatcher?
    private let assistant = AssistantClient()
    private let bridge = ClaudeBridge()
    private var bridgeStarted = false
    private let session = AssistantSession()
    private let settings: AppSettings

    private var pipelines: [AudioSource: SourcePipeline] = [:]
    private var systemCapture: SystemAudioCapture?
    private var micCapture: MicrophoneCapture?
    private var ticker: Task<Void, Never>?
    private let whisperServer = WhisperServer()
    private let downloader = ModelDownloader()
    /// Dźwięk systemu tej sesji na dysku — dla diaryzacji po rozmowie.
    private var sessionAudio: WavFileWriter?
    private var processingTask: Task<Void, Never>?

    /// OBS nagrywający wideo do tej samej rozmowy; `nil` = bez OBS.
    public var obs: OBSLink?
    /// Sesja związana z nagraniem w OBS - przy stopie kończymy i jego.
    private var obsSession = false
    public var isOBSSession: Bool { obsSession }

    /// Co jeszcze trzeba załatwić, zanim cokolwiek zadziała.
    @Published public private(set) var readiness = Readiness(checks: [])

    public func refreshReadiness() {
        readiness = Readiness.check(model: settings.whisperModel, backend: settings.assistantBackend,
                                    diarize: settings.diarizeAfter)
    }
    private var askTasks: [String: Task<Void, Never>] = [:]

    public init(settings: AppSettings = .shared) {
        self.settings = settings
    }

    // MARK: - cykl życia

    /// `origin` (ms epoki) to chwila, od której liczą się znaczniki czasu -
    /// np. start nagrania w OBS, żeby 00:01:05 w transkrypcie znaczyło
    /// 00:01:05 w filmie. Przygotowanie whispera trwa sekundy, a dźwięk z tego
    /// okna przepada, ale czas pierwszej próbki i tak liczy się od `origin`.
    public func start(origin: Double? = nil) async {
        guard !isRunning, !isProcessing else { return }
        var origin = origin
        lastError = nil
        importedMeta = nil
        let backend = settings.asrBackend

        // Przygotowanie silnika ASR. Obie ścieżki mogą odmówić z powodów,
        // których nie da się obejść w locie, więc rozstrzygamy je przed
        // dotknięciem mikrofonu.
        switch backend {
        case .whisperLocal:
            guard await prepareWhisper() else { return }
        case .appleSpeech:
            guard await prepareAppleSpeech() else { return }
        }

        // Nagranie w OBS włączamy dopiero po przygotowaniu silnika, żeby film
        // i transkrypt zaczynały się możliwie razem. `origin` podany z zewnątrz
        // znaczy, że OBS już nagrywa (start ręcznie w OBS).
        obsSession = origin != nil
        var obsNote: String?
        if origin == nil, settings.followOBS, let obs {
            status = "Włączam nagrywanie w OBS…"
            do {
                origin = try await obs.startRecording()
                obsSession = true
            } catch {
                obsNote = error.localizedDescription
            }
        }

        let now = origin ?? nowMs()
        store = TranscriptStore(startedAt: now)
        startedAt = now
        segments = []
        answers = []
        watcher = QuestionWatcher(minConfidence: settings.minConfidence) { [weak self] found in
            Task { @MainActor in self?.handleDetected(found) }
        }

        var sources: [AudioSource] = [.system]
        if settings.useMicrophone, await MicrophoneCapture.requestAccess() {
            sources.append(.microphone)
        }

        do {
            for source in sources {
                let pipeline = SourcePipeline(source: source, backend: backend,
                                              whisperPort: settings.whisperPort,
                                              languageCode: settings.languageCode,
                                              identifySpeakers: settings.identifySpeakers)
                pipelines[source] = pipeline
                try await pipeline.start(locale: settings.locale, onUpdate: { [weak self] update in
                    Task { @MainActor in self?.apply(update) }
                }, onError: { [weak self] (error: any Error) in
                    // Ten sam błąd potrafi się powtórzyć przy każdej rundzie
                    // transkrypcji — w interfejsie ma być raz.
                    Task { @MainActor in
                        let message = error.localizedDescription
                        if self?.lastError != message { self?.lastError = message }
                    }
                })
            }

            if let pipeline = pipelines[.system] {
                let capture = SystemAudioCapture()
                systemCapture = capture
                // Zapis na dysk tylko wtedy, gdy będzie z czego korzystać.
                let tape = settings.diarizeAfter ? try? WavFileWriter(url: Self.sessionAudioURL(now)) : nil
                sessionAudio = tape
                try await capture.start(sessionStartMs: now, onChunk: { chunk in
                    pipeline.submit(chunk)
                    tape?.append(chunk.samples, startMs: chunk.startMs)
                }, onStop: { [weak self] error in
                    Task { @MainActor in
                        if let error { self?.lastError = "Przechwytywanie przerwane: \(error.localizedDescription)" }
                        await self?.stop()
                    }
                })
            }

            if let pipeline = pipelines[.microphone] {
                let capture = MicrophoneCapture()
                micCapture = capture
                try capture.start(sessionStartMs: now, onChunk: { chunk in
                    pipeline.submit(chunk)
                })
            }
        } catch {
            lastError = error.localizedDescription
            await stop()
            return
        }

        isRunning = true
        // Język w statusie celowo: cicha rozbieżność między zapisanym językiem
        // a tym, czego oczekuje użytkownik, kosztowała już jedną sesję debugowania
        // (whisper dostawał `language=en` i tłumaczył polski na angielski).
        let engine = backend == .whisperLocal
            ? "whisper \(settings.whisperModel) · \(settings.languageCode)"
            : "Apple · \(settings.languageCode)"
        status = sources.count > 1
            ? "Słucham: system + mikrofon · \(engine)"
            : "Słucham: system · \(engine)"
        if obsSession { status += " · OBS nagrywa" }
        if let obsNote { lastError = obsNote }
        startTicker()
    }

    /// Podnosi `whisper-server`, jeśli trzeba. Zwraca `false`, gdy się nie da.
    private func prepareWhisper() async -> Bool {
        // Silnik tak samo jak model: brakujący pobieramy sami. 1,3 MB, więc
        // to sekunda — a wcześniej był to `brew install` i lektura README.
        if WhisperServer.locateBinary() == nil {
            status = "Pobieram silnik mowy…"
            do {
                try await Engines.install(.whisperServer) { [weak self] fraction in
                    Task { @MainActor in self?.status = "Pobieram silnik mowy — \(Int(fraction * 100))%" }
                }
            } catch {
                lastError = "Nie udało się pobrać silnika mowy: \(error.localizedDescription)"
                status = "Gotowy"
                return false
            }
            refreshReadiness()
        }

        // Model pobieramy sami, zamiast kazać użytkownikowi szukać w README
        // polecenia `curl` na 465 MB.
        if !ModelDownloader.isInstalled(settings.whisperModel) {
            let model = settings.whisperModel
            status = "Pobieram model \(model)…"
            do {
                try await downloader.download(model) { [weak self] progress in
                    Task { @MainActor in
                        let mb = Double(progress.receivedBytes) / 1e6
                        let total = Double(progress.totalBytes) / 1e6
                        self?.status = String(format: "Pobieram model %@ — %.0f%% (%.0f/%.0f MB)",
                                              model, progress.fraction * 100, mb, total)
                    }
                }
            } catch {
                lastError = "Nie udało się pobrać modelu: \(error.localizedDescription)"
                status = "Gotowy"
                return false
            }
        }

        let client = WhisperClient(endpoint: URL(string: "http://127.0.0.1:\(settings.whisperPort)")!,
                                   language: settings.languageCode)
        if await client.health() {
            status = "whisper-server działa"
            return true
        }

        guard settings.autoStartWhisper else {
            lastError = "whisper-server nie działa. Uruchom go w Ustawieniach albo `npm run whisper`."
            return false
        }

        status = "Uruchamiam whisper-server (\(settings.whisperModel))…"
        do {
            try await whisperServer.ensureRunning(.init(
                model: settings.whisperModel,
                port: settings.whisperPort,
                language: settings.languageCode
            ))
            return true
        } catch {
            lastError = error.localizedDescription
            status = "Gotowy"
            return false
        }
    }

    /// Sprawdza język i pobiera model mowy Apple.
    private func prepareAppleSpeech() async -> Bool {
        status = "Sprawdzam model mowy…"
        switch await SpeechRecognizer.modelStatus(locale: settings.locale) {
        case .unsupported:
            // Najczęstszy przypadek: polski. `SpeechTranscriber` go nie zna.
            lastError = "Rozpoznawanie Apple nie obsługuje języka \(settings.language). Przełącz silnik na whisper.cpp w Ustawieniach."
            status = "Gotowy"
            return false
        case .supported, .downloading:
            status = "Pobieram model mowy…"
            do {
                try await SpeechRecognizer.installModel(locale: settings.locale) { [weak self] fraction in
                    Task { @MainActor in
                        self?.status = "Pobieram model mowy… \(Int(fraction * 100))%"
                    }
                }
                return true
            } catch {
                lastError = "Nie udało się pobrać modelu mowy: \(error.localizedDescription)"
                status = "Gotowy"
                return false
            }
        case .installed:
            return true
        }
    }

    /// `recordingPath` podaje OBS, gdy to on zakończył nagranie - wtedy nie
    /// prosimy go o stop drugi raz.
    public func stop(recordingPath: String? = nil) async {
        guard isRunning || !pipelines.isEmpty else { return }

        // Kolejność jest celowa: najpierw gasimy stan widoczny w interfejsie,
        // dopiero potem sprzątamy. Wcześniej przycisk zostawał w „Zatrzymaj"
        // przez cały czas domykania — a to potrafiło potrwać, bo `flush`
        // dokańczał zaległe audio i wysyłał ostatnie żądanie do whispera.
        isRunning = false
        status = "Zatrzymuję…"

        ticker?.cancel()
        ticker = nil
        await systemCapture?.stop()
        systemCapture = nil
        micCapture?.stop()
        micCapture = nil

        for pipeline in pipelines.values { await pipeline.cancel() }
        pipelines.removeAll()

        // Pytania w locie też przerywamy — odpowiedź na rozmowę, która się
        // skończyła, nie jest już nikomu potrzebna.
        for task in askTasks.values { task.cancel() }
        askTasks.removeAll()
        pendingAuto = nil

        // Zatrzymujemy tylko serwer, który sami podnieśliśmy.
        await whisperServer.stop()
        if bridgeStarted {
            await bridge.stop()
            bridgeStarted = false
        }

        store.finalizeAll()
        publish()
        status = store.isEmpty ? "Gotowy" : "Zatrzymane"

        var videoPath = recordingPath
        if obsSession {
            obsSession = false
            if recordingPath == nil, let obs {
                status = "Kończę nagranie w OBS…"
                videoPath = await obs.stopRecording()
                status = store.isEmpty ? "Gotowy" : "Zatrzymane"
            }
        }

        if let tape = sessionAudio {
            sessionAudio = nil
            tape.finish()
            if store.isEmpty {
                try? FileManager.default.removeItem(at: tape.url)
            } else {
                diarizeSession(tape.url)
            }
        }

        if let videoPath, !store.isEmpty {
            Task { [weak self] in
                await self?.waitForProcessing()
                self?.saveTranscript(nextTo: videoPath)
            }
        }
    }

    /// Transkrypt obok pliku wideo z OBS, z tą samą nazwą i czasami
    /// względnymi - tylko te pokrywają się z osią filmu.
    private func saveTranscript(nextTo videoPath: String) {
        let url = OBS.transcriptURL(forRecording: videoPath)
        do {
            try renderMarkdown(absoluteTimestamps: false).write(to: url, atomically: true, encoding: .utf8)
            status = "Zapisano obok nagrania: \(url.lastPathComponent)"
        } catch {
            lastError = "Nie udało się zapisać transkryptu obok nagrania: \(error.localizedDescription)"
        }
    }

    // MARK: - po rozmowie

    static func sessionAudioURL(_ startedAt: Double) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("call-whisper-\(TimeFormat.filenameStamp(startedAt)).wav")
    }

    /// Diaryzacja neuronowa nagranej rozmowy.
    ///
    /// Na żywo zostają pewne etykiety „Ty" / „Rozmówcy"; dopiero po rozmowie,
    /// gdy klastrowanie widzi całe nagranie naraz, „Rozmówcy" rozpadają się na
    /// „Rozmówca 1", „Rozmówca 2"… Plik audio kasujemy zaraz potem.
    private func diarizeSession(_ wav: URL) {
        isProcessing = true
        processingTask = Task { [weak self] in
            defer { try? FileManager.default.removeItem(at: wav) }
            guard let self else { return }
            do {
                try await NeuralDiarizer.ensureInstalled { message in
                    Task { @MainActor in self.status = message }
                }
                self.status = "Rozpoznaję głosy…"
                let turns = try await NeuralDiarizer.run(wav: wav)
                let relabeled = SpeakerTurns.relabel(self.segments, turns: turns,
                                                     where: SpeakerTurns.isSystemLabel, prefix: "Rozmówca")
                let voices = Set(relabeled.map(\.speaker).filter { $0.hasPrefix("Rozmówca ") }).count
                self.segments = relabeled
                self.speakerCount = voices
                self.status = voices > 1 ? "Zatrzymane · rozpoznano \(voices) głosy rozmówców"
                                         : "Zatrzymane · jeden głos po drugiej stronie"
            } catch is CancellationError {
                self.status = "Zatrzymane"
            } catch {
                self.lastError = error.localizedDescription
                self.status = "Zatrzymane"
            }
            self.isProcessing = false
            self.refreshReadiness()
        }
    }

    /// Instalacja silnika z panelu gotowości, zanim będzie potrzebny.
    public func install(_ component: Engines.Component) async {
        let parts: [Engines.Component] = component == .diarizer ? [.diarizer, .diarizationModels] : [component]
        isProcessing = true
        defer { isProcessing = false; refreshReadiness() }
        for part in parts where !Engines.isInstalled(part) {
            do {
                try await Engines.install(part) { [weak self] fraction in
                    Task { @MainActor in self?.status = "Pobieram: \(part.label.lowercased()) — \(Int(fraction * 100))%" }
                }
            } catch {
                lastError = error.localizedDescription
                status = "Gotowy"
                return
            }
        }
        status = "Gotowy"
    }

    /// Import nagrania albo wideo (pomysł z whistlera). Wynik ląduje w tym
    /// samym transkrypcie co rozmowa na żywo, więc eksport, kopiowanie
    /// i pytania do asystenta działają bez zmian.
    public func importFile(_ url: URL, speakers: Int? = nil) {
        guard !isRunning, !isProcessing else { return }
        isProcessing = true
        lastError = nil
        processingTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isProcessing = false }
            guard await self.prepareWhisper() else { return }
            let options = MediaImport.Options(whisperPort: self.settings.whisperPort,
                                              language: self.settings.languageCode,
                                              diarize: self.settings.diarizeAfter, speakers: speakers)
            do {
                let result = try await MediaImport.run(url, options: options) { message in
                    Task { @MainActor in self.status = message }
                }
                self.store = TranscriptStore(startedAt: result.meta.startedAt ?? nowMs())
                self.answers = []
                self.segments = result.segments
                self.startedAt = result.meta.startedAt
                self.importedMeta = result.meta
                self.speakerCount = result.speakerCount
                self.lastError = result.diarizationNote.map { "Bez podziału na głosy: \($0)" }
                self.status = result.segments.isEmpty
                    ? "W \(url.lastPathComponent) nie rozpoznano mowy"
                    : "Zaimportowano \(url.lastPathComponent) · \(result.segments.count) wypowiedzi"
            } catch is CancellationError {
                self.status = "Import przerwany"
            } catch {
                self.lastError = error.localizedDescription
                self.status = "Gotowy"
            }
            await self.whisperServer.stop()
        }
    }

    /// Czeka, aż skończy się praca po rozmowie (diaryzacja), żeby zapisany
    /// plik miał już ostateczne etykiety mówców.
    public func waitForProcessing() async {
        await processingTask?.value
    }

    public func cancelProcessing() {
        processingTask?.cancel()
    }

    /// Co 250 ms domykamy wypowiedzi po ciszy i szukamy w nich pytań.
    private func startTicker() {
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                await MainActor.run {
                    // `finalizeIdle` domyka segmenty, w których tekst przestał
                    // się zmieniać. To ma sens dla źródeł napisowych, gdzie
                    // o ciszy dowiadujemy się wyłącznie po tym, że tekst stoi.
                    //
                    // Przy whisperze to jest wręcz szkodliwe: granice wypowiedzi
                    // wyznacza VAD, a każda runda przyrostowa dotyczy tej samej
                    // wypowiedzi i niesie ten sam znacznik czasu jej początku.
                    // `updatedAt` więc nie rośnie, segment jest uznawany za
                    // martwy po 2,5 s i wszystkie kolejne — dłuższe i lepsze —
                    // wersje tekstu lądują w koszu. Turę i tak domykamy jawnie.
                    if self.settings.asrBackend != .whisperLocal {
                        self.store.finalizeIdle()
                    }
                    self.publish()
                    if self.settings.assistantEnabled && self.settings.autoAsk {
                        self.watcher?.scan(self.store.segments)
                    }
                }
            }
        }
    }

    /// Podgląd surowych aktualizacji: `CW_DEBUG=1`. Diagnozowanie „czemu tekst
    /// jest ucięty" bez tego sprowadza się do zgadywania, czy gubi je łańcuch,
    /// czy `TranscriptStore`.
    private static let debug = ProcessInfo.processInfo.environment["CW_DEBUG"] == "1"

    private func apply(_ update: SourcePipeline.Update) {
        if Self.debug {
            let mark = update.discard ? "DISCARD" : (update.isFinal ? "FINAL" : "part")
            FileHandle.standardError.write(Data(
                "[cw] \(mark) key=\(update.key) t=\(Int(update.startMs)) \"\(update.text)\"\n".utf8))
        }
        if update.discard {
            // Wypowiedź bez rozpoznanego tekstu — usuwamy segment zamiast
            // zostawiać pusty wiersz z samą etykietą mówcy.
            store.discard(update.key)
            store.seal(update.key)
            publish()
            return
        }

        // Cokolwiek dojechało, znaczy że łańcuch działa — poprzedni błąd
        // przestaje być prawdą i nie ma czego straszyć nim w interfejsie.
        lastError = nil

        // `replace: true`, bo oba silniki podają pełną, poprawioną treść
        // fragmentu przy każdej aktualizacji — nie dopisują ogona.
        store.upsert(key: update.key, speaker: update.speaker, text: update.text,
                     at: (startedAt ?? nowMs()) + update.startMs, replace: true)
        if update.isFinal {
            // Pieczętujemy klucz: ten sam wynik potrafi przyjść ponownie,
            // a bez tego powstałby drugi segment z całą wypowiedzią.
            store.seal(update.key)
        }
        publish()
    }

    private func publish() {
        segments = store.segments
        answers = session.all
        // Liczba mówców mieszka w aktorach diaryzatorów, więc odpytujemy je
        // asynchronicznie; `Task` dziedziczy główny aktor, stąd brak `await`
        // przy samym słowniku.
        let running = pipelines.values.map { $0 }
        Task { [weak self] in
            var total = 0
            for pipeline in running { total += await pipeline.speakerCount }
            self?.speakerCount = total
        }
    }

    // MARK: - asystent

    /// Pytanie wykryte automatycznie w transkrypcji.
    ///
    /// Kolejka jest celowo płytka. Przy monologu albo filmie wykrywacz trafia
    /// co kilka sekund, a jedna odpowiedź przez most zajmuje 1,5-5 s — bez
    /// tego bufor rósł, odpowiedzi przychodziły do pytań sprzed pół minuty,
    /// a interfejs wyglądał na zawieszony.
    private func handleDetected(_ found: QuestionWatcher.Found) {
        guard askTasks.isEmpty else {
            // Jedno pytanie na raz. Nowsze wygrywa: odpowiedź na to, co padło
            // przed chwilą, jest warta więcej niż na to sprzed kilkunastu sekund.
            pendingAuto = found
            return
        }
        ask(found.question, speaker: found.speaker, auto: true)
    }

    /// Najświeższe pytanie czekające, aż zwolni się miejsce.
    private var pendingAuto: QuestionWatcher.Found?

    /// Po tylu ms pytanie przestaje być warte odpowiedzi.
    private static let autoQuestionTTL: Double = 20_000

    private func startPendingIfAny() {
        guard askTasks.isEmpty, let pending = pendingAuto else { return }
        pendingAuto = nil
        guard nowMs() - pending.at < Self.autoQuestionTTL else { return }
        ask(pending.question, speaker: pending.speaker, auto: true)
    }

    /// Pytanie zadane ręcznie w nakładce — omija wykrywanie i ustawienie
    /// „pytaj automatycznie", ale dostaje ten sam kontekst z transkryptu.
    public func ask(_ question: String, speaker: String? = nil, auto: Bool = false,
                    image: AssistantImage? = nil) {
        guard settings.assistantEnabled else { return }
        // Z obrazkiem samo pytanie może być puste — „co tu jest nie tak?"
        // bywa całą treścią, a reszta jest na zrzucie.
        let asked = question.isEmpty && image != nil ? "Co widzisz na tym obrazku?" : question
        guard let prompt = buildPrompt(question: asked, segments: store.segments,
                                       title: settings.title,
                                       projectContext: settings.projectContext) else { return }

        let backend = settings.assistantBackend
        let key = settings.apiKey
        if backend == .api && key.isEmpty {
            lastError = AssistantError.noKey.localizedDescription
            return
        }

        let item = session.add(question: asked, speaker: speaker, auto: auto, hasImage: image != nil)
        answers = session.all
        let started = Date()

        askTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            do {
                switch backend {
                case .claudeCode:
                    try await self.askViaBridge(prompt: prompt, image: image,
                                                itemID: item.id, started: started)
                case .api:
                    try await self.askViaAPI(prompt: prompt, image: image,
                                             itemID: item.id, apiKey: key)
                }
                await MainActor.run {
                    self.session.complete(item.id, durationMs: Date().timeIntervalSince(started) * 1000)
                    self.answers = self.session.all
                }
            } catch {
                if !(error is CancellationError) {
                    await MainActor.run {
                        self.session.fail(item.id, error: error.localizedDescription)
                        self.answers = self.session.all
                    }
                }
            }
            await MainActor.run {
                self.askTasks[item.id] = nil
                self.startPendingIfAny()
            }
        }
    }

    private func askViaAPI(prompt: String, image: AssistantImage?, itemID: String, apiKey: String) async throws {
        for try await chunk in await assistant.stream(prompt: prompt, apiKey: apiKey,
                                                      model: settings.modelID, image: image) {
            await MainActor.run {
                self.session.append(itemID, delta: chunk.delta, ttftMs: chunk.ttftMs)
                self.answers = self.session.all
            }
        }
    }

    private func askViaBridge(prompt: String, image: AssistantImage?,
                              itemID: String, started: Date) async throws {
        // Ze zrzutem ekranu model potrzebuje więcej czasu niż na sam tekst.
        _ = try await bridge.ask(prompt, image: image, timeout: image == nil ? 60 : 120) { delta in
            Task { @MainActor in
                let ttft = Date().timeIntervalSince(started) * 1000
                self.session.append(itemID, delta: delta, ttftMs: ttft)
                self.answers = self.session.all
            }
        }
    }

    /// Podnosi most i rozgrzewa go, zanim padnie pierwsze pytanie.
    ///
    /// Zimny start CLI to ~3,9 s do pierwszego tokenu, ciepły ~1,8 s. Ten koszt
    /// ma być zapłacony w tle przy starcie nasłuchu, a nie w środku rozmowy.
    private func prepareAssistant() async {
        guard settings.assistantEnabled, settings.assistantBackend == .claudeCode else { return }
        guard !bridgeStarted else { return }
        do {
            try await bridge.start(model: settings.claudeModel)
            bridgeStarted = true
            // Rozgrzewka leci w tle — nasłuch nie ma na nią czekać — ale to
            // jest jedyne miejsce, które ją uruchamia.
            Task { [bridge] in await bridge.warmup() }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - eksport

    public var markdown: String { renderMarkdown() }

    /// `absoluteTimestamps` nadpisuje ustawienie - plik obok nagrania OBS
    /// zawsze ma czasy względne, bo tylko te pokrywają się z osią filmu.
    public func renderMarkdown(absoluteTimestamps: Bool? = nil) -> String {
        var opts = MarkdownOptions()
        opts.locale = settings.markdownLocale
        opts.absoluteTimestamps = absoluteTimestamps ?? settings.absoluteTimestamps
        let meta = importedMeta ?? SessionMeta(
            title: settings.title,
            source: pipelines.count > 1 || micCapture != nil ? "mixed" : "system-audio",
            startedAt: startedAt,
            endedAt: segments.last?.endedAt
        )
        return Markdown.render(Session(meta: meta, segments: segments), options: opts)
    }

    /// Notatka do wklejenia w Claude: podsumowanie z kluczowymi punktami
    /// i znacznikami czasu, a pod nim pełny transkrypt. Pomysł z whistlera
    /// (`export_note_for_claude`); podsumowanie robi ten sam model, który
    /// podpowiada w rozmowie — most do Claude Code albo API.
    public func claudeNote() async throws -> String {
        let transcript = markdown
        // Ograniczamy wejście jak whistler: dwugodzinny transkrypt potrafi
        // przekroczyć kontekst, a do podsumowania wystarczy środek ciężkości.
        let body = Markdown.render(Session(meta: SessionMeta(), segments: segments),
                                   options: MarkdownOptions(frontmatter: false, stats: false))
        let prompt = """
        Poniżej jest transkrypt rozmowy z oznaczeniem osób i znacznikami czasu [HH:MM:SS].
        Napisz zwięzłe podsumowanie w Markdownie: 2-4 zdania ogólnie, potem krótka lista
        najważniejszych punktów, decyzji i zadań, każdy ze znacznikiem [HH:MM:SS].
        Odpowiedz w języku transkryptu. Wypisz tylko podsumowanie, bez wstępu.

        \(String(body.prefix(12_000)))
        """

        let summary: String
        switch settings.assistantBackend {
        case .claudeCode:
            if !bridgeStarted {
                try await bridge.start(model: settings.claudeModel)
                bridgeStarted = true
            }
            summary = try await bridge.ask(prompt, image: nil, timeout: 180) { _ in }
        case .api:
            let key = settings.apiKey
            guard !key.isEmpty else { throw AssistantError.noKey }
            var text = ""
            for try await chunk in await assistant.stream(prompt: prompt, apiKey: key,
                                                          model: settings.modelID, image: nil) {
                text += chunk.delta
            }
            summary = text
        }

        // Podsumowanie wstawiamy pod nagłówkiem dokumentu, przed tabelą osób.
        let heading = "## Podsumowanie\n\n\(summary.trimmingCharacters(in: .whitespacesAndNewlines))\n\n"
        if let range = transcript.range(of: "\n## ") {
            var out = transcript
            out.insert(contentsOf: "\n" + heading.dropLast(), at: range.lowerBound)
            return out
        }
        return heading + transcript
    }

    public var json: Data? {
        let payload: [String: Any] = [
            "startedAt": startedAt ?? nowMs(),
            "segments": segments.map { [
                "id": $0.id, "speaker": $0.speaker, "text": $0.text,
                "startedAt": $0.startedAt, "endedAt": $0.endedAt,
                "offsetMs": $0.offsetMs, "final": $0.final,
            ] },
        ]
        return try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }
}
