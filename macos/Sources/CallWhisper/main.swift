import Foundation
import AVFoundation
import CallWhisperCore
import CallWhisperKit

/// Tryb terminalowy: `call-whisper --probe [model]`.
///
/// Sprawdza klucz i model tą samą ścieżką kodu, której używa aplikacja —
/// łącznie ze strumieniowaniem SSE i pomiarem czasu do pierwszego tokenu.
/// Klucz bierze z pliku aplikacji, a jeśli go tam nie ma, ze zmiennej XPL_API_KEY.
func runProbe(model: String?) async -> Int32 {
    let settings = await MainActor.run { AppSettings.shared }
    let stored = await MainActor.run { settings.apiKey }
    let key = stored.isEmpty ? (ProcessInfo.processInfo.environment["XPL_API_KEY"] ?? "") : stored
    guard !key.isEmpty else {
        FileHandle.standardError.write(Data("Brak klucza. Ustaw go w aplikacji albo w XPL_API_KEY.\n".utf8))
        return 1
    }

    let configured = await MainActor.run { settings.modelID }
    let chosen = model ?? configured
    print("model: \(chosen)")

    let client = AssistantClient()

    // Pierwsze żądanie płaci za zestawienie połączenia TLS (~0,5 s). W aplikacji
    // klient żyje przez całą rozmowę, więc ten koszt ponosi się raz i nie ma go
    // w tym, co widzi użytkownik. Rozgrzewamy i mierzymy drugie.
    _ = await client.probe(apiKey: key, model: chosen)
    switch await client.probe(apiKey: key, model: chosen) {
    case .success(let ttft):
        print(String(format: "OK — pierwszy token po %.0f ms (ciepłe połączenie)", ttft))
        return 0
    case .failure(let error):
        FileHandle.standardError.write(Data("BŁĄD: \(error.localizedDescription)\n".utf8))
        return 2
    }
}

/// `call-whisper --set-key <klucz>` - zapisuje klucz (plik 0600) ścieżką
/// aplikacji i odczytuje go z powrotem.
func runSetKey(_ value: String) async -> Int32 {
    let ok = await MainActor.run { AppSettings.shared.setAPIKey(value) }
    guard ok else {
        FileHandle.standardError.write(Data("Nie udało się zapisać klucza w \(AppSettings.apiKeyURL.path).\n".utf8))
        return 1
    }
    let readBack = await MainActor.run { AppSettings.shared.apiKey }
    guard !readBack.isEmpty else {
        FileHandle.standardError.write(Data("Zapisano, ale odczyt zwrócił pustkę.\n".utf8))
        return 1
    }
    print("Zapisano klucz (\(readBack.count) znaków, \(readBack.prefix(4))…\(readBack.suffix(4)))")
    return 0
}

