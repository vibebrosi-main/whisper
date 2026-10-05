import Foundation

public struct SessionMeta: Sendable {
    public var title: String = ""
    public var source: String = ""
    public var url: String = ""
    public var startedAt: Double?
    public var endedAt: Double?
    public init(title: String = "", source: String = "", url: String = "", startedAt: Double? = nil, endedAt: Double? = nil) {
        self.title = title; self.source = source; self.url = url
        self.startedAt = startedAt; self.endedAt = endedAt
    }
}

public struct Session: Sendable {
    public var meta: SessionMeta
    public var segments: [Segment]
    public init(meta: SessionMeta, segments: [Segment]) {
        self.meta = meta; self.segments = segments
    }
}

public struct MarkdownOptions: Sendable {
    public var locale: String = "pl"
    public var frontmatter: Bool = true
    public var absoluteTimestamps: Bool = false
    public var stats: Bool = true
    public var escape: Bool = true
    public init() {}
    public init(locale: String = "pl", frontmatter: Bool = true, absoluteTimestamps: Bool = false, stats: Bool = true, escape: Bool = true) {
        self.locale = locale; self.frontmatter = frontmatter
        self.absoluteTimestamps = absoluteTimestamps; self.stats = stats; self.escape = escape
    }
}

/// Renderer Markdown. Port z `extension/src/core/markdown.js` — ten sam format
/// wyjściowy, więc pliki z wersji webowej i natywnej są nieodróżnialne.
public enum Markdown {
    struct Strings {
        var transcript, participants, person, utterances, words, share, untitled, empty, live: String
    }

    static let locales: [String: Strings] = [
        "pl": Strings(transcript: "Transkrypt", participants: "Uczestnicy", person: "Osoba",
                      utterances: "Wypowiedzi", words: "Słowa", share: "Udział", untitled: "Rozmowa",
                      empty: "_Brak transkrypcji — nikt nie mówił albo nie było czego słuchać._",
                      live: "w trakcie"),
        "en": Strings(transcript: "Transcript", participants: "Participants", person: "Person",
                      utterances: "Utterances", words: "Words", share: "Share", untitled: "Call",
                      empty: "_No transcript — nobody spoke or there was nothing to listen to._",
                      live: "live"),
    ]

    static let sourceLabels: [String: String] = [
        "google-meet": "Google Meet",
        "system-audio": "Dźwięk systemowy",
        "microphone": "Mikrofon",
        "mixed": "Dźwięk systemowy + mikrofon",
        "file": "Nagranie z pliku",
    ]

    /// Chronimy tylko to, co realnie psuje render w środku akapitu.
    static func escapeInline(_ text: String) -> String {
        var out = ""
        for ch in Text.normalize(text) {
            if ch == "*" || ch == "_" || ch == "`" { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    static func yamlString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }

    public static func render(_ session: Session, options: MarkdownOptions = MarkdownOptions()) -> String {
        let t = locales[options.locale] ?? locales["pl"]!
        let meta = session.meta
        let segments = session.segments.sorted { $0.startedAt < $1.startedAt }

        let startedAt = meta.startedAt ?? segments.first?.startedAt ?? nowMs()
        let endedAt = meta.endedAt ?? segments.last?.endedAt ?? startedAt
        let durationMs = Swift.max(0, endedAt - startedAt)
        let titleRaw = Text.normalize(meta.title)
        let title = titleRaw.isEmpty ? t.untitled : titleRaw
        let sourceLabel = sourceLabels[meta.source] ?? meta.source

        var order: [String] = []
        var rows: [String: (utterances: Int, words: Int)] = [:]
        for s in segments {
            if rows[s.speaker] == nil { order.append(s.speaker); rows[s.speaker] = (0, 0) }
            rows[s.speaker]!.utterances += 1
            rows[s.speaker]!.words += Text.wordCount(s.text)
        }
        let totalWords = Swift.max(1, order.reduce(0) { $0 + (rows[$1]?.words ?? 0) })

        var out: [String] = []

        if options.frontmatter {
            out.append("---")
            out.append("title: \(yamlString(title))")
            if !meta.source.isEmpty { out.append("source: \(meta.source)") }
            if !meta.url.isEmpty { out.append("url: \(yamlString(meta.url))") }
            out.append("date: \(TimeFormat.localDate(startedAt))")
            out.append("started: \(yamlString(TimeFormat.localDateTime(startedAt)))")
            out.append("duration: \(yamlString(TimeFormat.offset(durationMs)))")
            out.append("speakers: [\(order.map(yamlString).joined(separator: ", "))]")
            out.append("generator: call-whisper")
            out.append("---")
            out.append("")
        }

        out.append("# \(title)")
        out.append("")

        var headerBits = [TimeFormat.localDateTime(startedAt, withSeconds: false)]
        if durationMs > 0 { headerBits.append(TimeFormat.duration(durationMs)) }
        if !sourceLabel.isEmpty { headerBits.append(sourceLabel) }
        out.append(headerBits.joined(separator: " · "))
        out.append("")

        if options.stats && !order.isEmpty {
            out.append("## \(t.participants)")
            out.append("")
            out.append("| \(t.person) | \(t.utterances) | \(t.words) | \(t.share) |")
            out.append("| --- | ---: | ---: | ---: |")
            for name in order {
                let r = rows[name]!
                let share = Int((Double(r.words) / Double(totalWords) * 100).rounded())
                out.append("| \(name) | \(r.utterances) | \(r.words) | \(share)% |")
            }
            out.append("")
        }

        out.append("## \(t.transcript)")
        out.append("")

        if segments.isEmpty {
            out.append(t.empty)
            out.append("")
        }

        for s in segments {
            let stamp = options.absoluteTimestamps
                ? TimeFormat.localTime(s.startedAt)
                : TimeFormat.offset(s.offsetMs)
            let suffix = s.final ? "" : " _(\(t.live))_"
            out.append("**[\(stamp)] \(s.speaker)**\(suffix)")
            out.append("")
            out.append(options.escape ? escapeInline(s.text) : Text.normalize(s.text))
            out.append("")
        }

        var body = out.joined(separator: "\n")
        while body.contains("\n\n\n") { body = body.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return body.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    /// Krótki podgląd tekstowy (menu, powiadomienia).
    public static func preview(_ segments: [Segment], limit: Int = 6) -> String {
        segments.suffix(limit)
            .map { "[\(TimeFormat.offset($0.offsetMs))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }
}
