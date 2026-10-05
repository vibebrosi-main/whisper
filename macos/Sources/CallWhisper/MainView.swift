import SwiftUI
import UniformTypeIdentifiers
import CallWhisperKit
import CallWhisperCore

/// Okno główne w układzie Material 3, wzorowanym na aplikacjach Google
/// Workspace: tło surface container, treść na zaokrąglonych kartach,
/// górny pasek aplikacji z akcjami-ikonami i rozszerzony FAB na główną akcję.
struct MainView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings: AppSettings
    var overlay: OverlayController
    @ObservedObject var meetings: MeetingWatcher

    @State private var manualQuestion = ""
    @State private var dropTargeted = false
    @State private var exportingForClaude = false
    @State private var copiedNote = false
    @State private var busy = false
    @State private var showSetup = false
    @State private var attachment: AssistantImage?
    @FocusState private var questionFocused: Bool
    @StateObject private var paste = PasteWatcher()

    var body: some View {
        // Zwykły `VStack`, nie `safeAreaInset`: zagnieżdżone inset-y nie
        // rezerwowały sobie miejsca nawzajem i panel przysłaniał pole pytania.
        VStack(spacing: 0) {
            topAppBar
            if let meeting = meetings.activeMeeting, !recorder.isRunning, !recorder.isProcessing {
                meetingBanner(meeting)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
            HStack(spacing: 12) {
                transcriptCard
                    .frame(minWidth: 340, maxWidth: .infinity)
                assistantCard
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 440)
            }
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            statusLine
        }
        .background(M3.color.page)
        .tint(M3.color.primary)
        .sheet(isPresented: $showSetup) { SetupView(recorder: recorder) }
        .onAppear { paste.start { attachment = $0 } }
        .onDisappear { paste.stop() }
        .task {
            // Braki pokazujemy od razu po otwarciu, a nie dopiero komunikatem
            // błędu po kliknięciu „Słuchaj".
            recorder.refreshReadiness()
            if !recorder.readiness.allGood { showSetup = true }
        }
    }

    // MARK: - górny pasek

    private var topAppBar: some View {
        HStack(spacing: 4) {
            // Miejsce na światła okna: pasek tytułu jest ukryty, a pasek
            // aplikacji M3 zajmuje jego miejsce.
            Color.clear.frame(width: 64)

            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 22))
                .foregroundStyle(M3.color.primary)
            Text(recorder.importedMeta?.title ?? "call-whisper")
                .font(M3.type.titleLarge)
                .foregroundStyle(M3.color.onSurface)
                .lineLimit(1)
                .padding(.leading, 6)

            Spacer(minLength: 16)

            Button {
                if recorder.isProcessing { recorder.cancelProcessing() } else { ImportPanel.run(recorder) }
            } label: {
                Label(recorder.isProcessing ? "Przerwij" : "Importuj",
                      systemImage: recorder.isProcessing ? "xmark" : "square.and.arrow.down")
            }
            .buttonStyle(M3IconButtonStyle())
            .disabled(recorder.isRunning)
            .help(recorder.isProcessing
                  ? "Przerwij import albo rozpoznawanie głosów"
                  : "Transkrybuj nagranie albo wideo (mp4, mov, m4a, mp3, wav). Można też upuścić plik na transkrypt.")

            // Podpowiedzi bywają hałasem (film, monolog), więc wyłącznik musi
            // być pod ręką. Wariant „selected" przycisku-ikony M3 pokazuje stan.
            Button {
                settings.assistantEnabled.toggle()
            } label: {
                Label("Podpowiedzi", systemImage: settings.assistantEnabled ? "sparkles" : "sparkles.slash")
            }
            .buttonStyle(M3IconButtonStyle(selected: settings.assistantEnabled))
            .help(settings.assistantEnabled
                  ? "Podpowiedzi włączone: \(assistantLabel)"
                  : "Podpowiedzi wyłączone. Kliknij, żeby włączyć.")

            Button {
                overlay.toggle(recorder: recorder)
            } label: {
                Label("Nakładka", systemImage: "rectangle.on.rectangle")
            }
            .buttonStyle(M3IconButtonStyle(selected: overlay.isVisible))
            .help("Pływające okno z odpowiedziami, zostaje na wierzchu nad rozmową")

            Menu {
                Button("Kopiuj Markdown") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(recorder.markdown, forType: .string)
                }
                Button("Zapisz .md…") { save(recorder.markdown.data(using: .utf8), ext: "md") }
                Button("Zapisz .json…") { save(recorder.json, ext: "json") }
                Divider()
                Button(exportingForClaude ? "Podsumowuję…" : "Kopiuj dla Claude (z podsumowaniem)") {
                    exportForClaude()
                }
                .disabled(exportingForClaude)
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 18))
                    .foregroundStyle(M3.color.onSurfaceVariant)
                    .frame(width: 40, height: 40)
                    .contentShape(Circle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(recorder.segments.isEmpty || recorder.isRunning)
            .help("Eksport")

            Button {
                recorder.refreshReadiness()
                showSetup = true
            } label: {
                Label("Gotowość", systemImage: recorder.readiness.allGood
                      ? "checkmark.seal" : "exclamationmark.triangle")
            }
            .buttonStyle(M3IconButtonStyle(selected: !recorder.readiness.allGood))
            .help("Co jest potrzebne, żeby wszystko działało")
        }
        .padding(.horizontal, 12)
        .frame(height: 56)
    }

    // MARK: - transkrypt

    private var transcriptCard: some View {
        ZStack(alignment: .bottomTrailing) {
            Group {
                if recorder.segments.isEmpty {
                    emptyState
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 20) {
                                ForEach(recorder.segments, id: \.id) { segment in
                                    SegmentRow(segment: segment).id(segment.id)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, 20)
                            // Zapas pod FAB, żeby nie przykrywał ostatniej wypowiedzi.
                            .padding(.bottom, 96)
                        }
                        .onChange(of: recorder.segments.last?.id) { _, id in
                            guard let id else { return }
                            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .bottom) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            listenFAB.padding(20)
        }
        .background(M3.color.card, in: RoundedRectangle(cornerRadius: M3.shape.large))
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: M3.shape.large)
                    .strokeBorder(M3.color.primary, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(M3.color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: M3.shape.large))
            }
        }
        // Upuszczenie nagrania albo wideo na transkrypt = import.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard !recorder.isRunning, !recorder.isProcessing, let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, MediaImport.fileExtensions.contains(url.pathExtension.lowercased()) else { return }
                Task { @MainActor in recorder.importFile(url) }
            }
            return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: recorder.isRunning ? "waveform" : "mic.and.signal.meter")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(M3.color.onPrimaryContainer)
                .frame(width: 72, height: 72)
                .background(M3.color.primaryContainer, in: Circle())
                .symbolEffect(.variableColor.iterative, isActive: recorder.isRunning)
            Text(recorder.isRunning ? "Słucham" : (recorder.isProcessing ? "Pracuję" : "Cisza"))
                .font(M3.type.headlineSmall)
                .foregroundStyle(M3.color.onSurface)
            Text(recorder.isRunning
                 ? "Tekst pojawi się, gdy ktoś powie coś dłuższego."
                 : recorder.isProcessing
                    ? recorder.status
                    : "Kliknij „Słuchaj”, żeby zacząć zapis rozmowy, albo upuść tu nagranie lub wideo.")
                .font(M3.type.bodyMedium)
                .foregroundStyle(M3.color.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            if !recorder.isRunning && !recorder.isProcessing {
                Button {
                    ImportPanel.run(recorder)
                } label: {
                    Label("Importuj nagranie", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(M3ButtonStyle(kind: .outlined))
                .padding(.top, 4)
            }
        }
        .padding(32)
    }

    /// Główna akcja ekranu jako rozszerzony FAB M3. W trakcie nasłuchu zmienia
    /// się w „Zatrzymaj" na kontenerze error, żeby nie dało się pomylić stanów.
    private var listenFAB: some View {
        Button {
            // Blokada na czas przełączania: start podnosi whisper-server, a stop
            // przerywa żądania w locie. Drugie kliknięcie w międzyczasie
            // zostawiłoby stan w połowie drogi.
            guard !busy else { return }
            busy = true
            Task {
                recorder.isRunning ? await recorder.stop() : await recorder.start()
                busy = false
            }
        } label: {
            Label(recorder.isRunning ? "Zatrzymaj" : "Słuchaj",
                  systemImage: recorder.isRunning ? "stop.fill" : "mic.fill")
        }
        .buttonStyle(M3FABStyle(active: recorder.isRunning))
        .disabled(busy || recorder.isProcessing)
        .keyboardShortcut("l", modifiers: .command)
    }

    // MARK: - asystent

    private var assistantCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Podpowiedzi").font(M3.type.titleMedium).foregroundStyle(M3.color.onSurface)
                Spacer()
                Text(assistantLabel)
                    .font(M3.type.labelSmall)
                    .foregroundStyle(M3.color.onSurfaceVariant)
                    .lineLimit(1)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 8)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if recorder.answers.isEmpty {
                        Text(settings.assistantEnabled
                             ? (settings.autoAsk
                                ? "Pytania wykryte w rozmowie trafią tutaj same. Możesz też zapytać poniżej."
                                : "Automatyczne pytania wyłączone. Zapytaj poniżej.")
                             : "Podpowiedzi wyłączone. Włącz je ikoną ✨ na górnym pasku.")
                            .font(M3.type.bodyMedium)
                            .foregroundStyle(M3.color.onSurfaceVariant)
                            .padding(.top, 4)
                    }
                    ForEach(recorder.answers, id: \.id) { item in
                        AnswerCard(item: item)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            // Pole pytania jako przypięty pas: w `VStack` `ScrollView` bierze
            // całą wysokość i przy dłuższej odpowiedzi wyciskał pole do zera.
            .safeAreaInset(edge: .bottom, spacing: 0) { questionField }
        }
        .background(M3.color.card, in: RoundedRectangle(cornerRadius: M3.shape.large))
    }

    /// Pole pytania w stylu paska wyszukiwania Google (M3 search bar):
    /// kapsuła 56 pt na surface container high.
    private var questionField: some View {
        VStack(spacing: 8) {
            if let attachment { attachmentRow(attachment) }

            HStack(alignment: .center, spacing: 4) {
                // Zapasowa droga na wypadek, gdyby `onPasteCommand` nie dostało
                // fokusu. Nigdy nie wyszarzamy: stan schowka nie odświeża się
                // po skopiowaniu i przycisk zostawał martwy.
                Button {
                    attachment = AssistantImage.fromPasteboard()
                } label: {
                    Label("Załącz", systemImage: "paperclip")
                }
                .buttonStyle(M3IconButtonStyle(selected: paste.hasImage))
                .help(paste.hasImage
                      ? "Dołącz zrzut ze schowka (albo wklej przez ⌘V)"
                      : "W schowku nie ma obrazka")

                TextField(attachment == nil ? "Zapytaj o cokolwiek…" : "O co pytasz na tym zrzucie?",
                          text: $manualQuestion, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(M3.type.bodyLarge)
                    .foregroundStyle(M3.color.onSurface)
                    .lineLimit(1...4)
                    .focused($questionFocused)
                    .onSubmit(send)
                    // Tylko typy obrazkowe: wklejony tekst ma trafiać do pola.
                    .onPasteCommand(of: [UTType.png.identifier, UTType.tiff.identifier,
                                         UTType.jpeg.identifier]) { _ in
                        attachment = AssistantImage.fromPasteboard()
                    }

                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(canSend ? M3.color.onPrimary : M3.color.onSurface.opacity(0.38))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(canSend ? M3.color.primary : M3.color.onSurface.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(.leading, 4)
            .padding(.trailing, 10)
            .frame(minHeight: 56)
            .background(M3.color.cardField, in: RoundedRectangle(cornerRadius: M3.shape.extraLarge))
            .overlay(RoundedRectangle(cornerRadius: M3.shape.extraLarge)
                .strokeBorder(questionFocused ? M3.color.primary : .clear, lineWidth: 2))
        }
        .padding(12)
        .background(M3.color.card)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: M3.shape.large, bottomTrailingRadius: M3.shape.large))
    }

    private func attachmentRow(_ image: AssistantImage) -> some View {
        HStack(spacing: 12) {
            if let preview = image.preview {
                Image(nsImage: preview)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 56, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: M3.shape.small))
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Zrzut ekranu").font(M3.type.labelLarge).foregroundStyle(M3.color.onSurface)
                Text(image.sizeDescription).font(M3.type.bodySmall).foregroundStyle(M3.color.onSurfaceVariant)
            }
            Spacer()
            Button {
                attachment = nil
            } label: {
                Label("Usuń", systemImage: "xmark")
            }
            .buttonStyle(M3IconButtonStyle())
            .help("Usuń załącznik")
        }
        .padding(8)
        .m3Card(.outlined)
    }

    /// Z załącznikiem samo pytanie może być puste: zrzut bywa całą treścią.
    private var canSend: Bool {
        guard settings.assistantEnabled else { return false }
        return attachment != nil || !manualQuestion.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func send() {
        guard canSend else { return }
        let question = manualQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        recorder.ask(question, image: attachment)
        manualQuestion = ""
        attachment = nil
    }

    // MARK: - stan

    /// Banner M3: informacja z jedną akcją, na tonalnym kontenerze.
    private func meetingBanner(_ meeting: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "phone.fill")
                .font(.system(size: 14))
                .foregroundStyle(M3.color.onPrimary)
                .frame(width: 32, height: 32)
                .background(M3.color.primary, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("Trwa rozmowa w \(meeting)").font(M3.type.titleSmall)
                    .foregroundStyle(M3.color.onSecondaryContainer)
                Text("Zapisać transkrypt?").font(M3.type.bodySmall)
                    .foregroundStyle(M3.color.onSecondaryContainer.opacity(0.8))
            }
            Spacer()
            Button("Słuchaj") { Task { await recorder.start() } }
                .buttonStyle(M3ButtonStyle(kind: .filled, compact: true))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(M3.color.secondaryContainer, in: RoundedRectangle(cornerRadius: M3.shape.large))
    }

    private var statusLine: some View {
        VStack(spacing: 0) {
            if recorder.isProcessing { M3LinearProgress().padding(.horizontal, 16) }
            HStack(spacing: 8) {
                if recorder.isRunning {
                    Circle().fill(M3.color.error).frame(width: 8, height: 8)
                        .symbolEffect(.pulse)
                }
                Text(recorder.status)
                    .font(M3.type.labelMedium)
                    .foregroundStyle(M3.color.onSurfaceVariant)
                    .lineLimit(1)
                if (settings.identifySpeakers || settings.diarizeAfter) && recorder.speakerCount > 0 {
                    M3Chip(text: "\(recorder.speakerCount) \(recorder.speakerCount == 1 ? "głos" : "głosy")",
                           systemImage: "person.2.fill")
                        .scaleEffect(0.85)
                }
                Spacer()
                if copiedNote {
                    Label("Skopiowano dla Claude", systemImage: "checkmark")
                        .font(M3.type.labelMedium)
                        .foregroundStyle(M3.color.tertiary)
                }
                if let error = recorder.lastError {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(M3.type.labelMedium)
                        .foregroundStyle(M3.color.error)
                        .lineLimit(1)
                        .help(error)
                }
            }
            .padding(.horizontal, 20)
            .frame(height: 36)
        }
        .padding(.top, 4)
    }

    /// Skąd faktycznie idą podpowiedzi. Wcześniej pokazywał się tu zawsze
    /// model z API, także przy moście do Claude Code.
    private var assistantLabel: String {
        guard settings.assistantEnabled else { return "wyłączone" }
        switch settings.assistantBackend {
        case .claudeCode:
            let model = settings.claudeModel
            return "Claude Code · \(model.isEmpty ? "domyślny" : model)"
        case .api:
            return Models.named(settings.modelID)?.label ?? settings.modelID
        }
    }

    /// Notatka z podsumowaniem do schowka (pomysł z whistlera). Trwa kilka
    /// sekund, bo model pisze podsumowanie, stąd stan w etykiecie menu.
    private func exportForClaude() {
        exportingForClaude = true
        Task {
            defer { exportingForClaude = false }
            let note = (try? await recorder.claudeNote()) ?? recorder.markdown
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(note, forType: .string)
            copiedNote = true
            try? await Task.sleep(for: .seconds(3))
            copiedNote = false
        }
    }

    private func save(_ data: Data?, ext: String) {
        guard let data else { return }
        let panel = NSSavePanel()
        let base = recorder.importedMeta?.title ?? "rozmowa-\(TimeFormat.filenameStamp(recorder.startedAt ?? nowMs()))"
        panel.nameFieldStringValue = "\(base).\(ext)"
        panel.allowedContentTypes = [UTType(filenameExtension: ext) ?? .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url)
    }
}

