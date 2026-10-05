import Foundation

/// Uruchamia i pilnuje lokalnego `whisper-server`.
///
/// W wersji webowej to był osobny krok (`npm run whisper`) — rozszerzenie
/// Chrome nie może uruchomić procesu. Aplikacja natywna może, więc robi to
/// sama: jeden proces mniej do pamiętania.
///
/// Model zostaje w pamięci między żądaniami. To ta sama lekcja, co przy moście
/// do Claude Code: `whisper-cli` płaci ~400 ms na wczytanie modelu przy każdym
/// uruchomieniu, ciepły serwer nie płaci nic.
public actor WhisperServer {
    public struct Config: Sendable {
        public var model: String
        public var port: Int
        public var language: String
        public var threads: Int

        public init(model: String = "small", port: Int = 8899, language: String = "pl", threads: Int = 8) {
            self.model = model; self.port = port; self.language = language; self.threads = threads
        }
    }

    public enum ServerError: LocalizedError {
        case binaryMissing
        case modelMissing(String, URL)
        case didNotStart(String)

        public var errorDescription: String? {
            switch self {
            case .binaryMissing:
                return "Brak silnika mowy (whisper-server). Aplikacja pobiera go sama przy pierwszym nasłuchu — sprawdź połączenie z siecią."
            case .modelMissing(let model, let url):
                return "Brak modelu ggml-\(model).bin w \(url.path). Pobierz go z huggingface.co/ggerganov/whisper.cpp"
            case .didNotStart(let detail):
                return "whisper-server nie wystartował: \(detail)"
            }
        }
    }

    /// Logi serwerów — jeden plik na port.
    public static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/call-whisper")
    }

    public static var modelsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/whisper-models")
    }

    /// Gdzie jest `whisper-server`: w `.app`, w Application Support albo
    /// (zapasowo) w Homebrew — patrz `Engines`.
    public static func locateBinary() -> URL? { Engines.whisperServer }

    public static func modelURL(_ model: String) -> URL {
        modelsDirectory.appendingPathComponent("ggml-\(model).bin")
    }

    public static func installedModels() -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: modelsDirectory.path)) ?? []
        return contents
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") && !$0.contains("silero") }
            .map { String($0.dropFirst(5).dropLast(4)) }
            .sorted()
    }

    /// Procesy per port — bo model dokładny chodzi obok szybkiego.
    private var processes: [Int: Process] = [:]

    public init() {}

    public var runningPorts: [Int] { processes.filter { $0.value.isRunning }.map(\.key).sorted() }

    /// Startuje serwer, jeśli jeszcze nie odpowiada. Czeka, aż zacznie odpowiadać.
    @discardableResult
    public func ensureRunning(_ config: Config) async throws -> Bool {
        let client = WhisperClient(endpoint: URL(string: "http://127.0.0.1:\(config.port)")!,
                                   language: config.language)
        // Ktoś mógł już uruchomić serwer ręcznie (`npm run whisper`) — wtedy
        // nie zakładamy drugiego na tym samym porcie.
        if await client.health() { return false }

        guard let binary = Self.locateBinary() else { throw ServerError.binaryMissing }
        let model = Self.modelURL(config.model)
        guard FileManager.default.isReadableFile(atPath: model.path) else {
            throw ServerError.modelMissing(config.model, Self.modelsDirectory)
        }

        let task = Process()
        task.executableURL = binary
        task.arguments = [
            "--model", model.path,
            "--port", String(config.port),
            "--host", "127.0.0.1",
            "--language", config.language,
            "--threads", String(config.threads),
        ]
        // Wyjście serwera idzie do pliku, nie do potoku.
        //
        // Potok, którego nikt nie czyta, ma 64 kB bufora — po jego zapełnieniu
        // proces potomny **blokuje się na zapisie i przestaje odpowiadać**.
        // whisper-server loguje każde żądanie, więc przy transkrypcji co 1,2 s
        // dochodzi do tego w kilkadziesiąt sekund. Wyglądało to na padnięcie
        // serwera w połowie rozmowy.
        let logURL = Self.logDirectory.appendingPathComponent("whisper-\(config.port).log")
        try? FileManager.default.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            task.standardOutput = handle
            task.standardError = handle
        }

        do { try task.run() } catch {
            throw ServerError.didNotStart(error.localizedDescription)
        }
        processes[config.port] = task

        // Wczytanie modelu `small` zajmuje ~1 s, ale statyczny build
        // z OpenWhispr kompiluje przy starcie wbudowane shadery Metal (zmierzone
        // 7,5-9 s), a `large-v3-turbo` ładuje się dłużej. Stąd 45 s zapasu;
        // co 250 ms sprawdzamy, czy proces w międzyczasie nie padł.
        for _ in 0..<180 {
            if await client.health() { return true }
            if !task.isRunning {
                let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
                throw ServerError.didNotStart(String(output.suffix(200)))
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        // Nie zostawiamy sieroty: proces, który nie wstał, i tak trzymałby port.
        task.terminate()
        processes[config.port] = nil
        throw ServerError.didNotStart("brak odpowiedzi po 45 s")
    }

    /// Zatrzymujemy tylko procesy, które sami uruchomiliśmy — serwer
    /// podniesiony ręcznie ma prawo żyć dalej.
    public func stop() {
        for task in processes.values { task.terminate() }
        processes.removeAll()
    }
}
