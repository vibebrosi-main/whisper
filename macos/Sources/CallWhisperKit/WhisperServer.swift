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

    /// PID-y serwerów uruchomionych przez ten proces, dostępne bez aktora,
    /// żeby `applicationWillTerminate` mogło je zgasić synchronicznie.
    nonisolated(unsafe) private static var children: Set<pid_t> = []
    private static let childrenLock = NSLock()

    /// Gasi serwery uruchomione przez ten proces. Do wywołania przy wyjściu.
    public static func terminateChildren() {
        childrenLock.withLock {
            for pid in children { kill(pid, SIGTERM) }
            children.removeAll()
        }
    }

    /// Zabija osierocone serwery z binarki call-whisper.
    ///
    /// Aplikacja zamknięta bez sprzątania (`kill`, awaria, `--snapshot`)
    /// zostawiała `whisper-server` przy życiu. Zmierzone 2026-10-05: dwa takie
    /// procesy po godzinie słuchały naraz na 8899 (whisper-server ustawia
    /// SO_REUSEPORT), każdy z własną kopią modelu wypchniętą już z pamięci.
    /// Gorzej: `ensureRunning` widział działający port i używał sieroty, więc
    /// zmiana modelu albo języka w Ustawieniach nie miała żadnego skutku.
    ///
    /// Sierota to proces naszej binarki, którego rodzicem jest już launchd.
    /// Serwer z `npm run whisper` ma żywego rodzica i nie jest ruszany.
    @discardableResult
    public static func reapOrphans() -> Int {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-Ao", "pid=,ppid=,comm="]
        let pipe = Pipe()
        ps.standardOutput = pipe
        guard (try? ps.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()

        var killed = 0
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), parts[1] == "1" else { continue }
            let path = String(parts[2])
            guard path.hasSuffix("/whisper-server"), path.lowercased().contains("call-whisper") else { continue }
            if kill(pid, SIGTERM) == 0 { killed += 1 }
        }
        return killed
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
        // Sieroty z poprzednich uruchomień najpierw, inaczej odpowiedziałyby
        // na health i zostały użyte z dawnym modelem.
        if Self.reapOrphans() > 0 { try? await Task.sleep(for: .milliseconds(400)) }
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
            // Segmenty cięte na granicy słowa, nie tokenu (patrz WhisperClient).
            "--split-on-word",
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
        _ = Self.childrenLock.withLock { Self.children.insert(task.processIdentifier) }

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
        Self.childrenLock.withLock {
            for task in processes.values {
                Self.children.remove(task.processIdentifier)
                task.terminate()
            }
        }
        processes.removeAll()
    }
}