/// Wypowiedź: awatar z inicjałem (jak w Gmailu), nazwa, czas, treść.
struct SegmentRow: View {
    let segment: Segment

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            SpeakerAvatar(name: segment.speaker)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(segment.speaker)
                        .font(M3.type.titleSmall)
                        .foregroundStyle(M3.color.onSurface)
                    Text(TimeFormat.offset(segment.offsetMs))
                        .font(M3.type.labelSmall.monospacedDigit())
                        .foregroundStyle(M3.color.onSurfaceVariant)
                    if !segment.final {
                        Text("w trakcie")
                            .font(M3.type.labelSmall)
                            .padding(.horizontal, 8).frame(height: 20)
                            .background(M3.color.tertiaryContainer, in: Capsule())
                            .foregroundStyle(M3.color.onTertiaryContainer)
                    }
                }
                Text(segment.text)
                    .font(M3.type.bodyLarge)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .foregroundStyle(segment.final ? M3.color.onSurface : M3.color.onSurfaceVariant)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Okrągły awatar z inicjałem. Kolor wynika z nazwy, więc ta sama osoba ma
/// ten sam kolor w całym transkrypcie; „Ty" zawsze dostaje primary.
struct SpeakerAvatar: View {
    let name: String

    private static let palette: [(Color, Color)] = [
        (M3.color.primaryContainer, M3.color.onPrimaryContainer),
        (M3.color.tertiaryContainer, M3.color.onTertiaryContainer),
        (M3.color.secondaryContainer, M3.color.onSecondaryContainer),
        (M3.color.cardField, M3.color.onSurfaceVariant),
    ]

