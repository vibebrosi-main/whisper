import Testing
@testable import CallWhisperCore

/// Logika przeniesiona z OpenWhispr/whistler: diaryzacja neuronowa,
/// wykrywanie rozmów, import nagrań.
@Suite struct SpeakerTurnsTests {
    // Prawdziwe wyjście sherpa-onnx, łącznie z liniami, których nie chcemy.
    let output = """
    Started
    0.318 -- 6.865 speaker_00
    7.017 -- 10.747 speaker_01
    11.455 -- 13.632 speaker_01
    Duration : 56.861 s
    Elapsed seconds: 2.979 s
    """

    @Test func parsujeTylkoTury() {
        let turns = SpeakerTurns.parse(output)
        #expect(turns.count == 3)
        #expect(turns[0] == SpeakerTurn(start: 0.318, end: 6.865, cluster: "speaker_00"))
        #expect(turns[2].cluster == "speaker_01")
    }

    @Test func wygrywaNajdluzszePokrycie() {
        let turns = SpeakerTurns.parse(output)
        // 6,0-8,0: speaker_00 pokrywa 0,865 s, speaker_01 0,983 s.
        #expect(SpeakerTurns.dominantCluster(start: 6.0, end: 8.0, in: turns) == "speaker_01")
        #expect(SpeakerTurns.dominantCluster(start: 1, end: 2, in: turns) == "speaker_00")
        #expect(SpeakerTurns.dominantCluster(start: 30, end: 31, in: turns) == nil)
    }

    @Test func numeracjaWKolejnosciOdezwania() {
        // Klaster o wyższym numerze odzywa się pierwszy — ma dostać „1".
        let turns = [SpeakerTurn(start: 0, end: 5, cluster: "speaker_07"),
                     SpeakerTurn(start: 5, end: 9, cluster: "speaker_02"),
                     SpeakerTurn(start: 9, end: 12, cluster: "speaker_07")]
        let texts = [TimedText(start: 0.5, end: 4, text: "a"),
                     TimedText(start: 5.5, end: 8, text: "b"),
                     TimedText(start: 9.5, end: 11, text: "c"),
                     // Poza turami: dostaje najbliższy klaster, nie etykietę zapasową.
                     TimedText(start: 13, end: 14, text: "d")]
        let labels = SpeakerTurns.label(texts, turns: turns, prefix: "Osoba", fallback: "Nagranie")
        #expect(labels == ["Osoba 1", "Osoba 2", "Osoba 1", "Osoba 1"])
    }

    @Test func bezTurEtykietaZapasowa() {
        let texts = [TimedText(start: 0, end: 1, text: "a")]
        #expect(SpeakerTurns.label(texts, turns: [], prefix: "Osoba", fallback: "Nagranie") == ["Nagranie"])
    }

    @Test func sklejaAkapityTejSamejOsoby() {
        let texts = [TimedText(start: 0, end: 2, text: " Cześć."),
                     TimedText(start: 2.5, end: 4, text: "Zaczynamy."),
                     TimedText(start: 4.2, end: 6, text: "Hej."),
                     TimedText(start: 20, end: 22, text: "Po przerwie.")]
        let speakers = ["Osoba 1", "Osoba 1", "Osoba 2", "Osoba 2"]
        let paragraphs = SpeakerTurns.paragraphs(texts, speakers: speakers)
        #expect(paragraphs.count == 3)
        #expect(paragraphs[0].item.text == "Cześć. Zaczynamy.")
        #expect(paragraphs[0].item.end == 4)
        #expect(paragraphs[2].item.text == "Po przerwie.")

        let segments = SpeakerTurns.segments(paragraphs, startedAt: 1_000_000)
        #expect(segments[1].offsetMs == 4200)
        #expect(segments[1].startedAt == 1_004_200)
        #expect(segments.allSatisfy { $0.final })
    }

    @Test func relabelNieRuszaMikrofonu() {
        let base = 1_000_000.0
        func seg(_ id: String, _ speaker: String, _ at: Double, _ len: Double) -> Segment {
            Segment(id: id, speaker: speaker, text: id, startedAt: base + at * 1000,
                    endedAt: base + (at + len) * 1000, offsetMs: at * 1000, final: true)
        }
        let segments = [seg("a", "Rozmówcy", 0, 3), seg("b", "Ty", 3, 2),
                        seg("c", "Rozmówcy", 6, 3), seg("d", "Rozmówcy", 10, 2)]
        let turns = [SpeakerTurn(start: 0, end: 3, cluster: "speaker_00"),
                     SpeakerTurn(start: 6, end: 9, cluster: "speaker_01"),
                     SpeakerTurn(start: 10, end: 12, cluster: "speaker_00")]
        let out = SpeakerTurns.relabel(segments, turns: turns, where: SpeakerTurns.isSystemLabel, prefix: "Rozmówca")
        #expect(out.map(\.speaker) == ["Rozmówca 1", "Ty", "Rozmówca 2", "Rozmówca 1"])
    }

    @Test func relabelJednegoGlosuZostawiaEtykiete() {
        let segments = [Segment(id: "a", speaker: "Rozmówcy", text: "a", startedAt: 0, endedAt: 2000, offsetMs: 0, final: true)]
        let turns = [SpeakerTurn(start: 0, end: 2, cluster: "speaker_00")]
        #expect(SpeakerTurns.relabel(segments, turns: turns, where: SpeakerTurns.isSystemLabel, prefix: "Rozmówca")[0].speaker == "Rozmówcy")
    }
}

@Suite struct MeetingDetectionTests {
    @Test func potrzebaMikrofonuIAplikacji() {
        #expect(MeetingDetection.activeMeeting(micInUse: false, running: ["us.zoom.xos"]) == nil)
        #expect(MeetingDetection.activeMeeting(micInUse: true, running: []) == nil)
        #expect(MeetingDetection.activeMeeting(micInUse: true, running: ["us.zoom.xos"]) == "Zoom")
    }

    @Test func pierwszyPlanWygrywa() {
        let running: Set = ["com.tinyspeck.slackmacgap", "com.microsoft.teams2"]
        #expect(MeetingDetection.activeMeeting(micInUse: true, running: running,
                                               frontmost: "com.microsoft.teams2") == "Microsoft Teams")
    }

    @Test func przegladarkaTylkoNaPierwszymPlanie() {
        #expect(MeetingDetection.activeMeeting(micInUse: true, running: ["com.google.Chrome"],
                                               frontmost: "com.google.Chrome") == "przeglądarce")
        #expect(MeetingDetection.activeMeeting(micInUse: true, running: ["com.google.Chrome"],
                                               frontmost: "com.apple.finder") == nil)
    }

    @Test func histereza() {
        var d = MeetingDetection.Debouncer(onAfter: 2, offAfter: 3)
        #expect(d.feed("Zoom") == nil)
        #expect(d.feed(nil) == nil)            // mrugnięcie zeruje licznik
        #expect(d.feed("Zoom") == nil)
        #expect(d.feed("Zoom") == .started("Zoom"))
        #expect(d.feed("Zoom") == nil)
        #expect(d.feed(nil) == nil)
        #expect(d.feed(nil) == nil)
        #expect(d.feed(nil) == .ended("Zoom"))
        #expect(d.active == nil)
    }
}