/// `call-whisper --whisper <plik.wav>` — sprawdza cały łańcuch whispera:
/// podnosi serwer, wysyła audio, drukuje rozpoznany tekst i czas.
func runWhisperCheck(path: String) async -> Int32 {
    let settings = await MainActor.run { AppSettings.shared }
    let (model, port, languageCode) = await MainActor.run {
        (settings.whisperModel, settings.whisperPort, settings.languageCode)
    }

    if WhisperServer.locateBinary() == nil {
        print("pobieram silnik mowy…")
        do { try await Engines.install(.whisperServer) } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }
    print("whisper-server: \(WhisperServer.locateBinary()?.path ?? "?")")
    let server = WhisperServer()
    do {
        let started = try await server.ensureRunning(.init(model: model, port: port,
                                                           language: languageCode))
        print(started ? "whisper-server: uruchomiony przez nas (\(model))"
                      : "whisper-server: już działał na porcie \(port)")
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        return 1
    }

    guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else {
        FileHandle.standardError.write(Data("Nie mogę otworzyć \(path)\n".utf8))
        return 1
    }
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                               channels: 1, interleaved: false)!
    guard let converter = AVAudioConverter(from: file.processingFormat, to: target),
          let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length)),
          (try? file.read(into: input)) != nil,
          let out = AVAudioPCMBuffer(pcmFormat: target,
                                     frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 4096)
    else {
        FileHandle.standardError.write(Data("Nie mogę przekonwertować audio\n".utf8))
        return 1
    }
    guard convertOnce(converter, input: input, into: out), let channel = out.floatChannelData?[0] else {
        FileHandle.standardError.write(Data("Konwersja nie powiodła się\n".utf8))
        return 1
    }
    let pcm = Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    print(String(format: "audio: %.2f s, %d próbek @16 kHz", Double(pcm.count) / 16_000, pcm.count))

    let client = WhisperClient(endpoint: URL(string: "http://127.0.0.1:\(port)")!,
                               language: languageCode)
    let started = Date()
    do {
        let text = try await client.transcribe(pcm)
        let ms = Date().timeIntervalSince(started) * 1000
        print(String(format: "round-trip: %.0f ms", ms))
        print("tekst: \(text)")
        await server.stop()
        return text.isEmpty ? 3 : 0
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        await server.stop()
        return 2
    }
}

/// `call-whisper --listen [sekundy]` — pełny łańcuch bez interfejsu.
///
/// Przechwytywanie systemu, diaryzacja i transkrypcja, a na końcu gotowy
/// Markdown na stdout. Służy do sprawdzenia, czy problem leży w łańcuchu, czy
/// w interfejsie — i do zapisu rozmowy z terminala.
@MainActor
func runListen(seconds: Double) async -> Int32 {
    let recorder = Recorder()
    await recorder.start()

    guard recorder.isRunning else {
        FileHandle.standardError.write(Data("Nie wystartowało: \(recorder.lastError ?? "nieznany powód")\n".utf8))
        return 1
    }
    FileHandle.standardError.write(Data("\(recorder.status) — słucham \(Int(seconds)) s…\n".utf8))

    let deadline = Date().addingTimeInterval(seconds)
    var lastCount = -1
    while Date() < deadline {
        try? await Task.sleep(for: .milliseconds(500))
        if recorder.segments.count != lastCount {
            lastCount = recorder.segments.count
            if let last = recorder.segments.last {
                FileHandle.standardError.write(Data("  [\(TimeFormat.offset(last.offsetMs))] \(last.speaker): \(last.text)\n".utf8))
            }
        }
        if let error = recorder.lastError {
            FileHandle.standardError.write(Data("  ! \(error)\n".utf8))
        }
    }

    let stopStarted = Date()
    await recorder.stop()
    FileHandle.standardError.write(Data(
        String(format: "zatrzymanie: %.0f ms\n", Date().timeIntervalSince(stopStarted) * 1000).utf8))
    print(recorder.markdown)
    return recorder.segments.isEmpty ? 3 : 0
}

/// `call-whisper --ask "pytanie"` — sprawdza most do Claude Code tą samą
/// ścieżką kodu, której używa aplikacja. Bez klucza API.
func runAsk(_ question: String) async -> Int32 {
    guard ClaudeBridge.isAvailable else {
        FileHandle.standardError.write(Data("Nie znalazłem CLI `claude`.\n".utf8))
        return 1
    }
    let model = await MainActor.run { AppSettings.shared.claudeModel }
    let bridge = ClaudeBridge()
    do {
        try await bridge.start(model: model)
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        return 1
    }

    print("rozgrzewam most…")
    let warmStart = Date()
    let warm = await bridge.warmup()
    print(String(format: "  zimny start: %.0f ms (%@)", Date().timeIntervalSince(warmStart) * 1000,
                 warm ? "ok" : "nieudany"))

    let started = Date()
    // Domknięcie strumienia jest `@Sendable`, więc licznik musi być bezpieczny.
    final class Stamp: @unchecked Sendable { var ttft: Double? }
    let stamp = Stamp()
    do {
        let answer = try await bridge.ask(question) { _ in
            if stamp.ttft == nil { stamp.ttft = Date().timeIntervalSince(started) * 1000 }
        }
        print(String(format: "  pierwszy token: %.0f ms, całość: %.0f ms",
                     stamp.ttft ?? 0, Date().timeIntervalSince(started) * 1000))
        print("odpowiedź: \(answer)")
        await bridge.stop()
        return 0
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        await bridge.stop()
        return 2
    }
}

