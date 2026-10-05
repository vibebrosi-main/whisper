import Testing
import Foundation
@testable import CallWhisperCore

/// Współpraca z OBS: pomyłka w haśle kończy się cichym „czekam na OBS",
/// a w zdarzeniach - transkryptem, który nigdy nie powstaje.
struct OBSTests {
    @Test func uwierzytelnienieZgadzaSieZNode() {
        // Wartość policzona niezależnie przez node:crypto, tym samym wzorem.
        let auth = OBS.authentication(password: "supersecret",
                                      salt: "lM1GncleQOaCu9lT1yeUZhFYnqhsLLP1G5lAGo3ixaI=",
                                      challenge: "+IxH4CnCiqpX1rM9scsNynZzbOe4KhDeYcTNS3PDaeY=")
        #expect(auth == "sQBlPUYd9mki/3XVFBp4Pt08FCMWdMVIqnFWdEitUME=")
    }

    @Test func konfiguracjaZPlikuOBS() {
        let json = #"{"alerts_enabled":false,"auth_required":true,"first_load":false,"server_enabled":true,"server_password":"abc","server_port":4456}"#
        #expect(OBS.ServerConfig.parse(Data(json.utf8)) == .init(enabled: true, port: 4456, password: "abc"))

        // Bez wymaganego hasła nie wysyłamy go wcale.
        let open = #"{"auth_required":false,"server_enabled":false,"server_password":"abc","server_port":4455}"#
        #expect(OBS.ServerConfig.parse(Data(open.utf8)) == .init(enabled: false, port: 4455, password: nil))
        #expect(OBS.ServerConfig.parse(Data("nie json".utf8)) == nil)
    }

    @Test func wlaczenieSerweraZostawiaResztePliku() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("obs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"auth_required":true,"server_enabled":false,"server_password":"abc","server_port":4455,"alerts_enabled":false}"#.utf8).write(to: url)

        #expect(OBS.ServerConfig.enableServer(at: url))
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        #expect(json["server_enabled"] as? Bool == true)
        #expect(json["server_password"] as? String == "abc")
        #expect(json["alerts_enabled"] as? Bool == false)

        // Brak pliku: nic nie zakładamy.
        let missing = url.deletingLastPathComponent().appendingPathComponent("brak-\(UUID().uuidString).json")
        #expect(!OBS.ServerConfig.enableServer(at: missing))
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    @Test func transkryptObokNagrania() {
        #expect(OBS.transcriptURL(forRecording: "/Users/x/Movies/2026-10-05 22-30-00.mkv").path
                == "/Users/x/Movies/2026-10-05 22-30-00.md")
    }

    @Test func zdarzeniaNagrywania() {
        func event(_ state: String, _ path: String?) -> [String: Any] {
            var data: [String: Any] = ["outputActive": state.hasSuffix("STARTED"), "outputState": state]
            if let path { data["outputPath"] = path }
            return ["op": 5, "d": ["eventType": "RecordStateChanged", "eventIntent": 64, "eventData": data]]
        }
        #expect(OBS.recordEvent(from: event("OBS_WEBSOCKET_OUTPUT_STARTED", "/a.mkv")) == .started(path: "/a.mkv"))
        #expect(OBS.recordEvent(from: event("OBS_WEBSOCKET_OUTPUT_STOPPED", "/a.mkv")) == .stopped(path: "/a.mkv"))
        #expect(OBS.recordEvent(from: event("OBS_WEBSOCKET_OUTPUT_STOPPED", "")) == .stopped(path: nil))
        #expect(OBS.recordEvent(from: event("OBS_WEBSOCKET_OUTPUT_STOPPING", nil)) == nil)
        #expect(OBS.recordEvent(from: event("OBS_WEBSOCKET_OUTPUT_PAUSED", nil)) == nil)
        #expect(OBS.recordEvent(from: ["op": 5, "d": ["eventType": "StreamStateChanged", "eventData": [:]]]) == nil)
    }
}
