import Foundation

public let unknownSpeaker = "Nieznany"

/// Jedna wypowiedź w transkrypcie.
public struct Segment: Sendable, Equatable {
    public var id: String
    public var speaker: String
    public var text: String
    public var startedAt: Double
    public var endedAt: Double
    public var offsetMs: Double
    public var final: Bool

    public init(id: String, speaker: String, text: String, startedAt: Double, endedAt: Double, offsetMs: Double, final: Bool) {
        self.id = id; self.speaker = speaker; self.text = text
        self.startedAt = startedAt; self.endedAt = endedAt
        self.offsetMs = offsetMs; self.final = final
    }
}

public struct SpeakerStats: Sendable {
    public var name: String
    public var segments: Int
    public var chars: Int
    public var words: Int
    public var firstAt: Double
    public var talkMs: Double
}

/// TranscriptStore — rdzeń niezależny od źródła.
///
/// Adapter (ScreenCaptureKit, mikrofon, whisper.cpp…) woła `upsert()` z migawką
/// aktualnie rozpoznanego bloku. Store zajmuje się resztą: scalaniem strumienia,
/// pilnowaniem tożsamości mówcy, finalizacją po ciszy i łączeniem poszatkowanych
/// wypowiedzi tej samej osoby.
///
/// Port z `extension/src/core/transcript.js`.
public final class TranscriptStore {
    private final class Live {
        var id: String
        var key: String?
        var speaker: String
        var text: String
        var startedAt: Double
        var updatedAt: Double
        var endedAt: Double?
        var final: Bool
        init(id: String, key: String?, speaker: String, text: String, startedAt: Double, updatedAt: Double, final: Bool) {
            self.id = id; self.key = key; self.speaker = speaker; self.text = text
            self.startedAt = startedAt; self.updatedAt = updatedAt; self.final = final
        }
    }

    /// Po tylu ms bez zmiany tekstu segment uznajemy za domknięty.
    public var silenceMs: Double
    /// Kolejny segment tej samej osoby w tym oknie doklejamy do poprzedniego.
    public var mergeGapMs: Double
    /// Nie sklejamy w nieskończoność — twardy limit długości akapitu.
    public var maxMergedMs: Double
    /// Krótsze wypowiedzi niż tyle znaków są ignorowane przy finalizacji.
    public var minChars: Int

    public let startedAt: Double
    /// Rośnie przy każdej zmianie — tanie źródło prawdy dla UI.
    public private(set) var revision: Int = 0

    private var segmentList: [Live] = []
    private var live: [String: Live] = [:]
    /// Treść ostatnio domkniętego segmentu per klucz — broni przed dublowaniem
    /// bloku, który źródło pokazuje jeszcze długo po końcu wypowiedzi.
    private var retired: [String: (speaker: String, text: String)] = [:]
    private var retiredOrder: [String] = []
    /// Klucze domknięte ostatecznie — kolejne migawki są ignorowane.
    private var sealed: Set<String> = []
    private var sealedOrder: [String] = []
    private var idCounter = 0

    private static let retiredLimit = 100
    private static let sealedLimit = 200

    public init(startedAt: Double = nowMs(), silenceMs: Double = 2500, mergeGapMs: Double = 2500,
                maxMergedMs: Double = 60_000, minChars: Int = 1) {
        self.startedAt = startedAt
        self.silenceMs = silenceMs
        self.mergeGapMs = mergeGapMs
        self.maxMergedMs = maxMergedMs
        self.minChars = minChars
    }

    /// Migawka aktualnego bloku rozpoznania.
    ///
    /// `replace: true` oznacza, że źródło podaje pełną, poprawioną treść przy
    /// każdej aktualizacji (tak działa SpeechTranscriber) — wtedy tekst
    /// podmieniamy zamiast scalać.
    @discardableResult
    public func upsert(key: String, speaker: String?, text: String, at: Double = nowMs(), replace: Bool = false) -> Segment? {
        let body = Text.normalize(text)
        guard !body.isEmpty else { return nil }
        guard !sealed.contains(key) else { return nil }
        let whoRaw = Text.normalize(speaker)
        let who = whoRaw.isEmpty ? unknownSpeaker : whoRaw

        var seg = live[key]

        // Ten sam blok przejęty przez innego mówcę => zamykamy poprzedni.
        if let s = seg, s.speaker != who {
            close(s, now: at)
            live.removeValue(forKey: key)
            seg = nil
        }

        var incoming = body
        if seg == nil, let old = retired[key], old.speaker == who {
            // Przy pełnych migawkach domknięte znaczy domknięte.
            if replace { return nil }
            let merged = Text.reconcile(old.text, body)
            if merged == old.text { return nil } // blok wisi, nic nowego nie padło
            incoming = merged.hasPrefix(old.text)
                ? Text.normalize(String(merged.dropFirst(old.text.count)))
                : merged
            dropRetired(key)
            if incoming.isEmpty { return nil }
        }

        if seg == nil {
            idCounter += 1
            let fresh = Live(id: "s\(idCounter)", key: key, speaker: who, text: incoming,
                             startedAt: at, updatedAt: at, final: false)
            segmentList.append(fresh)
            live[key] = fresh
            revision += 1
            return snapshot(fresh)
        }

        let s = seg!
        let merged = replace ? body : Text.reconcile(s.text, body)
        if merged != s.text {
            s.text = merged
            s.updatedAt = at // rośnie tylko przy realnej zmianie -> działa detekcja ciszy
            revision += 1
        }
        return snapshot(s)
    }