/// `call-whisper --fetch-model <nazwa>` — pobiera model whispera z postępem.
func runFetchModel(_ model: String) async -> Int32 {
    if ModelDownloader.isInstalled(model) {
        print("Model \(model) już jest w \(WhisperServer.modelsDirectory.path)")
        return 0
    }
    let downloader = ModelDownloader()
    do {
        try await downloader.download(model) { p in
            let line = String(format: "\r  %.0f%%  %.0f/%.0f MB",
                              p.fraction * 100,
                              Double(p.receivedBytes) / 1e6, Double(p.totalBytes) / 1e6)
            FileHandle.standardError.write(Data(line.utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))
        let size = (try? FileManager.default.attributesOfItem(
            atPath: WhisperServer.modelURL(model).path)[.size] as? Int64) ?? 0
        print(String(format: "Pobrano %@ — %.1f MB", model, Double(size) / 1e6))
        return 0
    } catch {
        FileHandle.standardError.write(Data("\n\(error.localizedDescription)\n".utf8))
        return 1
    }
}

/// `call-whisper --ask-seq` — pięć kolejnych pytań przez most, z pomiarem.
///
/// Sprawdza, czy pula świeżych sesji trzyma czas. Jeden proces na całą rozmowę
/// kumulował historię CLI i piąte pytanie kosztowało 6107 ms zamiast 1727 ms.
func runAskSequence() async -> Int32 {
    guard ClaudeBridge.isAvailable else {
        FileHandle.standardError.write(Data("Nie znalazłem CLI `claude`.\n".utf8))
        return 1
    }
    func mark(_ m: String) { FileHandle.standardError.write(Data("[seq] \(m)\n".utf8)) }

    let claudeModel = await MainActor.run { AppSettings.shared.claudeModel }
    let bridge = ClaudeBridge()
    try? await bridge.start(model: claudeModel)
    mark("rozgrzewam pierwszą sesję…")
    _ = await bridge.warmup()
    mark("rozgrzana")

    let context = """
    Spotkanie: rozmowa

    Ostatnie wypowiedzi:
    Rozmówcy: To jest fragment transkrypcji, w którym pada sporo treści o obozie, historii i liczbach.
    Rozmówcy: Kolejne zdanie kontekstu, żeby prompt miał realistyczną długość.

    Pytanie, na które masz odpowiedzieć:

    """
    let questions = [
        "Czym było Auschwitz-Birkenau?",
        "Ile osób tam zginęło?",
        "Kiedy obóz został wyzwolony?",
        "Co to był blok numer 11?",
        "Czym różni się Auschwitz I od Birkenau?",
    ]

    final class Stamp: @unchecked Sendable { var ttft: Double? }
    for (i, question) in questions.enumerated() {
        let started = Date()
        let stamp = Stamp()
        do {
            let answer = try await bridge.ask(context + question) { _ in
                if stamp.ttft == nil { stamp.ttft = Date().timeIntervalSince(started) * 1000 }
            }
            mark(String(format: "pytanie %d: pierwszy token %4.0f ms, całość %4.0f ms, %d znaków",
                        i + 1, stamp.ttft ?? 0, Date().timeIntervalSince(started) * 1000, answer.count))
        } catch {
            mark("pytanie \(i + 1): BŁĄD — \(error.localizedDescription)")
        }
    }
    await bridge.stop()
    return 0
}

/// `call-whisper --ask-image <plik> "pytanie"` — sprawdza dołączanie obrazka
/// tą samą ścieżką kodu, którą używa wklejanie Cmd+V w oknie.
func runAskImage(path: String, question: String) async -> Int32 {
    guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        FileHandle.standardError.write(Data("Nie mogę wczytać \(path)\n".utf8))
        return 1
    }
    let image = await MainActor.run { AssistantImage.downscaled(raw) }
        ?? AssistantImage(data: raw, mediaType: "image/png")
    print("obrazek: \(raw.count) B na wejściu -> \(image.data.count) B po przeskalowaniu (\(image.sizeDescription))")

    let bridge = ClaudeBridge()
    try? await bridge.start(model: await MainActor.run { AppSettings.shared.claudeModel })
    _ = await bridge.warmup()

    final class Stamp: @unchecked Sendable { var ttft: Double? }
    let stamp = Stamp()
    let started = Date()
    do {
        let answer = try await bridge.ask(question, image: image, timeout: 120) { _ in
            if stamp.ttft == nil { stamp.ttft = Date().timeIntervalSince(started) * 1000 }
        }
        print(String(format: "pierwszy token: %.0f ms, całość: %.0f ms",
                     stamp.ttft ?? 0, Date().timeIntervalSince(started) * 1000))
        print("odpowiedź: \(answer)")
        await bridge.stop()
        return answer.isEmpty ? 2 : 0
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        await bridge.stop()
        return 2
    }
}

