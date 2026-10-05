import Foundation
import AppKit
import CallWhisperCore

/// Połączenie z OBS przez obs-websocket (wbudowany w OBS od wersji 28).
///
/// Prowadzi call-whisper: „Słuchaj" uruchamia OBS, jeśli nie działa, i włącza
/// w nim nagrywanie; „Zatrzymaj" je kończy i odbiera ścieżkę pliku wideo, obok
/// którego ląduje transkrypt. Działa też w drugą stronę - nagranie włączone
/// ręcznie w OBS uruchamia nasłuch (`onRecordStart` / `onRecordStop`).
///
/// Hasło i port czytamy z konfiguracji OBS. Gdy OBS nie działa, ponawiamy
/// co kilka sekund - kolejność uruchamiania programów nie ma znaczenia.
@MainActor
public final class OBSLink: ObservableObject {
    public enum State: Equatable {
        case off
        /// OBS nie działa albo nie odpowiada na porcie.
        case waiting
        /// W działającym OBS wyłączony serwer WebSocket.
        case serverDisabled
        case wrongPassword
        case connected
        case recording
    }

    public enum LinkError: LocalizedError {
        case notInstalled, serverDisabled, wrongPassword, timeout

        public var errorDescription: String? {
            switch self {
            case .notInstalled: return "Nie znaleziono OBS. Nasłuch działa bez nagrywania wideo."
            case .serverDisabled: return "W OBS włącz serwer: Narzędzia → Ustawienia serwera WebSocket → Włącz serwer WebSocket."
            case .wrongPassword: return "OBS odrzucił hasło WebSocket. Zapisz ustawienia serwera w OBS jeszcze raz."
            case .timeout: return "OBS nie odpowiedział na czas. Nasłuch działa bez nagrywania wideo."
            }
        }
    }

    @Published public private(set) var state: State = .off

    /// Nagranie włączone ręcznie w OBS; argument to chwila startu (ms epoki).
    public var onRecordStart: ((Double) -> Void)?
    /// Nagranie zatrzymane ręcznie w OBS; ścieżka pliku wideo, jeśli jest.
    public var onRecordStop: ((String?) -> Void)?

    public static let bundleID = "com.obsproject.obs-studio"

    private var socket: URLSessionWebSocketTask?
    private var retry: Timer?
    private var password: String?
    /// Kiedy zaczęło się trwające nagranie.
    private var recordingOrigin: Double?
    private var startWaiter: CheckedContinuation<Double?, Never>?
    private var stopWaiter: CheckedContinuation<String?, Never>?
    private static let statusRequestID = "cw-record-status"

    public init() {}

