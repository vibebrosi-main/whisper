import Foundation
import CoreGraphics
import AVFoundation

/// Czego aplikacja potrzebuje, żeby w ogóle zadziałać — i co z tego potrafi
/// załatwić sama.
///
/// Istnieje po to, żeby użytkownik nie dowiadywał się o brakach z komunikatu
/// błędu w pasku stanu po kliknięciu „Słuchaj".
public struct Readiness: Sendable {
    public struct Check: Sendable, Identifiable {
        public var id: String
        public var title: String
        public var ok: Bool
        /// `nil` znaczy: tego nie da się naprawić z aplikacji.
        public var fix: Fix?
        public var detail: String

        public enum Fix: Sendable, Equatable {
            case openScreenRecordingSettings
            case downloadEngine(Engines.Component)
            case downloadModel(String)
            case installClaudeCode
        }
    }

    public var checks: [Check]
    public var canRecord: Bool { checks.first { $0.id == "screen" }?.ok ?? false }
    public var canTranscribe: Bool {
        (checks.first { $0.id == "whisper" }?.ok ?? false) && (checks.first { $0.id == "model" }?.ok ?? false)
    }
    public var allGood: Bool { checks.allSatisfy(\.ok) }

    public static func check(model: String, backend: AssistantBackend, diarize: Bool = false) -> Readiness {
        var checks: [Check] = []

        checks.append(Check(
            id: "screen",
            title: "Zgoda na nagrywanie ekranu",
            ok: CGPreflightScreenCaptureAccess(),
            fix: .openScreenRecordingSettings,
            detail: "Dźwięk systemowy wychodzi w macOS przez ScreenCaptureKit, więc zgoda jest wymagana, choć obrazu nie dotykamy."
        ))

        // Silnik nie blokuje startu: brakujący aplikacja pobiera sama (1,3 MB),
        // tak samo jak model. Pokazujemy go, żeby było wiadomo, skąd pauza.
        let whisper = WhisperServer.locateBinary()
        checks.append(Check(
            id: "whisper",
            title: "Silnik mowy (whisper.cpp)",
            ok: whisper != nil,
            fix: whisper == nil ? .downloadEngine(.whisperServer) : nil,
            detail: whisper.map { $0.path.contains("homebrew") || $0.path.hasPrefix("/usr/local")
                ? "Z Homebrew. Działa, ale aplikacja ma już własny — brew nie jest potrzebny."
                : "Wbudowany." }
                ?? "Aplikacja pobierze go sama przy pierwszym nasłuchu (1,3 MB)."
        ))

        let hasModel = ModelDownloader.isInstalled(model)
        checks.append(Check(
            id: "model",
            title: "Model mowy (\(model))",
            ok: hasModel,
            fix: hasModel ? nil : .downloadModel(model),
            detail: hasModel ? "Pobrany." : "Aplikacja pobierze go sama przy pierwszym nasłuchu."
        ))

        if diarize {
            let ready = Engines.canDiarize
            let mb = Int((Engines.downloadBytes(.diarizer) + Engines.downloadBytes(.diarizationModels)) / 1_000_000)
            checks.append(Check(
                id: "diarization",
                title: "Rozpoznawanie głosów",
                ok: ready,
                fix: ready ? nil : .downloadEngine(.diarizer),
                detail: ready ? "Zainstalowane (pyannote + CAM++)."
                              : "Pobierze się samo po pierwszej rozmowie (~\(mb) MB) albo teraz."
            ))
        }

        if backend == .claudeCode {
            let hasCLI = ClaudeBridge.isAvailable
            checks.append(Check(
                id: "claude",
                title: "Claude Code (podpowiedzi)",
                ok: hasCLI,
                fix: hasCLI ? nil : .installClaudeCode,
                detail: hasCLI ? "Znaleziony — podpowiedzi bez klucza API."
                               : "Bez niego wyłącz podpowiedzi albo przełącz się na API z kluczem."
            ))
        }

        return Readiness(checks: checks)
    }

    /// Prosi system o zgodę na nagrywanie ekranu. Za pierwszym razem pokazuje
    /// systemowy monit; potem trzeba już iść w Ustawienia.
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    public static var screenRecordingSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    }

    public static let claudeInstallURL = URL(string: "https://claude.com/claude-code")!
}
