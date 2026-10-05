import Foundation

/// Pobieranie modeli whisper.cpp.
///
/// Bez tego pierwszym krokiem użytkownika jest ręczne `curl` po 465 MB do
/// katalogu, o którym nie ma skąd wiedzieć. To jest dokładnie ten rodzaj
/// kroku, po którym aplikacja „nie działa".
public actor ModelDownloader {
    public struct Progress: Sendable {
        public var fraction: Double
        public var receivedBytes: Int64
        public var totalBytes: Int64
    }

    public enum DownloadError: LocalizedError {
        case unknownModel(String)
        case http(Int)
        case incomplete

        public var errorDescription: String? {
            switch self {
            case .unknownModel(let name): return "Nie znam modelu \(name)."
            case .http(let status): return "Pobieranie zwróciło \(status)."
            case .incomplete: return "Pobieranie przerwane — plik jest niekompletny."
            }
        }
    }

    private static let baseURL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

    /// Rozmiary z repozytorium — do pokazania, na co się użytkownik pisze.
    public static let known: [(id: String, bytes: Int64, note: String)] = [
        ("small", 487_601_967, "domyślny, 13,3 % błędnych słów po polsku, ~930 ms"),
        ("large-v3-turbo", 1_624_555_275, "dokładniejszy: 10,0 %, ale ~1,6 s i 1,6 GB pamięci"),
        ("base", 147_951_465, "najmniejszy, wyraźnie gorszy po polsku"),
    ]

    public init() {}

    public static func isInstalled(_ model: String) -> Bool {
        FileManager.default.isReadableFile(atPath: WhisperServer.modelURL(model).path)
    }

    /// Pobiera model do `~/.cache/whisper-models`, jeśli go tam nie ma.
    ///
    /// Zadanie pobierania, a nie `URLSession.bytes`: ten drugi oddaje strumień
    /// bajt po bajcie i na 148 MB spalał 12 s czasu procesora na samą pętlę.
    public func download(_ model: String,
                         onProgress: @escaping @Sendable (Progress) -> Void) async throws {
        guard Self.known.contains(where: { $0.id == model }) else {
            throw DownloadError.unknownModel(model)
        }
        let target = WhisperServer.modelURL(model)
        if FileManager.default.isReadableFile(atPath: target.path) { return }

        try FileManager.default.createDirectory(at: WhisperServer.modelsDirectory,
                                                withIntermediateDirectories: true)

        let url = URL(string: "\(Self.baseURL)/ggml-\(model).bin")!
        let expected = Self.known.first { $0.id == model }?.bytes ?? 0
        let reporter = ProgressReporter(expected: expected, onProgress: onProgress)

        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: reporter)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            try? FileManager.default.removeItem(at: temporary)
            throw DownloadError.http(http.statusCode)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int64) ?? 0
        guard size > 1_000_000 else {
            try? FileManager.default.removeItem(at: temporary)
            throw DownloadError.incomplete
        }

        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: temporary, to: target)
        onProgress(Progress(fraction: 1, receivedBytes: size, totalBytes: expected))
    }
}

/// Postęp pobierania. Osobna klasa, bo `URLSession` chce delegata.
final class ProgressReporter: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expected: Int64
    private let onProgress: @Sendable (ModelDownloader.Progress) -> Void
    private var lastReport = Date.distantPast

    init(expected: Int64, onProgress: @escaping @Sendable (ModelDownloader.Progress) -> Void) {
        self.expected = expected
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        // Co 200 ms wystarczy — pasek postępu nie potrzebuje więcej, a każde
        // odświeżenie przechodzi na główny wątek.
        guard Date().timeIntervalSince(lastReport) > 0.2 else { return }
        lastReport = Date()
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        onProgress(ModelDownloader.Progress(
            fraction: total > 0 ? Double(totalBytesWritten) / Double(total) : 0,
            receivedBytes: totalBytesWritten,
            totalBytes: total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // Plik odbiera `download(from:)`; tutaj nic nie robimy.
    }
}
