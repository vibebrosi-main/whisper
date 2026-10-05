import Foundation
import CryptoKit

/// Czysta część współpracy z OBS: konfiguracja obs-websocket, uwierzytelnienie
/// protokołu v5 i nazwa pliku z transkryptem. Gniazdo siedzi w `OBSLink`.
///
/// Protokół: https://github.com/obsproject/obs-websocket/blob/master/docs/generated/protocol.md
public enum OBS {
    /// Ustawienia serwera z pliku, który OBS zapisuje sam. Czytamy je zamiast
    /// kazać przepisywać hasło do call-whisper: oba programy działają na tym
    /// samym koncie, więc plik i tak jest w zasięgu.
    public struct ServerConfig: Equatable, Sendable {
        public var enabled: Bool
        public var port: Int
        public var password: String?

        public init(enabled: Bool, port: Int, password: String?) {
            self.enabled = enabled
            self.port = port
            self.password = password
        }

        public static func parse(_ data: Data) -> ServerConfig? {
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            let authRequired = json["auth_required"] as? Bool ?? true
            let password = json["server_password"] as? String
            return ServerConfig(
                enabled: json["server_enabled"] as? Bool ?? false,
                port: json["server_port"] as? Int ?? 4455,
                password: authRequired && !(password ?? "").isEmpty ? password : nil)
        }

        public static var defaultURL: URL {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/obs-studio/plugin_config/obs-websocket/config.json")
        }

        public static func load(from url: URL = defaultURL) -> ServerConfig? {
            (try? Data(contentsOf: url)).flatMap(parse)
        }

        /// `server_enabled: true` w istniejącym pliku, reszta bez zmian.
        /// Wolno to robić tylko przy zamkniętym OBS - działający przeczytał
        /// plik przy starcie i nadpisze go przy wyjściu.
        ///
        /// Pliku, którego nie ma, celowo nie zakładamy: OBS przy pierwszym
        /// starcie sam generuje hasło, a serwer bez hasła słucha na wszystkich
        /// interfejsach, czyli dałby sterowanie OBS-em całej sieci lokalnej.
        @discardableResult
        public static func enableServer(at url: URL = defaultURL) -> Bool {
            guard let data = try? Data(contentsOf: url),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
            if json["server_enabled"] as? Bool == true { return true }
            json["server_enabled"] = true
            guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
                  (try? out.write(to: url, options: .atomic)) != nil else { return false }
            return true
        }
    }

    /// `authentication` z wiadomości Identify:
    /// base64(sha256(base64(sha256(hasło + sól)) + wyzwanie)).
    public static func authentication(password: String, salt: String, challenge: String) -> String {
        let secret = Data(SHA256.hash(data: Data((password + salt).utf8))).base64EncodedString()
        return Data(SHA256.hash(data: Data((secret + challenge).utf8))).base64EncodedString()
    }

    /// Bit subskrypcji zdarzeń wyjść (nagrywanie, stream, replay buffer).
    public static let outputsEventSubscription = 1 << 6

    /// Transkrypt ląduje obok nagrania, z tą samą nazwą: `rozmowa.mkv`
    /// -> `rozmowa.md`. Dzięki temu pliki trzymają się razem w Finderze.
    public static func transcriptURL(forRecording path: String) -> URL {
        URL(fileURLWithPath: path).deletingPathExtension().appendingPathExtension("md")
    }

    /// Stan nagrywania z `RecordStateChanged`.
    public enum RecordEvent: Equatable, Sendable {
        case started(path: String?)
        case stopped(path: String?)
    }

    /// Wyłuskuje start i stop nagrywania ze zdarzenia (op 5). Pauzę, wznowienie
    /// i stany przejściowe („starting", „stopping") pomijamy.
    public static func recordEvent(from message: [String: Any]) -> RecordEvent? {
        guard message["op"] as? Int == 5,
              let d = message["d"] as? [String: Any],
              d["eventType"] as? String == "RecordStateChanged",
              let data = d["eventData"] as? [String: Any],
              let state = data["outputState"] as? String else { return nil }
        let path = (data["outputPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch state {
        case "OBS_WEBSOCKET_OUTPUT_STARTED": return .started(path: path)
        case "OBS_WEBSOCKET_OUTPUT_STOPPED": return .stopped(path: path)
        default: return nil
        }
    }
}