    /// Domyka segmenty, które od `silenceMs` nic nie zmieniły.
    public func finalizeIdle(now: Double = nowMs()) {
        for (key, seg) in live where now - seg.updatedAt >= silenceMs {
            close(seg, now: now)
            live.removeValue(forKey: key)
        }
    }

    /// Blok zniknął ze źródła — wypowiedź na pewno się skończyła.
    public func dropKey(_ key: String, now: Double = nowMs()) {
        if let seg = live[key] {
            close(seg, now: now)
            live.removeValue(forKey: key)
        }
        dropRetired(key)
    }

    /// Domyka segment i zamyka klucz na dobre — źródło może go wysłać ponownie.
    public func seal(_ key: String, now: Double = nowMs()) {
        if let seg = live[key] {
            close(seg, now: now)
            live.removeValue(forKey: key)
        }
        dropRetired(key)
        if sealed.insert(key).inserted {
            sealedOrder.append(key)
            if sealedOrder.count > Self.sealedLimit {
                sealed.remove(sealedOrder.removeFirst())
            }
        }
    }

    /// Usuwa segment bez śladu — np. znacznik „w toku" po nieudanej transkrypcji.
    @discardableResult
    public func discard(_ key: String) -> Bool {
        guard let seg = live[key] else { return false }
        if let i = segmentList.firstIndex(where: { $0 === seg }) { segmentList.remove(at: i) }
        live.removeValue(forKey: key)
        dropRetired(key)
        revision += 1
        return true
    }

    /// Koniec sesji.
    public func finalizeAll(now: Double = nowMs()) {
        for seg in live.values { close(seg, now: now) }
        live.removeAll()
    }

    private func dropRetired(_ key: String) {
        if retired.removeValue(forKey: key) != nil {
            retiredOrder.removeAll { $0 == key }
        }
    }

    private func retire(_ seg: Live) {
        guard let key = seg.key else { return }
        if retired[key] == nil { retiredOrder.append(key) }
        retired[key] = (seg.speaker, seg.text)
        if retiredOrder.count > Self.retiredLimit {
            retired.removeValue(forKey: retiredOrder.removeFirst())
        }
    }

    private func close(_ seg: Live, now: Double) {
        seg.final = true
        seg.endedAt = Swift.max(seg.updatedAt, seg.startedAt)
        retire(seg)

        if Text.normalize(seg.text).count < minChars {
            if let i = segmentList.firstIndex(where: { $0 === seg }) { segmentList.remove(at: i) }
            revision += 1
            return
        }

        // Sklejanie poszatkowanych wypowiedzi tej samej osoby.
        guard let i = segmentList.firstIndex(where: { $0 === seg }), i > 0 else {
            revision += 1
            return
        }
        let prev = segmentList[i - 1]
        if prev.final,
           prev.speaker == seg.speaker,
           seg.startedAt - (prev.endedAt ?? prev.updatedAt) <= mergeGapMs,
           seg.updatedAt - prev.startedAt <= maxMergedMs {
            prev.text = Text.reconcile(prev.text, seg.text)
            prev.updatedAt = seg.updatedAt
            prev.endedAt = seg.endedAt
            segmentList.remove(at: i)
        }
        revision += 1
    }

    private func snapshot(_ s: Live) -> Segment {
        Segment(id: s.id, speaker: s.speaker, text: s.text,
                startedAt: s.startedAt, endedAt: s.endedAt ?? s.updatedAt,
                offsetMs: Swift.max(0, s.startedAt - startedAt), final: s.final)
    }

    /// Wszystkie segmenty (domknięte i na żywo) z policzonym offsetem.
    public var segments: [Segment] { segmentList.map(snapshot) }

    public var liveCount: Int { live.count }
    public var isEmpty: Bool { segmentList.isEmpty }

    /// Statystyki per osoba, w kolejności pierwszego wystąpienia.
    public var speakers: [SpeakerStats] {
        var order: [String] = []
        var map: [String: SpeakerStats] = [:]
        for s in segmentList {
            if map[s.speaker] == nil {
                order.append(s.speaker)
                map[s.speaker] = SpeakerStats(name: s.speaker, segments: 0, chars: 0, words: 0, firstAt: s.startedAt, talkMs: 0)
            }
            map[s.speaker]!.segments += 1
            map[s.speaker]!.chars += s.text.count
            map[s.speaker]!.words += Text.wordCount(s.text)
            map[s.speaker]!.talkMs += Swift.max(0, (s.endedAt ?? s.updatedAt) - s.startedAt)
        }
        return order.compactMap { map[$0] }
    }
}
