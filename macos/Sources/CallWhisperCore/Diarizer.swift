import Foundation

/// Rozpoznawanie mówcy po głosie (diaryzacja) — online, bez modelu neuronowego.
///
/// Łańcuch: ramki PCM -> VAD -> MFCC -> embedding wypowiedzi -> klastrowanie
/// online po podobieństwie kosinusowym. Embedding to statystyki cepstralne
/// (średnia + odchylenie), czyli klasyczne podejście sprzed ery sieci
/// neuronowych.
///
/// Świadome ograniczenie: to rozdziela wyraźnie różne głosy, ale jest istotnie
/// słabsze od modeli typu x-vector/ECAPA. Podobne głosy potrafi skleić.
/// Port z `extension/src/adapters/audio/diarizer.js`.

/// Kosinus między wektorami znormalizowanymi L2.
public func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
    var dot = 0.0
    for i in 0..<Swift.min(a.count, b.count) { dot += a[i] * b[i] }
    return dot
}

/// Normalizacja L2.
public func l2Normalize(_ vector: [Double]) -> [Double] {
    var sum = 0.0
    for v in vector { sum += v * v }
    let norm = sum.squareRoot()
    guard norm > 0 else { return vector }
    return vector.map { $0 / norm }
}

/// Embedding wypowiedzi: [średnia MFCC, odchylenie MFCC], znormalizowany L2.
public func embedFrames(_ frames: [[Double]]) -> [Double]? {
    guard let first = frames.first else { return nil }
    let dim = first.count
    var mean = [Double](repeating: 0, count: dim)
    var variance = [Double](repeating: 0, count: dim)

    for frame in frames {
        for i in 0..<dim { mean[i] += frame[i] }
    }
    for i in 0..<dim { mean[i] /= Double(frames.count) }

    for frame in frames {
        for i in 0..<dim {
            let d = frame[i] - mean[i]
            variance[i] += d * d
        }
    }
    for i in 0..<dim { variance[i] = (variance[i] / Double(frames.count)).squareRoot() }

    var embedding = [Double](repeating: 0, count: dim * 2)
    for i in 0..<dim {
        embedding[i] = mean[i]
        embedding[dim + i] = variance[i]
    }
    return l2Normalize(embedding)
}

/// Klastrowanie online: przypisuje embedding do mówcy albo zakłada nowego.
public final class SpeakerTracker {
    public struct Assignment: Sendable {
        public var index: Int
        public var similarity: Double
        public var isNew: Bool
    }

    /// Powyżej tego podobieństwa kosinusowego to ten sam mówca.
    public var threshold: Double
    public var maxSpeakers: Int
    /// Inercja centroidu — nowa próbka nie może go przewrócić.
    public var inertia: Double

    private var centroids: [[Double]] = []
    private var counts: [Int] = []

    public init(threshold: Double = 0.82, maxSpeakers: Int = 8, centroidInertia: Double = 0.85) {
        self.threshold = threshold
        self.maxSpeakers = maxSpeakers
        self.inertia = centroidInertia
    }

    @discardableResult
    public func assign(_ embedding: [Double]) -> Assignment {
        var best = -1
        var bestSimilarity = -Double.infinity

        for i in centroids.indices {
            let similarity = cosineSimilarity(embedding, centroids[i])
            if similarity > bestSimilarity {
                bestSimilarity = similarity
                best = i
            }
        }

        if best >= 0 && bestSimilarity >= threshold {
            update(best, embedding)
            return Assignment(index: best, similarity: bestSimilarity, isNew: false)
        }

        if centroids.count < maxSpeakers {
            centroids.append(embedding)
            counts.append(1)
            return Assignment(index: centroids.count - 1, similarity: bestSimilarity, isNew: true)
        }

        // Limit mówców wyczerpany — dokładamy do najbliższego zamiast zgadywać.
        update(best, embedding)
        return Assignment(index: best, similarity: bestSimilarity, isNew: false)
    }

    private func update(_ index: Int, _ embedding: [Double]) {
        var centroid = centroids[index]
        for i in centroid.indices {
            centroid[i] = centroid[i] * inertia + embedding[i] * (1 - inertia)
        }
        centroids[index] = l2Normalize(centroid)
        counts[index] += 1
    }

    public var count: Int { centroids.count }
}

/// Pełny diaryzator: karmisz go ramkami PCM, oddaje etykiety mówców i tury.
public final class Diarizer {
    public struct Turn: Sendable, Equatable {
        public var speaker: Int
        public var startMs: Double
        public var endMs: Double
    }

    public let extractor: MfccExtractor
    public let vad: Vad
    public let tracker: SpeakerTracker
    /// Ile ramek mowy musi się zebrać, zanim w ogóle zgadujemy mówcę.
    public var minFrames: Int
    /// Co ile ramek odświeżamy prowizoryczną etykietę w trakcie mówienia.
    public var refreshEveryFrames: Int

    /// Czy w ogóle rozpoznawać, KTO mówi.
    ///
    /// Wyłączone zostawia wykrywanie mowy (VAD) i granice tur — na nich stoi
    /// cały łańcuch transkrypcji — a pomija MFCC, embedding i klastrowanie.
    /// Dwa powody, żeby móc to wyłączyć:
    ///
    ///  - klastrowanie MFCC to podejście sprzed ery sieci neuronowych i przy
    ///    kilku podobnych głosach rozsypuje jedną osobę na pięć etykiet, co
    ///    psuje transkrypt bardziej, niż brak etykiet w ogóle;
    ///  - MFCC liczone dla każdej ramki co 10 ms to najdroższa część pętli,
    ///    więc bez niego zostaje sam VAD na energii.
    public var identifySpeakers: Bool

