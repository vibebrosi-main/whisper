import Foundation

/// Tura mówcy z diaryzacji: przedział w sekundach i surowa etykieta klastra.
public struct SpeakerTurn: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var cluster: String
    public init(start: Double, end: Double, cluster: String) {
        self.start = start; self.end = end; self.cluster = cluster
    }
}

/// Fragment tekstu z osią czasu w sekundach (od początku nagrania).
public struct TimedText: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

/// Łączenie wyniku diaryzacji z transkrypcją.
///
/// Diaryzacja (pyannote + CAM++ przez sherpa-onnx, podejście z OpenWhispr)
/// i whisper liczą granice niezależnie, więc granice tur i segmentów tekstu
/// prawie nigdy się nie pokrywają. Etykietę dostaje ten klaster, który
/// pokrywa fragment tekstu najdłużej — nie ten, który był pierwszy.
public enum SpeakerTurns {
    /// Parsuje wyjście `sherpa-onnx-offline-speaker-diarization`:
    /// `0.031 -- 3.035 speaker_01`, jedna tura na linię. Resztę (logi, nagłówki)
    /// pomija.
    public static func parse(_ output: String) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        for raw in output.split(whereSeparator: \.isNewline) {
            let parts = raw.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 4, parts[1] == "--",
                  let start = Double(parts[0]), let end = Double(parts[2]),
                  parts[3].hasPrefix("speaker_"), end > start
            else { continue }
            turns.append(SpeakerTurn(start: start, end: end, cluster: String(parts[3])))
        }
        return turns.sorted { $0.start < $1.start }
    }

    /// Klaster, który najdłużej pokrywa przedział. `nil`, gdy żaden.
    public static func dominantCluster(start: Double, end: Double, in turns: [SpeakerTurn]) -> String? {
        var overlap: [String: Double] = [:]
        for turn in turns where turn.end > start && turn.start < end {
            overlap[turn.cluster, default: 0] += min(end, turn.end) - max(start, turn.start)
        }
        // Remis rozstrzygamy nazwą klastra, żeby wynik był deterministyczny.
        return overlap.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
    }

    /// Najbliższy klaster dla fragmentu, którego nie pokrywa żadna tura —
    /// diaryzacja gubi krótkie wtrącenia, a tekst z nich jest prawdziwy.
    static func nearestCluster(start: Double, end: Double, in turns: [SpeakerTurn]) -> String? {
        let mid = (start + end) / 2
        return turns.min { a, b in
            distance(mid, a) < distance(mid, b)
        }?.cluster
    }

    private static func distance(_ t: Double, _ turn: SpeakerTurn) -> Double {
        t < turn.start ? turn.start - t : (t > turn.end ? t - turn.end : 0)
    }

    /// Przypisuje etykiety fragmentom tekstu.
    ///
    /// Surowe `speaker_07` z klastrowania nic nie mówią, więc numerujemy
    /// w kolejności pierwszego odezwania się: pierwszy głos w nagraniu to
    /// „{prefix} 1". Bez tur (diaryzacja wyłączona albo nieudana) wszystko
    /// dostaje `fallback`.
    public static func label(_ texts: [TimedText], turns: [SpeakerTurn],
                             prefix: String, fallback: String) -> [String] {
        guard !turns.isEmpty else { return texts.map { _ in fallback } }
        var numbering: [String: Int] = [:]
        return texts.map { item in
            guard let cluster = dominantCluster(start: item.start, end: item.end, in: turns)
                    ?? nearestCluster(start: item.start, end: item.end, in: turns)
            else { return fallback }
            if numbering[cluster] == nil { numbering[cluster] = numbering.count + 1 }
            return "\(prefix) \(numbering[cluster]!)"
        }
    }

    /// Skleja kolejne fragmenty tej samej osoby w akapity.
    ///
    /// Whisper tnie na zdania co kilka sekund; w notatce chcemy wypowiedzi,
    /// a nie osobny nagłówek nad każdym zdaniem. Sklejamy tylko przy krótkiej
    /// przerwie i do twardego limitu długości — tak samo jak `TranscriptStore`
    /// w trybie na żywo.
    public static func paragraphs(_ texts: [TimedText], speakers: [String],
                                  maxGap: Double = 2.5, maxLength: Double = 60) -> [(speaker: String, item: TimedText)] {
        var out: [(speaker: String, item: TimedText)] = []
        for (item, speaker) in zip(texts, speakers) {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = out.last, last.speaker == speaker,
               item.start - last.item.end <= maxGap,
               item.end - last.item.start <= maxLength {
                last.item.text += " " + text
                last.item.end = item.end
                out[out.count - 1] = last
            } else {
                out.append((speaker, TimedText(start: item.start, end: item.end, text: text)))
            }
        }
        return out
    }

    /// Gotowe segmenty transkryptu. `startedAt` to czas ściany początku nagrania
    /// w ms — Markdown liczy z niego offsety i nagłówek.
    public static func segments(_ paragraphs: [(speaker: String, item: TimedText)],
                                startedAt: Double, idPrefix: String = "imp") -> [Segment] {
        paragraphs.enumerated().map { index, p in
            Segment(id: "\(idPrefix)-\(index)", speaker: p.speaker, text: p.item.text,
                    startedAt: startedAt + p.item.start * 1000,
                    endedAt: startedAt + p.item.end * 1000,
                    offsetMs: p.item.start * 1000, final: true)
        }
    }

    /// Przepisuje etykiety istniejących segmentów rozmowy na żywo.
    ///
    /// Dotyka tylko segmentów, dla których `isTarget` zwraca prawdę (etykiety
    /// dźwięku systemu) — „Ty" z mikrofonu jest pewne, bo bierze się
    /// z rozdzielenia źródeł, a nie z barwy głosu, i diaryzacja nie ma go
    /// prawa nadpisać.
    public static func relabel(_ segments: [Segment], turns: [SpeakerTurn],
                               where isTarget: (String) -> Bool, prefix: String) -> [Segment] {
        guard !turns.isEmpty else { return segments }
        let targets = segments.enumerated().filter { isTarget($0.element.speaker) }
        let texts = targets.map { TimedText(start: $0.element.offsetMs / 1000,
                                            end: max($0.element.offsetMs / 1000 + 0.1,
                                                     $0.element.offsetMs / 1000 + ($0.element.endedAt - $0.element.startedAt) / 1000),
                                            text: $0.element.text) }
        let labels = label(texts, turns: turns, prefix: prefix, fallback: prefix)
        // Jeden głos to żadna informacja — zostawiamy znaną etykietę.
        guard Set(labels).count > 1 else { return segments }
        var out = segments
        for ((index, _), name) in zip(targets, labels) { out[index].speaker = name }
        return out
    }

    /// Etykiety, które może nadać dźwięk systemu — w obu trybach (z MFCC
    /// i bez). To je przepisuje diaryzacja po rozmowie.
    public static func isSystemLabel(_ speaker: String) -> Bool {
        speaker == "Rozmówcy" || speaker == unknownSpeaker || speaker.hasPrefix("Rozmówca ")
    }
}
