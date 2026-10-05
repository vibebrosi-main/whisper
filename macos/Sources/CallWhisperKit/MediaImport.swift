import Foundation
import AVFoundation
import CallWhisperCore

/// Import nagrania albo wideo do transkryptu — funkcja z whistlera
/// (`videoImportManager`), przepisana bez ffmpeg.
///
/// Whistler wołał ffmpeg, żeby wyciągnąć dźwięk z mp4 i pociąć go na
/// dziesięciominutowe kawałki. Tutaj robi to AVFoundation: `AVAssetReader`
/// dekoduje mp4/mov/m4a/mp3/wav i od razu zmiksowuje wszystkie ścieżki do
/// 16 kHz mono. Zero zależności, tak jak reszta aplikacji.
public enum MediaImport {
    public static let fileExtensions = ["mp4", "mov", "m4v", "m4a", "mp3", "wav", "aiff", "aif", "caf", "aac"]

    public struct Options: Sendable {
        public var whisperPort: Int
        public var language: String
        /// Diaryzacja neuronowa po transkrypcji.
        public var diarize: Bool
        /// Znana liczba osób; `nil` = niech klastrowanie zdecyduje.
        public var speakers: Int?

        public init(whisperPort: Int, language: String, diarize: Bool, speakers: Int? = nil) {
            self.whisperPort = whisperPort; self.language = language
            self.diarize = diarize; self.speakers = speakers
        }
    }

    public struct Result: Sendable {
        public var segments: [Segment]
        public var meta: SessionMeta
        /// Liczba rozpoznanych głosów; 0 = bez diaryzacji.
        public var speakerCount: Int
        /// Dlaczego diaryzacja się nie odbyła, choć była zamówiona.
        public var diarizationNote: String?
    }

    public enum ImportError: LocalizedError {
        case noAudio(String)
        case decode(String)

        public var errorDescription: String? {
            switch self {
            case .noAudio(let name): return "\(name) nie ma ścieżki dźwiękowej."
            case .decode(let detail): return "Nie udało się odczytać dźwięku: \(detail)"
            }
        }
    }

    /// Dekoduje dźwięk do 16 kHz mono Float32.
    public static func decode(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw ImportError.noAudio(url.lastPathComponent) }

        let reader = try AVAssetReader(asset: asset)
        // Mix, a nie pojedyncza ścieżka: nagrania rozmów potrafią mieć osobne
        // ścieżki na każdą stronę, a my chcemy słyszeć wszystkich.
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: asrSampleRate,
            AVNumberOfChannelsKey: 1,
        ])
        guard reader.canAdd(output) else { throw ImportError.decode("nieobsługiwany format") }
        reader.add(output)
        guard reader.startReading() else {
            throw ImportError.decode(reader.error?.localizedDescription ?? "startReading")
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            samples += chunk
        }
        if reader.status == .failed {
            throw ImportError.decode(reader.error?.localizedDescription ?? "przerwane")
        }
        return samples
    }

    /// Kawałki do transkrypcji, cięte w najcichszym miejscu.
    ///
    /// Whistler ciął co równe 10 minut, czyli zwykle w połowie słowa — to słowo
    /// ginęło albo przekręcało się po obu stronach cięcia. Szukamy najcichszych
    /// 100 ms w ostatnich 10 s kawałka i tam tniemy.
    static func chunkBounds(count: Int, target: Int, window: Int, samples: [Float]) -> [Range<Int>] {
        var bounds: [Range<Int>] = []
        var start = 0
        let hop = Int(asrSampleRate / 10)
        while start < count {
            var end = min(count, start + target)
            if end < count {
                var best = end, bestEnergy = Float.greatestFiniteMagnitude
                var probe = max(start + hop, end - window)
                while probe + hop <= end {
                    var energy: Float = 0
                    for i in probe..<(probe + hop) { energy += samples[i] * samples[i] }
                    if energy < bestEnergy { bestEnergy = energy; best = probe + hop / 2 }
                    probe += hop
                }
                end = best
            }
            bounds.append(start..<end)
            start = end
        }
        return bounds
    }

    /// Cały import: dekodowanie -> whisper -> (diaryzacja) -> segmenty.
    ///
    /// `whisper-server` ma już działać — uruchamia go wołający, bo to on wie,
    /// czy serwer jest jego.
    public static func run(_ url: URL, options: Options,
                           progress: @escaping @Sendable (String) -> Void) async throws -> Result {
        progress("Odczytuję dźwięk z \(url.lastPathComponent)…")
        let pcm = try await decode(url)
        let seconds = Double(pcm.count) / asrSampleRate

        // Dwie minuty na kawałek: na `small` to kilka sekund inferencji, więc
        // pasek postępu żyje, a przy okazji nie zbliżamy się do limitu czasu.
        let rate = Int(asrSampleRate)
        let bounds = chunkBounds(count: pcm.count, target: 120 * rate, window: 10 * rate, samples: pcm)
        let client = WhisperClient(endpoint: URL(string: "http://127.0.0.1:\(options.whisperPort)")!,
                                   language: options.language, timeout: 600)

        var texts: [TimedText] = []
        var context = ""
        for (index, range) in bounds.enumerated() {
            try Task.checkCancellation()
            progress(String(format: "Transkrybuję %@ — %d/%d (%.0f%%)", url.lastPathComponent,
                            index + 1, bounds.count, Double(range.lowerBound) / Double(max(1, pcm.count)) * 100))
            let offset = Double(range.lowerBound) / asrSampleRate
            let part = try await client.transcribeSegments(Array(pcm[range]), context: context)
            texts += part.map { TimedText(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
            // Ten sam trik, co na żywo: końcówka poprzedniego kawałka jako
            // `prompt` prawie połowi błędy w nazwach własnych.
            context = String(texts.map(\.text).joined(separator: " ").suffix(400))
        }

        var turns: [SpeakerTurn] = []
        var note: String?
        if options.diarize && !texts.isEmpty {
            do {
                try await NeuralDiarizer.ensureInstalled(onProgress: progress)
                progress("Rozpoznaję głosy…")
                let wav = FileManager.default.temporaryDirectory
                    .appendingPathComponent("cw-import-\(UUID().uuidString).wav")
                let writer = try WavFileWriter(url: wav)
                writer.append(pcm)
                writer.finish()
                defer { try? FileManager.default.removeItem(at: wav) }
                turns = try await NeuralDiarizer.run(wav: wav, speakers: options.speakers)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Transkrypt bez etykiet jest wciąż wart więcej niż żaden.
                note = error.localizedDescription
            }
        }

        let labels = SpeakerTurns.label(texts, turns: turns, prefix: "Osoba", fallback: "Nagranie")
        let paragraphs = SpeakerTurns.paragraphs(texts, speakers: labels)

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let created = (attributes?[.creationDate] as? Date) ?? Date()
        let startedAt = created.timeIntervalSince1970 * 1000
        let segments = SpeakerTurns.segments(paragraphs, startedAt: startedAt)

        let meta = SessionMeta(title: url.deletingPathExtension().lastPathComponent,
                               source: "file", url: url.path,
                               startedAt: startedAt, endedAt: startedAt + seconds * 1000)
        return Result(segments: segments, meta: meta,
                      speakerCount: turns.isEmpty ? 0 : Set(labels).count, diarizationNote: note)
    }
}