    public func start() {
        guard retry == nil else { return }
        state = .waiting
        connect()
        retry = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.socket == nil else { return }
                self.connect()
            }
        }
    }

    public func stop() {
        retry?.invalidate()
        retry = nil
        drop()
        state = .off
    }

    // MARK: - sterowanie nagrywaniem

    /// Uruchamia OBS (jeśli trzeba) i włącza nagrywanie. Zwraca chwilę startu
    /// nagrania, od której mają się liczyć znaczniki czasu transkryptu.
    public func startRecording() async throws -> Double {
        if retry == nil { start() }
        try await ensureConnected()
        if state == .recording, let recordingOrigin { return recordingOrigin }

        let origin: Double? = await withCheckedContinuation { continuation in
            startWaiter = continuation
            send(["op": 6, "d": ["requestType": "StartRecord", "requestId": "cw-start"]])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                self.startWaiter?.resume(returning: nil)
                self.startWaiter = nil
            }
        }
        guard let origin else { throw LinkError.timeout }
        return origin
    }

    /// Kończy nagrywanie i zwraca ścieżkę pliku wideo.
    public func stopRecording() async -> String? {
        guard state == .recording else { return nil }
        return await withCheckedContinuation { continuation in
            stopWaiter = continuation
            send(["op": 6, "d": ["requestType": "StopRecord", "requestId": "cw-stop"]])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(15))
                self.stopWaiter?.resume(returning: nil)
                self.stopWaiter = nil
            }
        }
    }

    /// Czeka na połączenie, a gdy OBS nie działa - uruchamia go.
    private func ensureConnected() async throws {
        if state == .connected || state == .recording { return }
        if state == .wrongPassword { throw LinkError.wrongPassword }

        let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        if !running {
            guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
                throw LinkError.notInstalled
            }
            // OBS jeszcze nie działa, więc możemy bezpiecznie włączyć serwer
            // w jego konfiguracji - przeczyta ją przy starcie. Na działającym
            // OBS to nic nie da, a przy zamknięciu nadpisałby plik swoją wersją.
            OBS.ServerConfig.enableServer()
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: config)
        } else if OBS.ServerConfig.load()?.enabled == false {
            throw LinkError.serverDisabled
        }

        // OBS startuje kilka sekund; serwer wstaje razem z nim.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if state == .connected || state == .recording { return }
            if state == .wrongPassword { throw LinkError.wrongPassword }
            if socket == nil { connect() }
            try? await Task.sleep(for: .milliseconds(500))
        }
        throw LinkError.timeout
    }

    // MARK: - gniazdo

    private func connect() {
        guard let config = OBS.ServerConfig.load() else {
            state = .waiting
            return
        }
        guard config.enabled else {
            let running = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
            state = running ? .serverDisabled : .waiting
            return
        }
        password = config.password
        let task = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:\(config.port)")!)
        socket = task
        task.resume()
        receive(on: task)
    }

    private func drop() {
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.socket === task else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receive(on: task)
                case .failure:
                    // Zamknięcie z kodem 4009 to złe hasło; resztę traktujemy
                    // jak „OBS jeszcze nie wstał" i ponawiamy.
                    let wasRecording = self.state == .recording
                    self.state = task.closeCode.rawValue == 4009 ? .wrongPassword : .waiting
                    self.socket = nil
                    self.recordingOrigin = nil
                    self.stopWaiter?.resume(returning: nil)
                    self.stopWaiter = nil
                    // OBS zamknięty w trakcie nagrywania też kończy nagranie.
                    if wasRecording { self.onRecordStop?(nil) }
                }
            }
        }
    }

    private func send(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        socket?.send(.string(text)) { _ in }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let op = json["op"] as? Int else { return }
        let d = json["d"] as? [String: Any] ?? [:]

        switch op {
        case 0: // Hello
            var identify: [String: Any] = ["rpcVersion": 1, "eventSubscriptions": OBS.outputsEventSubscription]
            if let auth = d["authentication"] as? [String: Any],
               let salt = auth["salt"] as? String, let challenge = auth["challenge"] as? String {
                identify["authentication"] = OBS.authentication(password: password ?? "", salt: salt, challenge: challenge)
            }
            send(["op": 1, "d": identify])
        case 2: // Identified
            state = .connected
            // Nagrywanie mogło trwać, zanim się połączyliśmy - wtedy też
            // włączamy nasłuch, z czasem cofniętym do startu nagrania.
            send(["op": 6, "d": ["requestType": "GetRecordStatus", "requestId": Self.statusRequestID]])
        case 7: // RequestResponse
            guard d["requestId"] as? String == Self.statusRequestID,
                  let response = d["responseData"] as? [String: Any],
                  response["outputActive"] as? Bool == true else { return }
            let elapsed = (response["outputDuration"] as? Double) ?? 0
            recordingStarted(at: nowMs() - elapsed)
        default:
            switch OBS.recordEvent(from: json) {
            case .started: recordingStarted(at: nowMs())
            case .stopped(let path): recordingStopped(path: path)
            case nil: break
            }
        }
    }

    private func recordingStarted(at origin: Double) {
        guard state != .recording else { return }
        state = .recording
        recordingOrigin = origin
        if let waiter = startWaiter {
            // Nagranie, o które sami poprosiliśmy.
            startWaiter = nil
            waiter.resume(returning: origin)
        } else {
            onRecordStart?(origin)
        }
    }

    private func recordingStopped(path: String?) {
        guard state == .recording else { return }
        state = .connected
        recordingOrigin = nil
        if let waiter = stopWaiter {
            stopWaiter = nil
            waiter.resume(returning: path)
        } else {
            onRecordStop?(path)
        }
    }
}
