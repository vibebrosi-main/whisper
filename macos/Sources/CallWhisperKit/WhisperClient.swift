import Foundation
import CallWhisperCore

/// Klient lokalnego whisper.cpp (`whisper-server`).
///
/// Powód istnienia: **`SpeechTranscriber` nie obsługuje polskiego.** Lista
/// `SpeechTranscriber.supportedLocales` ma 30 pozycji i nie ma wśród nich
/// żadnej polskiej. Whisper jest jedyną drogą do polskiego na urządzeniu,
/// a przy okazji jest lepszy dla gęstego słownictwa technicznego.
///
/// Pomiary z wersji webowej (Apple M4, ciepły serwer, 5 s polskiego audio):
///
///   ggml-small           188 ms encode -> 396 ms round-trip HTTP
///   ggml-large-v3-turbo  902 ms encode -> ~1,4 s
///
/// Zmierzone 2026-09-06 na polskim materiale z nazwami własnymi (WER względem
/// znanego tekstu, ten sam plik, ciepły serwer):
///
///   small,  greedy, bez promptu   26,7 %    696 ms   <- ustawienia startowe
///   small,  beam 5, bez promptu   23,3 %    896 ms
///   small,  beam 5, z promptem    13,3 %    929 ms
///   turbo,  beam 5, z promptem    10,0 %   1570 ms
///
/// Wniosek, którego się nie spodziewałem: **największą pojedynczą poprawę daje
/// `prompt`, nie model ani beam search** — kontekst rozmowy niemal połowi
/// liczbę błędów kosztem 33 ms, bo nakierowuje dekoder na słownictwo, które
/// w tej rozmowie już padło.
public struct WhisperClient: Sendable {
    /// Ustawienia dekodera. Dwa profile, bo służą do czego innego.
    public struct Quality: Sendable {
        /// Beam search zamiast zachłannego dekodowania. `nil` = zachłannie.
        public var beamSize: Int?
        /// Odsiewa `[Muzyka]`, `*w tle*` i resztę znaczników nie-mowy.
        public var suppressNonSpeech: Bool

        /// Do rund przyrostowych: tekst ma się pojawić szybko, i tak go za
        /// chwilę podmienimy.
        public static let fast = Quality(beamSize: nil, suppressNonSpeech: true)
        /// Do wersji ostatecznej: to ona zostaje w notatce.
        public static let accurate = Quality(beamSize: 5, suppressNonSpeech: true)
    }

    public let endpoint: URL
    public let language: String
    private let session: URLSession

    /// - Parameter timeout: 15 s dla rozmowy na żywo — 45 s audio na modelu
    ///   `small` to ~2 s inferencji, a po 15 s rozmowa dawno poszła dalej.
    ///   Import nagrania wysyła kilkuminutowe kawałki i potrzebuje więcej.
    public init(endpoint: URL = URL(string: "http://127.0.0.1:8899")!, language: String = "pl",
                timeout: TimeInterval = 15) {
        self.endpoint = endpoint
        self.language = language
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        self.session = URLSession(configuration: config)
    }

    public enum WhisperError: LocalizedError {
        case offline(URL)
        case http(Int)

        public var errorDescription: String? {
            switch self {
            case .offline(let url):
                return "Nie mogę połączyć się z whisper-server (\(url.absoluteString)). Uruchom go z Ustawień albo `npm run whisper`."
            case .http(let status):
                return "whisper-server zwrócił \(status)."
            }
        }
    }

    public func health(timeout: TimeInterval = 1.5) async -> Bool {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        guard let (_, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode < 500
    }

    /// - Parameters:
    ///   - pcm: 16 kHz mono
    ///   - context: co padło w rozmowie wcześniej. Trafia do `initial_prompt`
    ///     whispera i jest najtańszym sposobem na poprawę jakości, jaki tu jest.
    public func transcribe(_ pcm: [Float], sampleRate: Int = 16_000,
                           context: String = "", quality: Quality = .accurate) async throws -> String {
        let data = try await inference(pcm, sampleRate: sampleRate, context: context,
                                       quality: quality, format: "json")
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return Text.cleanWhisper(json?["text"] as? String ?? "")
    }

    /// Segmenty z czasami (`verbose_json`) — do importu nagrań, gdzie granice
    /// zdań wyznacza whisper, a nie VAD na żywo.
    public func transcribeSegments(_ pcm: [Float], sampleRate: Int = 16_000,
                                   context: String = "", quality: Quality = .accurate) async throws -> [TimedText] {
        let data = try await inference(pcm, sampleRate: sampleRate, context: context,
                                       quality: quality, format: "verbose_json")
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let segments = json?["segments"] as? [[String: Any]] ?? []
        var out: [TimedText] = []
        var raw: [String] = []
        for segment in segments {
            guard let start = segment["start"] as? Double, let end = segment["end"] as? Double else { continue }
            let text = segment["text"] as? String ?? ""
            // Segment, który nie zaczyna się od spacji, to ciąg dalszy słowa
            // rozciętego na granicy poprzedniego, więc doklejamy go bez przerwy.
            if let first = text.first, !first.isWhitespace, let last = out.indices.last {
                raw[last] += text
                out[last].end = end
            } else {
                out.append(TimedText(start: start, end: end, text: ""))
                raw.append(text)
            }
        }
        for i in out.indices { out[i].text = Text.cleanWhisper(raw[i]) }
        return out.filter { !$0.text.isEmpty }
    }

    private func inference(_ pcm: [Float], sampleRate: Int, context: String,
                           quality: Quality, format: String) async throws -> Data {
        let boundary = "cw-\(UUID().uuidString)"
        var body = Data()

        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"chunk.wav\"\r\n".utf8))
        body.append(Data("Content-Type: audio/wav\r\n\r\n".utf8))
        body.append(Wav.encode(pcm, sampleRate: sampleRate))
        body.append(Data("\r\n".utf8))

        field("language", language)
        field("response_format", format)
        field("temperature", "0")
        // Bez tego whisper.cpp dokleja halucynacje na ciszy.
        field("no_speech_thold", "0.6")
        // whisper.cpp tnie segmenty po tokenach, czyli w środku słowa
        // („poniedz" + „iałek"), a granice oddaje jako `\n`. Zmierzone
        // 2026-10-06 na `small`: bez tego co trzecie długie słowo w notatce
        // było rozbite („odpow iedzialny", „zatrudn ieniowa").
        field("split_on_word", "true")
        if quality.suppressNonSpeech { field("suppress_nst", "true") }
        if let beam = quality.beamSize { field("beam_size", String(beam)) }
        if !context.isEmpty { field("prompt", context) }
        body.append(Data("--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: endpoint.appendingPathComponent("inference"))
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // URLSession przy anulowaniu rzuca `URLError(.cancelled)`, a nie
            // `CancellationError` — bez tego rozróżnienia każda runda przerwana
            // przez domknięcie wypowiedzi meldowała się jako „serwer nie działa"
            // i zostawała w interfejsie jako błąd, którego nie było.
            if error is CancellationError { throw error }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw CancellationError()
            }
            throw WhisperError.offline(endpoint)
        }

        guard let http = response as? HTTPURLResponse else { throw WhisperError.offline(endpoint) }
        guard http.statusCode == 200 else { throw WhisperError.http(http.statusCode) }
        return data
    }
}
