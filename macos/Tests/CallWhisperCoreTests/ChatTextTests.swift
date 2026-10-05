import Testing
@testable import CallWhisperCore

/// Tekst do wklejenia w czat: jedna linia na wypowiedź, bez pustych.
struct ChatTextTests {
    @Test func jednaLiniaNaWypowiedz() {
        let segments = [
            Segment(id: "a", speaker: "Rozmówcy", text: "Ile to trwało?", startedAt: 0, endedAt: 0, offsetMs: 484_000, final: true),
            Segment(id: "b", speaker: "Ty", text: "  ", startedAt: 0, endedAt: 0, offsetMs: 490_000, final: true),
            Segment(id: "c", speaker: "Ty", text: "Dwa  lata\nna etacie.", startedAt: 0, endedAt: 0, offsetMs: 3_661_000, final: false),
        ]
        #expect(Markdown.chatText(segments) == "[00:08:04] Rozmówcy: Ile to trwało?\n[01:01:01] Ty: Dwa lata na etacie.")
        #expect(Markdown.chatText([]) == "")
    }
}