/// `call-whisper --install-engines <katalog> [składniki…]` — pobiera silniki
/// do wskazanego katalogu. `bundle.sh` wkłada tak `whisper-server` do `.app`,
/// więc adresy i sumy kontrolne mieszkają w jednym miejscu (`Engines`).
func runInstallEngines(root: String, names: [String]) async -> Int32 {
    let components = names.isEmpty ? [Engines.Component.whisperServer]
                                   : names.compactMap(Engines.Component.init(rawValue:))
    guard components.count == max(1, names.count) else {
        let known = Engines.Component.allCases.map(\.rawValue).joined(separator: ", ")
        FileHandle.standardError.write(Data("Nieznany składnik. Dostępne: \(known)\n".utf8))
        return 1
    }
    for component in components {
        do {
            try await Engines.install(component, into: URL(fileURLWithPath: root)) { fraction in
                FileHandle.standardError.write(Data(String(format: "\r  %@: %.0f%%", component.rawValue, fraction * 100).utf8))
            }
            FileHandle.standardError.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("\n\(component.rawValue): \(error.localizedDescription)\n".utf8))
            return 2
        }
    }
    return 0
}

/// `call-whisper --diarize <plik.wav> [liczba osób]` — same tury mówców.
func runDiarize(path: String, speakers: Int?) async -> Int32 {
    do {
        try await NeuralDiarizer.ensureInstalled { FileHandle.standardError.write(Data("\r\($0)".utf8)) }
        let started = Date()
        let turns = try await NeuralDiarizer.run(wav: URL(fileURLWithPath: path), speakers: speakers)
        for turn in turns { print(String(format: "%7.2f -- %7.2f  %@", turn.start, turn.end, turn.cluster)) }
        FileHandle.standardError.write(Data(String(format: "\n%d tur, %d głosów, %.1f s\n", turns.count,
                                                   Set(turns.map(\.cluster)).count,
                                                   Date().timeIntervalSince(started)).utf8))
        return turns.isEmpty ? 3 : 0
    } catch {
        FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
        return 1
    }
}

