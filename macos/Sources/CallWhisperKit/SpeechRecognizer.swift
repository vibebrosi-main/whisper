import Foundation
@preconcurrency import AVFoundation
import Speech
import CallWhisperCore

/// Rozpoznawanie mowy on-device przez `SpeechAnalyzer` (macOS 26).
///
/// To zamiennik Web Speech API z wersji webowej i wygrywa z nim w trzech
/// miejscach naraz:
///
///  1. **Znaczniki czasu słów.** Web Speech ich nie oddawał, więc mówcę
///     zgadywaliśmy pytając diaryzator, kto dominował w oknie wyniku. Tutaj
///     każdy wynik ma `range`, więc wiązanie tekstu z mówcą przestaje być
///     przybliżeniem.
///  2. **Brak zależności od SODA i „Napisów na żywo".** Model pobiera się
///     przez `AssetInventory`, programowo, bez wysyłania użytkownika do
///     ustawień przeglądarki.
///  3. **Wyniki przyrostowe z jawnym `isFinal`** zamiast heurystyki na
///     `resultIndex`.
public actor SpeechRecognizer {
    public struct Transcript: Sendable {
        public var text: String
        /// Początek i koniec fragmentu względem startu sesji, w ms.
        public var startMs: Double
        public var endMs: Double
        public var isFinal: Bool
    }

    public enum ModelStatus: Sendable, Equatable {
        case unsupported
        case supported      // da się pobrać, jeszcze nie ma
        case downloading(Double)
        case installed
    }

    public enum RecognizerError: LocalizedError {
        case localeUnsupported(String)
        case noCompatibleFormat
        case notRunning

        public var errorDescription: String? {
            switch self {
            case .localeUnsupported(let id):
                return "Rozpoznawanie mowy nie obsługuje języka \(id)."
            case .noCompatibleFormat:
                return "Nie znalazłem formatu audio zgodnego z modelem mowy."
            case .notRunning:
                return "Rozpoznawanie nie jest uruchomione."
            }
        }
    }

    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var analyzerFormat: AVAudioFormat?
    private let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: asrSampleRate,
                                             channels: 1,
                                             interleaved: false)!

    public init() {}

    /// Czy dany język jest w ogóle obsługiwany przez `SpeechTranscriber`.
    ///
    /// `supportedLocale(equivalentTo:)` NIE nadaje się do tego sprawdzenia:
    /// dla `pl-PL` zwraca `pl_PL`, choć polskiego nie ma na liście
    /// `supportedLocales` (30 pozycji, same zachodnie + CJK). Trzeba porównać
    /// z listą wprost, inaczej start rozpoznawania kończy się dopiero błędem
    /// w trakcie rozmowy.
    public static func isSupported(locale: Locale) async -> Bool {
        await resolvedLocale(locale) != nil
    }

    static func resolvedLocale(_ locale: Locale) async -> Locale? {
        let supported = await SpeechTranscriber.supportedLocales
        let wanted = locale.identifier.replacingOccurrences(of: "-", with: "_")
        if let exact = supported.first(where: { $0.identifier == wanted }) { return exact }
        // Dopuszczamy dopasowanie po samym języku: en-PL -> en_US.
        let language = String(wanted.prefix(2))
        return supported.first { $0.identifier.hasPrefix(language + "_") }
    }

    /// Czy model dla danego języka jest już na dysku.
    public static func modelStatus(locale: Locale) async -> ModelStatus {
        guard let resolved = await resolvedLocale(locale) else {
            return .unsupported
        }
        let module = SpeechTranscriber(locale: resolved, preset: .timeIndexedProgressiveTranscription)
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading(0)
        case .installed: return .installed
        @unknown default: return .unsupported
        }
    }

    /// Pobiera model języka, jeśli trzeba. `onProgress` dostaje 0…1.
    ///
    /// W wersji webowej to był ślepy zaułek: `install()` potrafił zwrócić
    /// `false` mimo poprawnego gestu użytkownika, więc jedyną drogą było
    /// odesłanie go do `chrome://settings/captions`. Natywnie po prostu
    /// prosimy system o pobranie.
    public static func installModel(locale: Locale, onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard let resolved = await resolvedLocale(locale) else {
            throw RecognizerError.localeUnsupported(locale.identifier)
        }
        let module = SpeechTranscriber(locale: resolved, preset: .timeIndexedProgressiveTranscription)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else {
            onProgress(1)
            return // już zainstalowany
        }
        let observation = request.progress.observe(\.fractionCompleted) { progress, _ in
            onProgress(progress.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        onProgress(1)
    }

    /// Uruchamia rozpoznawanie. `onTranscript` dostaje wyniki przyrostowe.
    public func start(locale: Locale,
                      onTranscript: @escaping @Sendable (Transcript) -> Void,
                      onError: @escaping @Sendable (Error) -> Void = { _ in }) async throws {
        guard let resolved = await Self.resolvedLocale(locale) else {
            throw RecognizerError.localeUnsupported(locale.identifier)
        }

        // `timeIndexedProgressiveTranscription`: tekst pojawia się w trakcie
        // mówienia (jak w wersji webowej) i każdy wynik niesie swój zakres czasu.
        let transcriber = SpeechTranscriber(locale: resolved, preset: .timeIndexedProgressiveTranscription)
        self.transcriber = transcriber

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw RecognizerError.noCompatibleFormat
        }
        analyzerFormat = format
        converter = format.settings as NSDictionary == sourceFormat.settings as NSDictionary
            ? nil
            : AVAudioConverter(from: sourceFormat, to: format)

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.continuation = continuation

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    guard !text.isEmpty else { continue }
                    onTranscript(Transcript(
                        text: text,
                        startMs: result.range.start.seconds * 1000,
                        endMs: result.range.end.seconds * 1000,
                        isFinal: result.isFinal
                    ))
                }
            } catch {
                if !(error is CancellationError) { onError(error) }
            }
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        try await analyzer.start(inputSequence: stream)
    }

    /// Dokłada próbki 16 kHz mono. `startMs` to czas pierwszej próbki
    /// względem startu sesji — dzięki temu `range` w wynikach jest w tej samej
    /// skali, co tury diaryzatora.
    public func feed(_ samples: [Float], startMs: Double) {
        guard let continuation, let analyzerFormat else { return }
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat,
                                            frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = source.floatChannelData?[0]
        else { return }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }

        let buffer: AVAudioPCMBuffer
        if let converter {
            let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return }
            guard convertOnce(converter, input: source, into: out) else { return }
            buffer = out
        } else {
            buffer = source
        }

        // Świadomie BEZ `bufferStartTime`.
        //
        // Podawanie własnych znaczników kończyło się błędem „Audio input
        // timestamp overlaps or precedes prior audio input": czas liczyliśmy
        // w dziedzinie 16 kHz, a bufor po konwersji do formatu analizatora ma
        // inną długość, więc kolejne zakresy na siebie nachodziły. Bez
        // znacznika analizator sam prowadzi ciągły czas od początku strumienia
        // — a że karmimy go bez przerw od startu sesji, wychodzi na to samo,
        // co oś czasu diaryzatora.
        continuation.yield(AnalyzerInput(buffer: buffer))
    }

    /// Domyka strumień i czeka na ostateczne wyniki.
    public func finish() async {
        continuation?.finish()
        continuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        resultsTask?.cancel()
        resultsTask = nil
        analyzer = nil
        transcriber = nil
        converter = nil
        analyzerFormat = nil
    }
}
