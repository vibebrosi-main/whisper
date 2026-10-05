import Testing
import Foundation
@testable import CallWhisperCore

/// Testy zgodności z implementacją webową.
///
/// Wektory referencyjne pochodzą z działającego kodu JS
/// (`macos/tools/gen-fixtures.mjs`), a nie z ręcznie przepisanych asercji.
/// Dzięki temu każda rozbieżność portu wychodzi tu, a nie w trakcie rozmowy.
struct FixtureTests {
    /// Parsujemy przy każdym odczycie zamiast cache'ować w statycznej zmiennej:
    /// swift-testing puszcza testy równolegle, a plik ma kilkadziesiąt kB.
    static var fixtures: [String: Any] {
        guard let url = Bundle.module.url(forResource: "fixtures", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { fatalError("brak fixtures.json — uruchom: node macos/tools/gen-fixtures.mjs") }
        return json
    }

    static func cases(_ key: String) -> [[String: Any]] {
        (fixtures[key] as? [[String: Any]]) ?? []
    }

    // MARK: - tekst

    @Test func reconcileZgadzaSieZJS() {
        let items = Self.cases("reconcileCases")
        #expect(!items.isEmpty)
        for c in items {
            let prev = c["prev"] as! String
            let next = c["next"] as! String
            let expected = c["result"] as! String
            #expect(Text.reconcile(prev, next) == expected, "reconcile(\(prev), \(next))")
        }
    }

    @Test func normalizeZgadzaSieZJS() {
        for c in Self.cases("normalizeCases") {
            #expect(Text.normalize(c["input"] as? String) == c["result"] as! String)
        }
    }

    @Test func foldZgadzaSieZJS() {
        for c in Self.cases("foldCases") {
            let input = c["input"] as! String
            #expect(Text.fold(input) == c["result"] as! String, "fold(\(input))")
        }
    }

    @Test func wordCountITruncate() {
        for c in Self.cases("wordCountCases") {
            #expect(Text.wordCount(c["input"] as! String) == c["result"] as! Int)
        }
        for c in Self.cases("truncateCases") {
            #expect(Text.truncate(c["input"] as! String, max: c["max"] as! Int) == c["result"] as! String)
        }
    }

    // MARK: - czas

    @Test func formatowanieCzasu() {
        for c in Self.cases("offsetCases") {
            let ms = (c["ms"] as! NSNumber).doubleValue
            #expect(TimeFormat.offset(ms) == c["result"] as! String, "offset(\(ms))")
        }
        for c in Self.cases("durationCases") {
            let ms = (c["ms"] as! NSNumber).doubleValue
            #expect(TimeFormat.duration(ms) == c["result"] as! String, "duration(\(ms))")
        }
    }

    // MARK: - wykrywanie pytań

    @Test func wykrywaniePytanZgadzaSieZJS() {
        let items = Self.cases("questionCases")
        #expect(items.count >= 10)
        for c in items {
            let text = c["text"] as! String
            let v = QuestionDetector.detect(text)
            #expect(v.isQuestion == c["isQuestion"] as! Bool, "isQuestion dla: \(text)")
            let expectedConfidence = (c["confidence"] as! NSNumber).doubleValue
            #expect(abs(v.confidence - expectedConfidence) < 1e-9, "confidence dla: \(text)")
            #expect(v.reason == c["reason"] as! String, "reason dla: \(text)")
            #expect(v.question == c["question"] as! String, "question dla: \(text)")
        }
    }

    @Test func podzialNaFrazy() {
        for c in Self.cases("clauseCases") {
            #expect(QuestionDetector.splitClauses(c["text"] as! String) == c["result"] as! [String])
        }
    }

    @Test func promptZgadzaSieZJS() {
        let segments = Self.markdownSegments()
        let prompt = buildPrompt(question: "A jakie RPO i RTO to nam daje?", segments: segments, title: "Standup zespołu")
        #expect(prompt == (Self.fixtures["prompt"] as! String))
    }

    // MARK: - markdown

    static func markdownSegments() -> [Segment] {
        let startedAt = Self.startedAt
        return [
            Segment(id: "s1", speaker: "Anna Kowalska", text: "Cześć wszystkim, zaczynamy standup.",
                    startedAt: startedAt + 4000, endedAt: startedAt + 9000, offsetMs: 4000, final: true),
            Segment(id: "s2", speaker: "Jan Nowak", text: "Hej, słychać mnie? Mam *gwiazdkę* i _podkreślenie_.",
                    startedAt: startedAt + 11_000, endedAt: startedAt + 14_000, offsetMs: 11_000, final: true),
            Segment(id: "s3", speaker: "Anna Kowalska", text: "Lecimy dalej.",
                    startedAt: startedAt + 20_000, endedAt: startedAt + 22_000, offsetMs: 20_000, final: false),
        ]
    }

    static let startedAt: Double = {
        var c = DateComponents()
        c.year = 2026; c.month = 8; c.day = 23; c.hour = 8; c.minute = 15; c.second = 3
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!.timeIntervalSince1970 * 1000
    }()

    @Test func markdownZgadzaSieZJS() {
        let meta = SessionMeta(title: "Standup zespołu", source: "google-meet",
                               url: "https://meet.google.com/abc-defg-hij",
                               startedAt: Self.startedAt, endedAt: Self.startedAt + 2_531_000)
        let session = Session(meta: meta, segments: Self.markdownSegments())

        var opts = MarkdownOptions()
        opts.frontmatter = false
        #expect(Markdown.render(session, options: opts) == (Self.fixtures["markdown"] as! String))

        var optsEn = MarkdownOptions()
        optsEn.frontmatter = false
        optsEn.locale = "en"
        optsEn.stats = false
        #expect(Markdown.render(session, options: optsEn) == (Self.fixtures["markdownEn"] as! String))
    }

    // MARK: - transkrypt

    @Test func transcriptStoreZgadzaSieZJS() {
        let t0: Double = 1_700_000_000_000
        let store = TranscriptStore(startedAt: t0, silenceMs: 2500)
        store.upsert(key: "a", speaker: "Anna", text: "Cześć", at: t0 + 100)
        store.upsert(key: "a", speaker: "Anna", text: "Cześć wszystkim", at: t0 + 400)
        store.upsert(key: "b", speaker: "Jan", text: "Hej", at: t0 + 900)
        store.finalizeIdle(now: t0 + 5000)
        store.upsert(key: "c", speaker: "Anna", text: "Druga wypowiedź Anny", at: t0 + 30_000)
        store.finalizeAll(now: t0 + 40_000)

        let expected = Self.fixtures["transcriptResult"] as! [[String: Any]]
        let actual = store.segments
        #expect(actual.count == expected.count, "liczba segmentów")
        for (a, e) in zip(actual, expected) {
            #expect(a.speaker == e["speaker"] as! String)
            #expect(a.text == e["text"] as! String)
            #expect(a.offsetMs == (e["offsetMs"] as! NSNumber).doubleValue)
            #expect(a.final == e["final"] as! Bool)
        }
    }
}
