import SwiftUI

/// Tekst odpowiedzi renderowany jako Markdown.
///
/// Model odpowiada Markdownem — `**pogrubienie**`, `` `nazwa.metody` `` — i bez
/// tego widać w oknie surowe gwiazdki i backticki zamiast formatowania.
///
/// Świadomie **bez zewnętrznego renderera**: `AttributedString(markdown:)`
/// obsługuje wszystko, co realnie pada w krótkiej podpowiedzi, a repozytorium
/// trzyma się zasady zero zależności.
struct MarkdownText: View {
    let text: String
    var font: Font = .callout

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let code):
                    // Blok kodu: własne tło i przewijanie w poziomie, żeby
                    // długa linia nie rozpychała całego panelu.
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(code)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    // Bez tego poziomy `ScrollView` rozpycha się w pionie
                    // i zabiera wysokość reszcie panelu.
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                case .bullet(let items):
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").font(font).foregroundStyle(.secondary)
                                Text(styled(item)).font(font)
                            }
                        }
                    }

                case .paragraph(let paragraph):
                    Text(styled(paragraph)).font(font)
                }
            }
        }
        .textSelection(.enabled)
    }

    // MARK: - parsowanie

    private enum Block {
        case paragraph(String)
        case bullet([String])
        case code(String)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var code: [String] = []
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        func flushBullets() {
            if !bullets.isEmpty { out.append(.bullet(bullets)); bullets = [] }
        }

        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if inCode {
                    out.append(.code(code.joined(separator: "\n")))
                    code = []
                } else {
                    flushParagraph(); flushBullets()
                }
                inCode.toggle()
                continue
            }
            if inCode { code.append(line); continue }

            if trimmed.isEmpty { flushParagraph(); flushBullets(); continue }

            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                flushParagraph()
                bullets.append(String(trimmed.dropFirst(2)))
                continue
            }

            flushBullets()
            paragraph.append(trimmed)
        }
        if inCode && !code.isEmpty { out.append(.code(code.joined(separator: "\n"))) }
        flushParagraph()
        flushBullets()
        return out
    }

    /// Formatowanie w linii: pogrubienie, kursywa, kod.
    private func styled(_ source: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                           failurePolicy: .returnPartiallyParsedIfPossible)
        )) ?? AttributedString(source)

        // `AttributedString` oznacza kod intencją, ale nie nadaje mu kroju —
        // bez tego `Dispatchers.IO` wygląda jak zwykły tekst.
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = .system(.callout, design: .monospaced)
            attributed[run.range].foregroundColor = M3.color.primary
        }
        return attributed
    }
}