    /// Wołane przy zamknięciu tury — backend plikowy (whisper.cpp) tnie tu audio.
    public var onTurn: (Turn) -> Void = { _ in }
    /// Wołane przy otwarciu tury — backend strumieniowy zaczyna tu nasłuch.
    public var onTurnStart: (Double) -> Void = { _ in }

    /// Indeks mówcy aktualnie mówiącego, albo nil.
    public private(set) var currentSpeaker: Int?
    /// Stan VAD z ostatniej ramki — pozwala domknąć turę w przerwie między
    /// zdaniami, zamiast ciąć w połowie słowa.
    public private(set) var lastFrameLoud = false
    public private(set) var turns: [Turn] = []

    private var frames: [[Double]] = []
    private var turnStartMs: Double = 0
    private var framesSinceRefresh = 0
    private var lastFrameMs: Double = 0

    public init(extractor: MfccExtractor = MfccExtractor(), vad: Vad = Vad(),
                tracker: SpeakerTracker = SpeakerTracker(),
                minFrames: Int = 25, refreshEveryFrames: Int = 25,
                identifySpeakers: Bool = true) {
        self.extractor = extractor
        self.vad = vad
        self.tracker = tracker
        self.minFrames = minFrames
        self.refreshEveryFrames = refreshEveryFrames
        self.identifySpeakers = identifySpeakers
    }

    /// Jedna ramka PCM (frameSize próbek), `tMs` to czas jej początku.
    @discardableResult
    public func pushFrame(_ frame: [Float], at tMs: Double) -> Int? {
        let energyDb = MfccExtractor.frameEnergyDb(frame)
        lastFrameMs = tMs
        let state = vad.push(energyDb)
        lastFrameLoud = state.loud

        if state.started {
            frames = []
            framesSinceRefresh = 0
            turnStartMs = tMs
            // Bez rozpoznawania mówcy i tak trzeba mieć kogoś w turze, inaczej
            // `closeTurn` uznałby ją za pustą i wyrzucił razem z transkrypcją.
            currentSpeaker = identifySpeakers ? nil : 0
            onTurnStart(tMs)
        }

        if identifySpeakers, state.speaking, state.loud {
            frames.append(extractor.frameToMfcc(frame))
            framesSinceRefresh += 1

            let enough = frames.count >= minFrames
            let due = framesSinceRefresh >= refreshEveryFrames
            if enough && (currentSpeaker == nil || due) {
                framesSinceRefresh = 0
                classify()
            }
        }

        if state.ended { closeTurn(at: tMs) }
        return currentSpeaker
    }

    private func classify() {
        // Świadomie bez CMN: w obrębie jednego źródła kanał jest stały, więc
        // normalizacja cepstralna nic nie różnicuje, a jej dryf w trakcie sesji
        // przesuwa przestrzeń embeddingów pod już nauczonymi centroidami.
        guard let embedding = embedFrames(frames) else { return }
        currentSpeaker = tracker.assign(embedding).index
    }

    private func closeTurn(at endMs: Double) {
        if let speaker = currentSpeaker, endMs > turnStartMs {
            let turn = Turn(speaker: speaker, startMs: turnStartMs, endMs: endMs)
            turns.append(turn)
            onTurn(turn)
        }
        frames = []
        currentSpeaker = nil
    }

    /// Domyka otwartą turę — na koniec sesji.
    public func flush(at endMs: Double) {
        if vad.speaking {
            if currentSpeaker == nil && !frames.isEmpty { classify() }
            closeTurn(at: endMs)
            vad.reset()
        }
    }

    /// Kto dominował w oknie czasu — tak wiążemy tekst z ASR z mówcą.
    /// Uwzględnia też turę wciąż otwartą.
    public func dominantSpeaker(from fromMs: Double, to toMs: Double) -> Int? {
        var totals: [Int: Double] = [:]
        func add(_ speaker: Int, _ ms: Double) {
            if ms > 0 { totals[speaker, default: 0] += ms }
        }

        for turn in turns {
            add(turn.speaker, Swift.min(turn.endMs, toMs) - Swift.max(turn.startMs, fromMs))
        }
        if let speaker = currentSpeaker {
            // Tura wciąż otwarta — jej koniec to ostatnia widziana ramka, nie zegar ścienny.
            add(speaker, Swift.min(toMs, lastFrameMs) - Swift.max(turnStartMs, fromMs))
        }

        return totals.max { a, b in
            a.value != b.value ? a.value < b.value : a.key > b.key
        }?.key
    }

    public var speakerCount: Int { tracker.count }
}

/// Tnie ciągły strumień próbek na ramki o stałej długości z zadanym skokiem.
/// Port z `extension/src/adapters/audio/framer.js`.
public final class Framer {
    public let frameSize: Int
    public let hopSize: Int
    private var buffer: [Float] = []
    /// Ile próbek już wypadło z bufora — pozwala liczyć czas ramki bez dryfu.
    private var consumed = 0

    public init(frameSize: Int, hopSize: Int) {
        precondition(frameSize > 0 && hopSize > 0, "Framer: rozmiary muszą być dodatnie")
        self.frameSize = frameSize
        self.hopSize = hopSize
    }

    /// Dokłada próbki i oddaje wszystkie kompletne ramki wraz z indeksem
    /// pierwszej próbki każdej z nich.
    public func push(_ samples: [Float]) -> [(frame: [Float], startSample: Int)] {
        buffer.append(contentsOf: samples)
        var out: [(frame: [Float], startSample: Int)] = []
        while buffer.count >= frameSize {
            out.append((Array(buffer[0..<frameSize]), consumed))
            buffer.removeFirst(hopSize)
            consumed += hopSize
        }
        return out
    }

    public func reset() {
        buffer.removeAll()
        consumed = 0
    }
}
