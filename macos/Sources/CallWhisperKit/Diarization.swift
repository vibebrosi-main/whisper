import Foundation
import CallWhisperCore

/// Zapis 16 kHz mono do pliku WAV, strumieniowo.
///
/// Godzina rozmowy to 115 MB w Int16 — trzymanie tego w pamięci jako `[Float]`
/// (230 MB) tylko po to, żeby na końcu zrobić z tego plik, nie ma sensu.
///
/// Wypełnia dziury ciszą według znaczników czasu: ScreenCaptureKit **nie
/// wysyła buforów, gdy w systemie panuje cisza**, więc zapis „próbka za
/// próbką" rozjechałby się z osią czasu transkryptu — dokładnie ten sam błąd,
/// który kiedyś dawał wypowiedzi ze znacznikiem `00:00:00`.
public final class WavFileWriter: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var written = 0
    private let sampleRate: Double

    public init(url: URL, sampleRate: Double = 16_000) throws {
        self.url = url
        self.sampleRate = sampleRate
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Wav.encode([], sampleRate: Int(sampleRate)))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    /// - Parameter startMs: czas pierwszej próbki względem początku nagrania.
    ///   `nil` = dopisz zaraz za poprzednimi.
    public func append(_ samples: [Float], startMs: Double? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let startMs {
            let expected = Int((startMs / 1000 * sampleRate).rounded())
            // 20 ms tolerancji na drganie zegara; dopiero większa luka to cisza.
            let gap = expected - written
            if gap > Int(sampleRate / 50) { writeSamples([Float](repeating: 0, count: gap)) }
        }
        writeSamples(samples)
    }

    private func writeSamples(_ samples: [Float]) {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = Swift.max(-1, Swift.min(1, sample))
            let value = Int16((clamped < 0 ? clamped * 32768 : clamped * 32767).rounded(.towardZero))
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        handle.write(data)
        written += samples.count
    }

    public var durationSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return Double(written) / sampleRate
    }

    /// Domyka plik: wpisuje do nagłówka prawdziwe długości.
    public func finish() {
        lock.lock(); defer { lock.unlock() }
        let dataBytes = UInt32(written * 2)
        func patch(_ offset: UInt64, _ value: UInt32) {
            try? handle.seek(toOffset: offset)
            withUnsafeBytes(of: value.littleEndian) { handle.write(Data($0)) }
        }
        patch(4, 36 + dataBytes)
        patch(40, dataBytes)
        try? handle.close()
    }
}

/// Diaryzacja neuronowa: `sherpa-onnx-offline-speaker-diarization`
/// z segmentacją pyannote i odciskiem głosu CAM++ (zestaw z OpenWhispr).
///
/// Działa na całym pliku, nie na żywo — klastrowanie widzi wtedy wszystkie
/// głosy naraz, zamiast decydować o pierwszym, zanim usłyszy drugi. To jest
/// główny powód, dla którego MFCC na żywo rozsypywało jedną osobę na kilka
/// etykiet.
public enum NeuralDiarizer {
    public enum DiarizeError: LocalizedError {
        case notInstalled
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "Silnik diaryzacji nie jest zainstalowany."
            case .failed(let detail): return "Diaryzacja nie powiodła się: \(detail)"
            }
        }
    }

    /// Instaluje brakujące części (silnik ~63 MB, modele ~37 MB).
    public static func ensureInstalled(onProgress: @escaping @Sendable (String) -> Void) async throws {
        for component in [Engines.Component.diarizer, .diarizationModels] where !Engines.isInstalled(component) {
            let mb = Double(Engines.downloadBytes(component)) / 1e6
            try await Engines.install(component) { fraction in
                onProgress(String(format: "Pobieram %@ — %.0f%% z %.0f MB",
                                  component.label.lowercased(), fraction * 100, mb))
            }
        }
    }

    /// - Parameters:
    ///   - speakers: znana liczba osób; `nil` = niech klastrowanie zdecyduje
    ///   - threshold: próg łączenia klastrów. 0,5 to domyślna wartość
    ///     sherpa-onnx; na nagraniu wzorcowym z czterema głosami 0,5 i 0,55
    ///     dały identyczny wynik, 0,7 sklejało już różne osoby.
    public static func run(wav: URL, speakers: Int? = nil, threshold: Double = 0.5) async throws -> [SpeakerTurn] {
        guard let binary = Engines.diarizer, let models = Engines.diarizationModels else {
            throw DiarizeError.notInstalled
        }
        var arguments = [
            "--segmentation.pyannote-model=\(models.segmentation.path)",
            "--embedding.model=\(models.embedding.path)",
            "--min-duration-on=0.2",
            "--min-duration-off=0.5",
        ]
        if let speakers, speakers > 0 {
            arguments.append("--clustering.num-clusters=\(speakers)")
        } else {
            arguments.append("--clustering.cluster-threshold=\(threshold)")
        }
        arguments.append(wav.path)

        // Wyjście do plików, nie do potoków: sherpa wypisuje na stderr całą
        // konfigurację, a nieczytany potok blokuje proces po 64 kB.
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("cw-diar-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("cw-diar-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }

        let task = Process()
        task.executableURL = binary
        task.arguments = arguments
        task.standardOutput = try FileHandle(forWritingTo: outURL)
        task.standardError = try FileHandle(forWritingTo: errURL)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                task.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                do { try task.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            task.terminate()
        }

        let output = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
        guard status == 0 else { throw DiarizeError.failed(String(stderr.suffix(300))) }
        // Parser pomija wszystko poza liniami tur, więc czytamy oba strumienie —
        // nie zakładamy, na który z nich dana wersja sherpa wypisuje wynik.
        return SpeakerTurns.parse(output + "\n" + stderr)
    }
}
