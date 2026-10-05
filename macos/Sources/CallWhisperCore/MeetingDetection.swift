import Foundation

/// Rozstrzyganie, czy właśnie trwa rozmowa — pomysł z OpenWhispr
/// (`meetingDetectionEngine`), uproszczony do tego, co da się sprawdzić
/// bez uprawnień: czy ktoś trzyma mikrofon i czy działa znany komunikator.
///
/// Sam mikrofon nie wystarcza (dyktowanie, notatka głosowa), sama aplikacja
/// też nie (Slack i Teams działają cały dzień). Dopiero oba naraz znaczą
/// rozmowę z dużym prawdopodobieństwem.
public enum MeetingDetection {
    public static let knownApps: [(bundleID: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack"),
        ("com.hnc.Discord", "Discord"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("Cisco-Systems.Spark", "Webex"),
        ("net.whatsapp.WhatsApp", "WhatsApp"),
        ("ru.keepcoder.Telegram", "Telegram"),
        ("com.skype.skype", "Skype"),
    ]

    /// Przeglądarki: Google Meet nie ma aplikacji, więc mikrofon trzymany przez
    /// przeglądarkę też liczymy — z nazwą ogólną, bo karty nie widać.
    public static let browsers: [(bundleID: String, name: String)] = [
        ("com.google.Chrome", "przeglądarce"),
        ("com.apple.Safari", "przeglądarce"),
        ("company.thebrowser.Browser", "przeglądarce"),
        ("org.mozilla.firefox", "przeglądarce"),
        ("com.microsoft.edgemac", "przeglądarce"),
        ("com.brave.Browser", "przeglądarce"),
    ]

    /// Nazwa aplikacji rozmowy albo `nil`.
    ///
    /// - Parameters:
    ///   - micInUse: czy jakikolwiek proces trzyma wejście audio
    ///   - running: bundle ID uruchomionych aplikacji
    ///   - frontmost: aplikacja na pierwszym planie — przy kilku kandydatach
    ///     ona wygrywa, bo to z nią użytkownik właśnie rozmawia
    public static func activeMeeting(micInUse: Bool, running: Set<String>,
                                     frontmost: String? = nil) -> String? {
        guard micInUse else { return nil }
        let candidates = knownApps.filter { running.contains($0.bundleID) }
        if let front = frontmost, let hit = candidates.first(where: { $0.bundleID == front }) {
            return hit.name
        }
        if let first = candidates.first { return first.name }
        if let browser = browsers.first(where: { $0.bundleID == frontmost }) { return browser.name }
        return nil
    }

    /// Histereza: mikrofon potrafi mrugnąć na ułamek sekundy (podgląd
    /// w ustawieniach, dźwięk powiadomienia). Rozmowa zaczyna się po `onAfter`
    /// kolejnych trafieniach i kończy po `offAfter` pudłach.
    public struct Debouncer: Sendable {
        public var onAfter: Int
        public var offAfter: Int
        public private(set) var active: String?
        private var hits = 0
        private var misses = 0

        public init(onAfter: Int = 2, offAfter: Int = 5) {
            self.onAfter = onAfter; self.offAfter = offAfter
        }

        public enum Change: Sendable, Equatable { case started(String), ended(String) }

        public mutating func feed(_ meeting: String?) -> Change? {
            if let meeting {
                misses = 0
                hits += 1
                if active == nil && hits >= onAfter {
                    active = meeting
                    return .started(meeting)
                }
            } else {
                hits = 0
                misses += 1
                if let current = active, misses >= offAfter {
                    active = nil
                    return .ended(current)
                }
            }
            return nil
        }
    }
}
