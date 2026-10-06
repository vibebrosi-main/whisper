import Foundation
import CallWhisperCore

/// Który silnik zamienia dźwięk na tekst.
public enum ASRBackend: String, Sendable, CaseIterable {
    /// whisper.cpp przez lokalny `whisper-server`. Jedyna opcja dla polskiego.
    case whisperLocal
    /// `SpeechAnalyzer` z macOS 26. Szybszy i bez serwera, ale 30 języków
    /// i **żadnego polskiego**.
    case appleSpeech

    public var label: String {
        switch self {
        case .whisperLocal: return "whisper.cpp (lokalnie)"
        case .appleSpeech:  return "Rozpoznawanie Apple (bez polskiego)"
        }
    }
}

/// Łańcuch przetwarzania jednego źródła dźwięku.
///
/// Aktor, a nie klasa na głównym wątku: ramki lecą co 10 ms, a MFCC i FFT nie
/// mają czego szukać w wątku rysującym interfejs. Na zewnątrz wychodzą dopiero
/// gotowe fragmenty transkryptu.
public actor SourcePipeline {
    public struct Update: Sendable {
        public var source: AudioSource
        /// Klucz segmentu w `TranscriptStore` — stały przez całą wypowiedź.
        public var key: String
        public var speaker: String
        public var text: String
        public var isFinal: Bool
        public var startMs: Double
        /// Wypowiedź nie dała żadnego tekstu — segment ma zniknąć, a nie zostać pusty.
        public var discard: Bool = false
    }

    public let source: AudioSource
    public let backend: ASRBackend
    private let framer: Framer
    private let diarizer: Diarizer
    private let ring: AudioRing
    private let hopSize: Int

    // --- ścieżka Apple ---
    private let recognizer = SpeechRecognizer()

    // --- ścieżka whisper ---
    private let whisper: WhisperClient

    /// Ostatnie zdania rozmowy, podawane whisperowi jako `initial_prompt`.
    ///
    /// Najtańsza poprawa jakości, jaka tu jest: zmierzone 23,3 % -> 13,3 % WER
    /// kosztem 33 ms. Dekoder dostaje słownictwo, które w tej rozmowie już
    /// padło, więc przestaje wymyślać nazwy własne od zera.
    private var context = ""
    private static let maxContextChars = 400
    /// Stałe słownictwo rozmowy (nazwy technologii, firm, osób) doklejane
    /// przed kontekst. Zmierzone 2026-10-05: `small` bez niego pisał
    /// „Reads Finex Js", z nim „React, Next.js" - jak `large-v3-turbo`,
    /// ale w 0,63 s zamiast 2,4 s.
    private let vocabulary: String
    private var whisperPrompt: String {
        vocabulary.isEmpty ? context : String((vocabulary + " " + context).prefix(Self.maxContextChars + Vocabulary.maxChars))
    }
    /// Co ile odświeżamy transkrypcję trwającej wypowiedzi.
    private let intervalMs: Double = 1200
    /// Zanim to minie, nie ma czego transkrybować.
    ///
    /// Podniesione z 700 ms: na krótkim urywku whisper chętnie zmyśla całe
    /// zdanie („o takie socjalne rzeczy zadziałał nazizm" na sekundzie ciszy),
    /// a zmyślony tekst wchodzi potem do kontekstu i ciągnie się przez resztę
    /// wypowiedzi.
    private let minAudioMs: Double = 1400
    /// Twardy limit jednej wypowiedzi.
    ///
    /// VAD domyka tury na ciszy, ale przy mowie ciągłej — nagranie z TTS,
    /// czytany tekst, ktoś mówiący bez oddechu — cisza nie nadchodzi i tura
    /// wisi otwarta. Efekt: jeden segment na półtorej minuty, w nim pytanie
    /// sklejone z odpowiedzią, prompt na setki znaków i odpowiedź po 9 s.
    /// Po tym czasie domykamy turę sami, żeby transkrypt miał czytelne akapity.
    private let maxUtteranceMs: Double = 25_000
    /// Margines przed początkiem tury: VAD ucina ciche początki głosek.
    private let padMs: Double = 200
    /// Krótsze tury odrzucamy bez pytania whispera. To zwykle kaszlnięcia
    /// i trzaski, a whisper chętnie dokleja do nich halucynacje — na ciszy
    /// potrafi wyprodukować całe zdanie, którego nikt nie powiedział.
    private let minTurnMs: Double = 600

    private struct Utterance {
        var key: String
        var startMs: Double
        var speaker: String?
        var lastText: String = ""
    }
    private var utterance: Utterance?
    private var ticker: Task<Void, Never>?
    private var inFlight: Task<Void, Never>?

    private var sequence = 0
    private var lastFrameMs: Double = 0

    /// Przelicznik: czas próbek -> czas sesji.
    ///
    /// Bufor kołowy i diaryzator MUSZĄ żyć w czasie próbek, bo bufor trzyma
    /// próbki ciągiem — przerwy w dostawie dźwięku po prostu w nim nie istnieją.
    /// `TranscriptStore` żyje natomiast w czasie sesji, bo tym zegarem mierzy
    /// ciszę. Trzymamy więc przesunięcie między nimi, odświeżane przy każdej
    /// paczce, i tłumaczymy dopiero na granicy.
    private var samplesIngested = 0
    private var clockOffsetMs: Double = 0

    /// Kiedy ostatnio przyszła jakakolwiek paczka dźwięku.
    ///
    /// ScreenCaptureKit **przestaje wysyłać bufory, gdy w systemie jest cisza**.
    /// VAD nie dostaje wtedy cichych ramek, więc nie domyka tury — a bez
    /// domknięcia nie ma wersji ostatecznej wypowiedzi. Wypowiedź kończyła się
    /// na ostatniej rundzie przyrostowej z modelu szybkiego i tak zostawała
    /// w notatce.
    private var lastChunkAt = Date()
    /// Po tylu ms bez dźwięku domykamy turę sami.
    private static let audioStallMs: Double = 800
    /// Ile jeszcze czekamy na przerwę po przekroczeniu limitu wypowiedzi.
    private static let cutGraceMs: Double = 8_000

    private func sessionMs(_ sampleMs: Double) -> Double { sampleMs + clockOffsetMs }
    private var onUpdate: (@Sendable (Update) -> Void)?
    private var onError: (@Sendable (Error) -> Void)?

    /// Kanał wejściowy audio.
    ///
    /// Próbki MUSZĄ trafiać do framera w kolejności nadejścia. Wołanie
    /// `Task { await ingest(…) }` prosto z callbacku przechwytywania tego nie
    /// gwarantuje — zadania startują w kolejności dowolnej, a przestawione
    /// bloki rozjeżdżają okno ramki i oś czasu diaryzatora względem ASR.
    private var inputContinuation: AsyncStream<PCMChunk>.Continuation?
    private var inputTask: Task<Void, Never>?

    public private(set) var lastLatencyMs: Double?

    public let identifySpeakers: Bool

    public init(source: AudioSource, backend: ASRBackend, whisperPort: Int = 8899,
                languageCode: String = "pl", identifySpeakers: Bool = false, vocabulary: String = "") {
        self.source = source
        self.vocabulary = String(Text.normalize(vocabulary).prefix(300))
        self.backend = backend
        self.identifySpeakers = identifySpeakers
        let extractor = MfccExtractor()
        self.hopSize = extractor.hopSize
        self.framer = Framer(frameSize: extractor.frameSize, hopSize: extractor.hopSize)
        self.diarizer = Diarizer(extractor: extractor, identifySpeakers: identifySpeakers)
        self.ring = AudioRing(sampleRate: asrSampleRate, seconds: 90, epochMs: 0)
        self.whisper = WhisperClient(
            endpoint: URL(string: "http://127.0.0.1:\(whisperPort)")!,
            language: languageCode
        )
    }

    public func start(locale: Locale,
                      onUpdate: @escaping @Sendable (Update) -> Void,
                      onError: @escaping @Sendable (Error) -> Void) async throws {
        self.onUpdate = onUpdate
        self.onError = onError

        switch backend {
        case .appleSpeech:
            try await recognizer.start(locale: locale, onTranscript: { [weak self] transcript in
                guard let self else { return }
                Task { await self.handleApple(transcript) }
            }, onError: { error in onError(error) })

        case .whisperLocal:
            diarizer.onTurnStart = { [weak self] startMs in
                guard let self else { return }
                Task { await self.openUtterance(at: startMs) }
            }
            diarizer.onTurn = { [weak self] turn in
                guard let self else { return }
                Task { await self.closeUtterance(turn) }
            }
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(1200))
                    await self?.tick()
                }
            }
        }

        let (stream, continuation) = AsyncStream<PCMChunk>.makeStream(bufferingPolicy: .unbounded)
        inputContinuation = continuation
        inputTask = Task { [weak self] in
            for await chunk in stream { await self?.process(chunk) }
        }
    }

    /// Wołane z wątku przechwytywania. Tylko kolejkuje — nic tu nie liczymy.
    public nonisolated func submit(_ chunk: PCMChunk) {
        Task { await self.enqueue(chunk) }
    }

    private func enqueue(_ chunk: PCMChunk) { inputContinuation?.yield(chunk) }

    private func process(_ chunk: PCMChunk) async {
        lastChunkAt = Date()
        clockOffsetMs = chunk.startMs - Double(samplesIngested) / asrSampleRate * 1000
        samplesIngested += chunk.samples.count

        for (frame, startSample) in framer.push(chunk.samples) {
            let tMs = Double(startSample) / asrSampleRate * 1000
            lastFrameMs = tMs
            // Do bufora trafia tylko nowa część ramki — ramki analizy nachodzą
            // na siebie o `frameSize - hopSize` próbek.
            ring.write(frame.suffix(hopSize))
            diarizer.pushFrame(frame, at: tMs)

            // Mowa ciągła bez pauz — VAD nie ma na czym domknąć tury.
            //
            // Po przekroczeniu limitu nie tniemy natychmiast: czekamy na
            // najbliższą cichą ramkę, czyli przerwę między zdaniami. Sztywne
            // cięcie co do sekundy rozrywało pytanie na pół („Jaka jest
            // różnica?" / „Między StateFlow a SharedFlow") i detektor dostawał
            // ogryzek zamiast pytania.
            if let open = utterance {
                let elapsed = tMs - open.startMs
                if elapsed >= maxUtteranceMs && !diarizer.lastFrameLoud {
                    trace("limit \(Int(maxUtteranceMs)) ms + przerwa — domykam")
                    diarizer.flush(at: tMs)
                } else if elapsed >= maxUtteranceMs + Self.cutGraceMs {
                    // Przerwa nie nadeszła — tniemy, żeby nie rosło bez końca.
                    trace("limit + \(Int(Self.cutGraceMs)) ms bez przerwy — tnę")
                    diarizer.flush(at: tMs)
                }
            }
        }
        if backend == .appleSpeech {
            await recognizer.feed(chunk.samples, startMs: chunk.startMs)
        }
    }

    // MARK: - ścieżka whisper (transkrypcja przyrostowa)

    private func openUtterance(at startMs: Double) {
        trace("otwieram wypowiedź @\(Int(startMs))")
        sequence += 1
        utterance = Utterance(key: "\(source.rawValue)#\(sequence)", startMs: startMs)
    }

    /// Etykieta mówcy bywa znana dopiero po kilkuset ms mowy.
    private func speakerFor(_ u: inout Utterance) -> String {
        if let known = u.speaker { return known }
        guard let index = diarizer.currentSpeaker else { return unknownSpeaker }
        let name = label(for: index)
        u.speaker = name
        return name
    }

    private static let debug = ProcessInfo.processInfo.environment["CW_DEBUG"] == "1"
    private func trace(_ message: String) {
        guard Self.debug else { return }
        FileHandle.standardError.write(Data("[pipe:\(source.rawValue)] \(message)\n".utf8))
    }

    private func tick() async {
        // Dźwięk ucichł i przestał przychodzić — domykamy turę sami, inaczej
        // wisiałaby otwarta w nieskończoność.
        if utterance != nil,
           Date().timeIntervalSince(lastChunkAt) * 1000 > Self.audioStallMs {
            trace("cisza w strumieniu — domykam turę")
            diarizer.flush(at: lastFrameMs)
            return
        }

        // Mowa ciągła bez pauz — VAD nie ma na czym domknąć tury.
        if let open = utterance, ring.newestMs - open.startMs >= maxUtteranceMs {
            trace("wypowiedź przekroczyła \(Int(maxUtteranceMs)) ms — domykam")
            diarizer.flush(at: lastFrameMs)
            return
        }

        guard let u = utterance else { return }
        guard inFlight == nil else { trace("tick: poprzednia w locie"); return }
        let now = ring.newestMs
        guard now - u.startMs >= minAudioMs else { return }

        let to = Swift.min(now, u.startMs + maxUtteranceMs)
        guard let pcm = ring.readRange(from: u.startMs - padMs, to: to), !pcm.isEmpty else { return }
        trace("tick: \(pcm.count) próbek (\(Int(Double(pcm.count) / 16))ms)")

        // Zadania NIE czekamy tutaj: `tick()` jest wołany z pętli, która czeka
        // na jego zakończenie, więc jedno zawieszone żądanie zatrzymywałoby
        // całą pętlę razem z wykrywaniem ciszy powyżej.
        let key = u.key
        let startMs = u.startMs
        inFlight = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.runIncremental(pcm, key: key, startMs: startMs)
            await self.clearInFlight()
        }
    }

    private func clearInFlight() { inFlight = nil }

    /// Runda przyrostowa: pełna transkrypcja wypowiedzi od jej początku.
    ///
    /// Wygląda na marnotrawstwo, ale encoder Whispera kosztuje tyle samo
    /// niezależnie od długości audio (wejście jest dopychane do okna 30 s),
    /// więc powtarzanie jest tanie — a tekst pojawia się W TRAKCIE mówienia
    /// zamiast po jego końcu.
    private func runIncremental(_ pcm: [Float], key: String, startMs: Double) async {
        do {
            let text = try await whisper.transcribe(pcm, context: whisperPrompt, quality: .fast)
            trace("part -> \"\(text)\"")
            // Wypowiedź mogła się w międzyczasie domknąć — wynik dotyczy wtedy
            // czegoś, czego już nie ma, i nie wolno go nikomu przypisać.
            guard utterance?.key == key else { trace("part: wypowiedź już zamknięta"); return }
            guard !text.isEmpty, text != utterance?.lastText else { return }

            utterance?.lastText = text
            let speaker = currentLabel()
            utterance?.speaker = speaker
            onUpdate?(Update(source: source, key: key, speaker: speaker, text: text,
                             isFinal: false, startMs: sessionMs(startMs)))
        } catch {
            if !(error is CancellationError) { onError?(error) }
        }
    }

    /// Etykieta mówcy bywa znana dopiero po kilkuset ms mowy.
    private func currentLabel() -> String {
        if let known = utterance?.speaker { return known }
        return label(for: diarizer.currentSpeaker)
    }

    private func closeUtterance(_ turn: Diarizer.Turn) async {
        guard var u = utterance else { return }

        // Wypowiedź przejmujemy NATYCHMIAST, przed jakimkolwiek `await`.
        //
        // Wcześniej `utterance` był zerowany dopiero na końcu tej metody, po
        // dwóch punktach zawieszenia. W międzyczasie ruszała już następna tura
        // i ustawiała tam swoją wypowiedź — którą to zerowanie kasowało.
        // Objawem były zdania znikające z transkryptu i wypowiedzi bez wersji
        // ostatecznej, pozostające na surowej rundzie przyrostowej.
        utterance = nil
        // Etykieta z domkniętej tury jest pewniejsza niż prowizoryczna.
        let speaker = label(for: turn.speaker)
        u.speaker = speaker

        if turn.endMs - turn.startMs < minTurnMs {
            trace("tura za krótka (\(Int(turn.endMs - turn.startMs)) ms) — odrzucam")
            onUpdate?(Update(source: source, key: u.key, speaker: speaker, text: "",
                             isFinal: true, startMs: sessionMs(u.startMs), discard: true))
            return
        }

        // Runda przyrostowa w locie dotyczy tej samej wypowiedzi, ale krótszego
        // audio — jej wynik jest już nieaktualny.
        inFlight?.cancel()
        inFlight = nil

        var text = u.lastText
        if let pcm = ring.readRange(
            from: u.startMs - padMs,
            to: Swift.min(turn.endMs + padMs, u.startMs + maxUtteranceMs)
        ), !pcm.isEmpty {
            do {
                let final = try await whisper.transcribe(pcm, context: whisperPrompt, quality: .accurate)
                trace("final -> \"\(final)\"")
                if !final.isEmpty { text = final }
            } catch {
                if !(error is CancellationError) { onError?(error) }
            }
        }

        // Domknięta wypowiedź zasila kontekst kolejnej.
        if !text.isEmpty {
            context = String((context + " " + text).suffix(Self.maxContextChars))
        }

        onUpdate?(Update(source: source, key: u.key, speaker: speaker, text: text,
                         isFinal: true, startMs: sessionMs(u.startMs), discard: text.isEmpty))
    }

    // MARK: - ścieżka Apple

    private func handleApple(_ transcript: SpeechRecognizer.Transcript) {
        let text = Text.normalize(transcript.text)
        guard !text.isEmpty else { return }

        // `SpeechAnalyzer` daje zakres czasu wyniku, więc pytamy diaryzator
        // o dokładnie ten przedział, zamiast zgadywać okno.
        let index = diarizer.dominantSpeaker(from: transcript.startMs, to: transcript.endMs)

        onUpdate?(Update(
            source: source,
            key: "\(source.rawValue)#\(sequence)",
            speaker: label(for: index),
            text: text,
            isFinal: transcript.isFinal,
            startMs: sessionMs(transcript.startMs)
        ))
        if transcript.isFinal { sequence += 1 }
    }

    // MARK: - wspólne

    /// Nazwa mówcy. Z samego głosu nie da się odczytać imienia, więc etykiety
    /// są anonimowe — ale rozdzielenie źródeł daje za darmo pewne „Ty".
    private func label(for index: Int?) -> String {
        // Bez rozpoznawania mówcy zostaje podział, który i tak jest pewny:
        // mikrofon to Ty, dźwięk systemu to reszta. Nic tu nie zgadujemy.
        guard identifySpeakers else {
            return source == .microphone ? "Ty" : "Rozmówcy"
        }
        switch source {
        case .microphone:
            // Mikrofon to zwykle jedna osoba; dopiero drugi wykryty głos
            // dostaje własną etykietę (ktoś obok, ta sama sala).
            guard let index, index > 0 else { return "Ty" }
            return "Osoba obok \(index + 1)"
        case .system:
            guard let index else { return unknownSpeaker }
            return "Rozmówca \(index + 1)"
        }
    }

    /// Zatrzymanie natychmiastowe.
    ///
    /// Nie dokańczamy zaległości: bufor wejściowy bywa spory, a domknięcie
    /// otwartej wypowiedzi oznacza kolejne żądanie do whispera na nawet 45 s
    /// audio. Użytkownik, który nacisnął „Zatrzymaj", ma dostać zatrzymanie
    /// teraz, a nie za kilkanaście sekund — tekst, który już jest, i tak
    /// zostaje w transkrypcie.
    public func cancel() async {
        inputContinuation?.finish()
        inputContinuation = nil
        inputTask?.cancel()
        inputTask = nil
        ticker?.cancel()
        ticker = nil
        inFlight?.cancel()
        inFlight = nil
        utterance = nil
        if backend == .appleSpeech { await recognizer.finish() }
    }

    public var speakerCount: Int { diarizer.speakerCount }
}
