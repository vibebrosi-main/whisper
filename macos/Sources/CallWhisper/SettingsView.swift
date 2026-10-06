import SwiftUI
import CallWhisperKit
import CallWhisperCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var obs: OBSLink
    @State private var probeResult: String?
    @State private var probing = false
    @State private var modelStatus: String = "sprawdzam…"
    @State private var whisperStatus: String = "sprawdzam…"
    @State private var appleSupportsLanguage = false

    /// Bufor lokalny, celowo nie związany wprost z Keychainem.
    ///
    /// Wiązanie `SecureField` prosto do `settings.apiKey` zapisywało klucz przy
    /// każdym naciśnięciu klawisza i odczytywało go przy każdym przerysowaniu.
    /// Gdy zapis się nie udawał, pole gubiło tekst w trakcie pisania, a do
    /// Keychaina trafiały niepełne klucze.
    @State private var keyDraft = ""
    @State private var keySaved: Bool?

    private var obsStatus: String {
        switch obs.state {
        case .off: return "Wyłączone"
        case .waiting: return "OBS nie działa. „Słuchaj” uruchomi go sam."
        case .serverDisabled: return "W OBS włącz serwer: Narzędzia → Ustawienia serwera WebSocket → Włącz serwer WebSocket"
        case .wrongPassword: return "OBS odrzucił hasło. Zapisz ustawienia serwera WebSocket w OBS jeszcze raz."
        case .connected: return "Połączono z OBS"
        case .recording: return "OBS nagrywa, call-whisper słucha"
        }
    }

    var body: some View {
        TabView {
            general.tabItem { Label("Ogólne", systemImage: "gear") }
            speech.tabItem { Label("Mowa", systemImage: "waveform") }
            assistantTab.tabItem { Label("Asystent", systemImage: "sparkles") }
        }
        .frame(width: 500)
        .task { await refreshModelStatus() }
        .onAppear { keyDraft = settings.apiKey }
    }

    private var general: some View {
        Form {
            TextField("Tytuł rozmowy", text: Binding(
                get: { settings.title }, set: { settings.title = $0 }))
                .help("Trafia do nagłówka i frontmattera pliku .md")

            Section("Kontekst projektu") {
                LabeledContent("Plik") {
                    HStack {
                        Text(contextStatus).foregroundStyle(.secondary).lineLimit(1)
                        Button("Wybierz…") { pickProjectContext() }
                            .controlSize(.small)
                        if !settings.projectContextPath.isEmpty {
                            Button("Wyczyść") { settings.projectContextPath = "" }
                                .controlSize(.small)
                        }
                    }
                }
                Text("Opis projektu, o którym rozmawiasz — architektura, decyzje, nazwy klas. Trafia do każdego pytania jako tło, więc model odpowiada „jak jest zrobione”, a nie zgaduje. Limit 8000 znaków.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Słuchaj też mikrofonu", isOn: Binding(
                get: { settings.useMicrophone }, set: { settings.useMicrophone = $0 }))
                .help("Włącz tylko wtedy, gdy Twój własny głos ma trafić do transkryptu")

            if settings.useMicrophone {
                Text("Na głośnikach mikrofon łapie echo i każda wypowiedź pojawi się dwa razy — raz jako „Rozmówcy”, raz jako „Ty”. Na słuchawkach problem znika.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("Nagrywany jest wyłącznie dźwięk systemu — to, co słychać z rozmowy albo z odtwarzanego materiału.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Wykrywanie rozmów") {
                Toggle("Powiadamiaj, gdy zaczyna się rozmowa", isOn: Binding(
                    get: { settings.detectMeetings }, set: { settings.detectMeetings = $0 }))
                if settings.detectMeetings {
                    Toggle("Zaczynaj i kończ nasłuch samodzielnie", isOn: Binding(
                        get: { settings.autoStartOnMeeting }, set: { settings.autoStartOnMeeting = $0 }))
                }
                Text("Rozmowa to mikrofon w użyciu plus działający Zoom, Teams, FaceTime, Slack, Discord, Webex albo przeglądarka na pierwszym planie (Google Meet). Sprawdzane co 2 s, bez żadnych dodatkowych zgód.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("OBS") {
                Toggle("Nagrywaj wideo w OBS razem z nasłuchem", isOn: Binding(
                    get: { settings.followOBS }, set: { settings.followOBS = $0 }))
                if settings.followOBS {
                    Text(obsStatus).font(.caption)
                        .foregroundStyle(obs.state == .connected || obs.state == .recording ? Color.secondary : Color.orange)
                }
                Text("„Słuchaj” uruchamia OBS, jeśli nie działa, i włącza w nim nagrywanie; „Zatrzymaj” je kończy i zapisuje transkrypt obok pliku wideo, z tą samą nazwą i rozszerzeniem .md. Czasy liczą się od początku nagrania, więc zgadzają się z osią filmu. Działa też odwrotnie: nagranie włączone w OBS włącza nasłuch. Hasło i port czytamy z ustawień OBS.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Eksport") {
                Picker("Język pliku", selection: Binding(
                    get: { settings.markdownLocale }, set: { settings.markdownLocale = $0 })) {
                    Text("polski").tag("pl")
                    Text("angielski").tag("en")
                }
                Toggle("Znaczniki czasu jako godzina zegarowa", isOn: Binding(
                    get: { settings.absoluteTimestamps }, set: { settings.absoluteTimestamps = $0 }))
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var speech: some View {
        Form {
            Picker("Język mowy", selection: Binding(
                get: { settings.language }, set: { settings.language = $0 })) {
                Text("polski").tag("pl-PL")
                Text("angielski (US)").tag("en-US")
                Text("angielski (UK)").tag("en-GB")
                Text("niemiecki").tag("de-DE")
                Text("hiszpański").tag("es-ES")
                Text("francuski").tag("fr-FR")
            }
            .onChange(of: settings.language) { _, _ in Task { await refreshModelStatus() } }

            Toggle("Rozpoznawaj, kto mówi", isOn: Binding(
                get: { settings.identifySpeakers }, set: { settings.identifySpeakers = $0 }))
                .help("Klastrowanie MFCC — podejście sprzed ery sieci neuronowych. Rozdziela wyraźnie różne głosy, ale podobne potrafi rozsypać na kilka etykiet.")

            if !settings.identifySpeakers {
                Text("Wyłączone. Podział „Ty” (mikrofon) vs „Rozmówcy” (dźwięk systemu) działa dalej — on nie zgaduje niczego po głosie.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Rozpoznawaj głosy po rozmowie (sieć neuronowa)", isOn: Binding(
                get: { settings.diarizeAfter }, set: { settings.diarizeAfter = $0 }))
                .help("pyannote + CAM++ przez sherpa-onnx, jak w OpenWhispr. Działa na całym nagraniu naraz, więc widzi wszystkie głosy, zanim zdecyduje.")
            if settings.diarizeAfter {
                Text(Engines.canDiarize
                     ? "Po zatrzymaniu „Rozmówcy” rozpadną się na „Rozmówca 1”, „Rozmówca 2”… Działa też przy imporcie nagrań. Audio sesji leży w katalogu tymczasowym tylko do końca rozpoznawania."
                     : "Przy pierwszym użyciu pobierze silnik i modele (~100 MB). Po zatrzymaniu „Rozmówcy” rozpadną się na „Rozmówca 1”, „Rozmówca 2”…")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Picker("Silnik", selection: Binding(
                get: { settings.asrBackend }, set: { settings.asrBackend = $0 })) {
                ForEach(ASRBackend.allCases, id: \.self) { backend in
                    Text(backend.label).tag(backend)
                }
            }

            if settings.asrBackend == .appleSpeech && !appleSupportsLanguage {
                Label("Rozpoznawanie Apple nie obsługuje języka \(settings.language). Wybierz whisper.cpp albo zmień język.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }

            if settings.asrBackend == .appleSpeech {
                LabeledContent("Model mowy") {
                    HStack {
                        Text(modelStatus).foregroundStyle(.secondary)
                        Button("Odśwież") { Task { await refreshModelStatus() } }
                            .controlSize(.small)
                    }
                }
            }

            if settings.asrBackend == .whisperLocal {
                Section("whisper.cpp") {
                    Picker("Model", selection: Binding(
                        get: { settings.whisperModel }, set: { settings.whisperModel = $0 })) {
                        ForEach(WhisperServer.installedModels(), id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                    Text("`small` — 13,3 % błędnych słów po polsku, ~930 ms. `large-v3-turbo` schodzi do 10,0 %, ale kosztuje ~1,6 s na rundę i 1,6 GB pamięci.")
                        .font(.caption).foregroundStyle(.secondary)

                    TextField("Słownictwo rozmowy", text: Binding(
                        get: { settings.whisperVocabulary }, set: { settings.whisperVocabulary = $0 }),
                              prompt: Text("np. React, Next.js, Nuxt, Vue, Pinia"), axis: .vertical)
                        .lineLimit(2...4)
                    Text("Nazwy technologii, firm i osób, które padną w rozmowie. Dzięki nim `small` pisze „React, Next.js” zamiast „Reads Finex Js” i nie trzeba wolniejszego modelu.")
                        .font(.caption).foregroundStyle(.secondary)

                    Toggle("Uruchamiaj serwer automatycznie", isOn: Binding(
                        get: { settings.autoStartWhisper }, set: { settings.autoStartWhisper = $0 }))

                    LabeledContent("Serwer") {
                        HStack {
                            Text(whisperStatus).foregroundStyle(.secondary)
                            Button("Sprawdź") { Task { await refreshWhisperStatus() } }
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .task { await refreshWhisperStatus() }
    }

    private var assistantTab: some View {
        Form {
            Toggle("Podpowiadaj w rozmowie", isOn: Binding(
                get: { settings.assistantEnabled }, set: { settings.assistantEnabled = $0 }))

            Toggle("Pytaj automatycznie po wykryciu pytania", isOn: Binding(
                get: { settings.autoAsk }, set: { settings.autoAsk = $0 }))
                .disabled(!settings.assistantEnabled)
                .help("Pytania lecą do modelu w momencie wykrycia, a nie po kliknięciu — odpowiedź ma czekać, zanim ktoś na nią spojrzy")

            Section("Skąd biorą się podpowiedzi") {
                Picker("Źródło", selection: Binding(
                    get: { settings.assistantBackend }, set: { settings.assistantBackend = $0 })) {
                    ForEach(AssistantBackend.allCases, id: \.self) { backend in
                        Text(backend.label).tag(backend)
                    }
                }

                if settings.assistantBackend == .claudeCode {
                    if ClaudeBridge.isAvailable {
                        Picker("Model", selection: Binding(
                            get: { settings.claudeModel }, set: { settings.claudeModel = $0 })) {
                            ForEach(Models.claudeCodeModels, id: \.id) { model in
                                Text(model.label).tag(model.id)
                            }
                        }
                        Text("Bez klucza API i bez dodatkowych opłat — pytania idą przez Twoje lokalne CLI Claude Code. Pierwsze pytanie po starcie kosztuje ~3,9 s, kolejne ~1,8 s; proces jest rozgrzewany przy starcie nasłuchu.")
                            .font(.caption).foregroundStyle(.secondary)
                        Text("Sonnet odpowiada najszybciej: pierwsze słowo po ~1-2 s (zmierzone 2026-10-06). Haiku bywa niedostępny.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("Nie znalazłem CLI `claude`. Zainstaluj Claude Code albo przełącz się na API.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                    }
                }
            }

            if settings.assistantBackend == .api {
                Section("Model") {
                    Picker("Model", selection: Binding(
                        get: { settings.modelID }, set: { settings.modelID = $0 })) {
                        ForEach(Models.all, id: \.id) { model in
                            Text(model.label).tag(model.id)
                        }
                    }
                    if let model = Models.named(settings.modelID), let ttft = model.measuredTtftMs {
                        LabeledContent("Zmierzony pierwszy token") {
                            Text("\(ttft) ms").monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    if Models.named(settings.modelID)?.free == true {
                        Text("Modele darmowe bywają odrzucane błędem 429 przy większym ruchu. Jeśli podpowiedzi zaczną znikać, to jest tego powód.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if settings.assistantBackend == .api {
            Section("Klucz API") {
                SecureField("xpl_…", text: $keyDraft)
                    .onSubmit(saveKey)

                HStack {
                    Button("Zapisz klucz", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines) == settings.apiKey)
                    if let keySaved {
                        Label(keySaved ? "Zapisany" : "Nie udało się zapisać",
                              systemImage: keySaved ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.callout)
                            .foregroundStyle(keySaved ? .green : .orange)
                    }
                }

                Text("Trzymany w pliku z prawami 0600 (tylko Twoje konto), nie w ustawieniach. Bez pytań o hasło do pęku kluczy. Białe znaki są przycinane - wklejony klucz z końcem linii dawałby 401.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button(probing ? "Sprawdzam…" : "Sprawdź klucz i model") {
                        Task { await probe() }
                    }
                    .disabled(probing || settings.apiKey.isEmpty)
                    if let probeResult {
                        Text(probeResult).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func saveKey() {
        keySaved = settings.setAPIKey(keyDraft)
        keyDraft = settings.apiKey
        probeResult = nil
    }

    /// Krótki opis stanu pliku kontekstu — nazwa i rozmiar albo powód braku.
    private var contextStatus: String {
        let path = settings.projectContextPath
        guard !path.isEmpty else { return "brak" }
        let name = (path as NSString).lastPathComponent
        let chars = settings.projectContext.count
        return chars > 0 ? "\(name) — \(chars) znaków" : "\(name) — nie znaleziono"
    }

    private func pickProjectContext() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.plainText, .text]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.message = "Wybierz plik z opisem projektu"
        if let current = URL(string: "file://" + settings.projectContextPath) {
            panel.directoryURL = current.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.projectContextPath = url.path
    }

    private func refreshWhisperStatus() async {
        let client = WhisperClient(endpoint: URL(string: "http://127.0.0.1:\(settings.whisperPort)")!,
                                   language: settings.language)
        if await client.health() {
            whisperStatus = "działa na porcie \(settings.whisperPort)"
        } else if WhisperServer.locateBinary() == nil {
            whisperStatus = "silnik pobierze się sam przy nasłuchu"
        } else if WhisperServer.installedModels().isEmpty {
            whisperStatus = "brak modeli w ~/.cache/whisper-models"
        } else {
            whisperStatus = settings.autoStartWhisper ? "wystartuje przy nasłuchu" : "nie działa"
        }
    }

    private func refreshModelStatus() async {
        appleSupportsLanguage = await SpeechRecognizer.isSupported(locale: settings.locale)
        switch await SpeechRecognizer.modelStatus(locale: settings.locale) {
        case .installed: modelStatus = "zainstalowany"
        case .supported: modelStatus = "do pobrania (pobierze się przy starcie)"
        case .downloading: modelStatus = "pobieranie…"
        case .unsupported: modelStatus = "język nieobsługiwany"
        }
    }

    private func probe() async {
        probing = true
        defer { probing = false }
        let client = AssistantClient()
        switch await client.probe(apiKey: settings.apiKey, model: settings.modelID) {
        case .success(let ttft): probeResult = "OK, pierwszy token \(Int(ttft)) ms"
        case .failure(let error): probeResult = error.localizedDescription
        }
    }
}
