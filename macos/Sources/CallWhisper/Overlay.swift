import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CallWhisperKit
import CallWhisperCore

/// Pływające okno z odpowiedziami, trzymane nad rozmową.
///
/// Odpowiednik nakładki w Shadow DOM z wersji webowej — z tą różnicą, że
/// natywnie nie musimy się bronić przed CSS cudzej strony ani przechwytywać
/// klawiszy, żeby pisanie nie sterowało rozmową. Zamiast tego potrzebne są
/// trzy rzeczy, których przeglądarka nie dawała wcale:
///
///  - `.nonactivatingPanel` — kliknięcie w nakładkę nie zabiera fokusu
///    aplikacji do wideorozmowy;
///  - poziom `.floating` + `canJoinAllSpaces` — nakładka jest widoczna także
///    nad rozmową na pełnym ekranie, na każdym pulpicie;
///  - `hidesOnDeactivate = false` — nie znika, gdy klikniesz z powrotem
///    w rozmowę, bo wtedy byłaby bezużyteczna.
@MainActor
@Observable
final class OverlayController {
    private var panel: NSPanel?
    var isVisible = false

    func toggle(recorder: Recorder) {
        isVisible ? hide() : show(recorder: recorder)
    }

    func show(recorder: Recorder) {
        if let panel {
            panel.orderFrontRegardless()
            isVisible = true
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 260),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Podpowiedzi"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.contentView = NSHostingView(rootView: OverlayView(recorder: recorder))

        // Prawy górny róg ekranu — tam, gdzie zwykle nie ma twarzy rozmówców.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 400, y: frame.maxY - 300))
        }

        panel.orderFrontRegardless()
        self.panel = panel
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }
}

struct OverlayView: View {
    @ObservedObject var recorder: Recorder
    @State private var question = ""
    @State private var attachment: AssistantImage?
    @StateObject private var paste = PasteWatcher()

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(recorder.answers.suffix(6), id: \.id) { item in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(item.question)
                                    .font(M3.type.labelMedium)
                                    .foregroundStyle(M3.color.primary)
                                    .lineLimit(2)
                                if item.status == .pending {
                                    M3LinearProgress().frame(width: 80)
                                } else if item.status == .error {
                                    Text(item.error ?? "Błąd").font(M3.type.bodyMedium).foregroundStyle(M3.color.error)
                                } else {
                                    MarkdownText(text: item.answer).foregroundStyle(M3.color.onSurface)
                                }
                            }
                            .id(item.id)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(M3.color.surfaceContainerLow, in: RoundedRectangle(cornerRadius: M3.shape.medium))
                        }
                        if recorder.answers.isEmpty {
                            Text("Czekam na pytanie w rozmowie.")
                                .font(M3.type.bodyMedium).foregroundStyle(M3.color.onSurfaceVariant)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: recorder.answers.last?.answer) { _, _ in
                    guard let id = recorder.answers.last?.id else { return }
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }

            // Pole pytania musi mieć własną, gwarantowaną wysokość — inaczej
            // przy dłuższej odpowiedzi lista wyciska je do zera.
            if let attachment {
                HStack(spacing: 8) {
                    if let preview = attachment.preview {
                        Image(nsImage: preview)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 48, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: M3.shape.extraSmall))
                    }
                    Text(attachment.sizeDescription)
                        .font(M3.type.labelSmall).foregroundStyle(M3.color.onSurfaceVariant)
                    Spacer()
                    Button { self.attachment = nil } label: {
                        Label("Usuń", systemImage: "xmark")
                    }
                    .buttonStyle(M3IconButtonStyle())
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }

            HStack(spacing: 6) {
                TextField(attachment == nil ? "Zapytaj…" : "O co pytasz na tym zrzucie?",
                          text: $question)
                    .textFieldStyle(.plain)
                    .font(M3.type.bodyMedium)
                    .foregroundStyle(M3.color.onSurface)
                    .onSubmit(send)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(M3.color.surfaceContainerHigh, in: Capsule())
                    // Tylko typy obrazkowe — wklejenie tekstu ma trafiać do pola.
                    .onPasteCommand(of: [UTType.png.identifier,
                                         UTType.tiff.identifier,
                                         UTType.jpeg.identifier]) { _ in
                        attachment = AssistantImage.fromPasteboard()
                    }

                // Zapasowa droga, gdyby `onPasteCommand` nie dostało fokusu —
                // nakładka jest oknem nieaktywującym, więc tym bardziej.
                Button {
                    attachment = AssistantImage.fromPasteboard()
                } label: {
                    Label("Załącz", systemImage: "paperclip")
                }
                .buttonStyle(M3IconButtonStyle(selected: paste.hasImage))
                .help(paste.hasImage
                      ? "Dołącz zrzut ze schowka (albo wklej przez ⌘V)"
                      : "W schowku nie ma obrazka")
            }
            .padding(10)
            .frame(minHeight: 44)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 300, minHeight: 200)
        .background(M3.color.surfaceContainerLowest.opacity(0.94))
        .tint(M3.color.primary)
        .onAppear { paste.start { attachment = $0 } }
        .onDisappear { paste.stop() }
    }

    /// Ze zrzutem samo pytanie może być puste — obrazek bywa całą treścią.
    private func send() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || attachment != nil else { return }
        recorder.ask(text, image: attachment)
        question = ""
        attachment = nil
    }
}