/// `call-whisper --import <nagranie|wideo> [--speakers auto|N]` —
/// import z terminala, Markdown na stdout. Odpowiednik `openwhispr-video
/// import` z whistlera, tyle że bez działającej aplikacji w tle.
func runImport(path: String, diarize: Bool, speakers: Int?) async -> Int32 {
    let (model, port, languageCode) = await MainActor.run {
        (AppSettings.shared.whisperModel, AppSettings.shared.whisperPort, AppSettings.shared.languageCode)
    }
    @Sendable func log(_ message: String) { FileHandle.standardError.write(Data("\(message)\n".utf8)) }

    if WhisperServer.locateBinary() == nil {
        log("pobieram silnik mowy…")
        do { try await Engines.install(.whisperServer) } catch { log(error.localizedDescription); return 1 }
    }
    if !ModelDownloader.isInstalled(model) {
        log("pobieram model \(model)…")
        do { try await ModelDownloader().download(model) { _ in } } catch { log(error.localizedDescription); return 1 }
    }
    let server = WhisperServer()
    do {
        try await server.ensureRunning(.init(model: model, port: port, language: languageCode))
    } catch {
        log(error.localizedDescription)
        return 1
    }

    let started = Date()
    do {
        let result = try await MediaImport.run(URL(fileURLWithPath: path),
                                               options: .init(whisperPort: port, language: languageCode,
                                                              diarize: diarize, speakers: speakers)) { log($0) }
        await server.stop()
        if let note = result.diarizationNote { log("bez podziału na głosy: \(note)") }
        log(String(format: "gotowe w %.1f s: %d wypowiedzi, %d głosów", Date().timeIntervalSince(started),
                   result.segments.count, result.speakerCount))
        print(Markdown.render(Session(meta: result.meta, segments: result.segments)))
        return result.segments.isEmpty ? 3 : 0
    } catch {
        await server.stop()
        log(error.localizedDescription)
        return 2
    }
}

let arguments = CommandLine.arguments
func flagValue(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), arguments.count > i + 1 else { return nil }
    return arguments[i + 1]
}
if let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 1 {
    let file = arguments.count > index + 2 ? arguments[index + 2] : nil
    exit(await runSnapshot(directory: arguments[index + 1], file: file))
}
if let index = arguments.firstIndex(of: "--install-engines"), arguments.count > index + 1 {
    exit(await runInstallEngines(root: arguments[index + 1], names: Array(arguments[(index + 2)...])))
}
if let path = flagValue("--diarize") {
    exit(await runDiarize(path: path, speakers: flagValue("--speakers").flatMap(Int.init)))
}
if let path = flagValue("--import") {
    // `--speakers auto` włącza diaryzację bez podawania liczby osób.
    exit(await runImport(path: path, diarize: flagValue("--speakers") != nil,
                         speakers: flagValue("--speakers").flatMap(Int.init)))
}
if arguments.contains("--ask-seq") { exit(await runAskSequence()) }
if let i = arguments.firstIndex(of: "--ask-image"), arguments.count > i + 2 {
    exit(await runAskImage(path: arguments[i + 1], question: arguments[i + 2]))
}
if let index = arguments.firstIndex(of: "--fetch-model"), arguments.count > index + 1 {
    exit(await runFetchModel(arguments[index + 1]))
}
if let index = arguments.firstIndex(of: "--ask"), arguments.count > index + 1 {
    exit(await runAsk(arguments[index + 1]))
}
if let index = arguments.firstIndex(of: "--listen") {
    let seconds = arguments.count > index + 1 ? (Double(arguments[index + 1]) ?? 20) : 20
    exit(await runListen(seconds: seconds))
}
if let index = arguments.firstIndex(of: "--whisper"), arguments.count > index + 1 {
    exit(await runWhisperCheck(path: arguments[index + 1]))
}
if let index = arguments.firstIndex(of: "--set-key"), arguments.count > index + 1 {
    exit(await runSetKey(arguments[index + 1]))
}
if let index = arguments.firstIndex(of: "--probe") {
    let model = arguments.count > index + 1 && !arguments[index + 1].hasPrefix("-")
        ? arguments[index + 1] : nil
    exit(await runProbe(model: model))
}

CallWhisperApp.main()