    var body: some View {
        let colors: (Color, Color) = name == "Ty"
            ? (M3.color.primary, M3.color.onPrimary)
            : Self.palette[abs(stableHash(name)) % Self.palette.count]
        let digits = name.filter(\.isNumber)
        let initial = digits.isEmpty ? String(name.prefix(1)).uppercased() : String(digits.prefix(2))
        Text(initial)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(colors.1)
            .frame(width: 36, height: 36)
            .background(colors.0, in: Circle())
    }

    /// `hashValue` jest losowany per uruchomienie; kolor ma być stały.
    private func stableHash(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
    }
}

struct AnswerCard: View {
    let item: AssistantItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.hasImage ? "photo" : (item.auto ? "sparkles" : "person.wave.2"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(M3.color.primary)
                    .padding(.top, 1)
                Text(item.question)
                    .font(M3.type.titleSmall)
                    .foregroundStyle(M3.color.onSurface)
                    .lineLimit(3)
            }
            switch item.status {
            case .pending:
                // Licznik, nie sam kręciołek: przy moście do Claude Code
                // odpowiedź potrafi iść 5 s i bez tego wygląda to na zawieszenie.
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    HStack(spacing: 8) {
                        M3LinearProgress().frame(width: 80)
                        Text(String(format: "%.0f s", context.date.timeIntervalSince1970 - item.at / 1000))
                            .font(M3.type.labelSmall.monospacedDigit())
                            .foregroundStyle(M3.color.onSurfaceVariant)
                    }
                }
            case .streaming, .done:
                MarkdownText(text: item.answer)
                    .foregroundStyle(M3.color.onSurface)
            case .error:
                Text(item.error ?? "Błąd")
                    .font(M3.type.bodyMedium)
                    .foregroundStyle(M3.color.error)
            }
            if let ttft = item.ttftMs {
                // Zmierzony czas do pierwszego tokenu: jedyna latencja, którą
                // widać w trakcie rozmowy.
                Text("pierwszy token: \(Int(ttft)) ms")
                    .font(M3.type.labelSmall.monospacedDigit())
                    .foregroundStyle(M3.color.onSurfaceVariant)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(M3.color.cardInset, in: RoundedRectangle(cornerRadius: M3.shape.medium))
    }
}

/// Wybór pliku do importu: wspólny dla okna i menu w pasku.
@MainActor
enum ImportPanel {
    static func run(_ recorder: Recorder) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = MediaImport.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Wybierz nagranie albo wideo do transkrypcji"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        recorder.importFile(url)
    }
}
