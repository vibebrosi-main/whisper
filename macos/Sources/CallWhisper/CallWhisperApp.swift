import SwiftUI
import UserNotifications
import CallWhisperKit
import CallWhisperCore

/// Właściciel obiektów, które żyją dłużej niż okno: nasłuch i wykrywanie
/// rozmów. Okno główne da się zamknąć, a powiadomienie „Wykryto rozmowę"
/// ma dalej umieć uruchomić nasłuch.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let recorder = Recorder()
    let meetings = MeetingWatcher()
    let obs = OBSLink()
    private let settings = AppSettings.shared
    /// Nasłuch włączony przez wykrywanie — tylko taki wolno nam samym zatrzymać.
    private var autoStarted = false

    nonisolated private static let category = "meeting"
    nonisolated private static let listenAction = "listen"

    /// Powiadomienia wymagają paczki `.app`; uruchomione przez `swift run`
    /// `UNUserNotificationCenter` wywala proces.
    private var canNotify: Bool { Bundle.main.bundleIdentifier != nil }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if canNotify {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            let listen = UNNotificationAction(identifier: Self.listenAction, title: "Słuchaj", options: [])
            center.setNotificationCategories([UNNotificationCategory(
                identifier: Self.category, actions: [listen], intentIdentifiers: [])])
        }
        meetings.onChange = { [weak self] change in self?.handle(change) }
        syncMeetingDetection()
        recorder.obs = obs
        obs.onRecordStart = { [weak self] origin in self?.obsRecordingStarted(at: origin) }
        obs.onRecordStop = { [weak self] path in self?.obsRecordingStopped(path: path) }
        syncOBS()
    }

    func syncOBS() {
        if settings.followOBS { obs.start() } else { obs.stop() }
    }

    /// Nagranie włączone ręcznie w OBS. Gdy to call-whisper je włączył,
    /// `OBSLink` tego zdarzenia tu nie przekazuje.
    private func obsRecordingStarted(at origin: Double) {
        guard !recorder.isRunning, !recorder.isProcessing else {
            notify("OBS nagrywa, ale call-whisper już słucha",
                   body: "Czasy w transkrypcie nie pokryją się z filmem. Zatrzymaj nasłuch i zacznij nagranie od nowa.",
                   action: false)
            return
        }
        autoStarted = false
        Task { await recorder.start(origin: origin) }
    }

    /// Nagranie zatrzymane w OBS kończy też nasłuch, a transkrypt ląduje
    /// obok pliku wideo.
    private func obsRecordingStopped(path: String?) {
        guard recorder.isRunning, recorder.isOBSSession else { return }
        Task { await recorder.stop(recordingPath: path) }
    }

    /// Plik upuszczony na ikonę w Docku albo otwarty z Findera
    /// („Otwórz za pomocą") trafia prosto do importu.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { MediaImport.fileExtensions.contains($0.pathExtension.lowercased()) })
        else { return }
        recorder.importFile(url)
    }

    func syncMeetingDetection() {
        if settings.detectMeetings {
            meetings.start()
            if canNotify {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
        } else {
            meetings.stop()
        }
    }

    private func handle(_ change: MeetingDetection.Debouncer.Change) {
        switch change {
        case .started(let app):
            guard !recorder.isRunning, !recorder.isProcessing else { return }
            if settings.autoStartOnMeeting {
                autoStarted = true
                Task { await recorder.start() }
                notify("Słucham rozmowy w \(app)", body: "Transkrypt zbiera się w call-whisper.", action: false)
            } else {
                notify("Wykryto rozmowę w \(app)", body: "Zapisać transkrypt?", action: true)
            }
        case .ended:
            guard autoStarted, recorder.isRunning else { return }
            autoStarted = false
            Task { await recorder.stop() }
        }
    }

    private func notify(_ title: String, body: String, action: Bool) {
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if action { content.categoryIdentifier = Self.category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "meeting-\(UUID().uuidString)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let identifier = response.actionIdentifier
        let isMeeting = response.notification.request.content.categoryIdentifier == Self.category
        await MainActor.run {
            // Kliknięcie samego powiadomienia też liczymy jako „tak" — jedyne,
            // co ono proponuje, to nasłuch.
            guard isMeeting, identifier == Self.listenAction || identifier == UNNotificationDefaultActionIdentifier,
                  !recorder.isRunning else { return }
            Task { await recorder.start() }
        }
    }

    /// Powiadomienie ma się pokazać także wtedy, gdy aplikacja jest na wierzchu.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

// Wejście jest w main.swift — tam rozstrzygamy między UI a trybem --probe.
struct CallWhisperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var settings = AppSettings.shared
    @State private var overlay = OverlayController()

    private var recorder: Recorder { delegate.recorder }

    var body: some Scene {
        Window("call-whisper", id: "main") {
            MainView(recorder: recorder, settings: settings, overlay: overlay, meetings: delegate.meetings)
                .frame(minWidth: 720, minHeight: 500)
        }
        // Pasek tytułu ukryty: jego miejsce zajmuje górny pasek aplikacji M3.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 680)

        // Ikona w pasku menu — odpowiednik ikony rozszerzenia z wersji webowej.
        // Licznik pokazuje liczbę zarejestrowanych wypowiedzi, kropka nasłuch.
        MenuBarExtra {
            MenuBarView(recorder: recorder, settings: settings, overlay: overlay, meetings: delegate.meetings)
        } label: {
            MenuBarLabel(recorder: recorder)
        }

        Settings {
            SettingsView(settings: settings, obs: delegate.obs)
                .tint(M3.color.primary)
                .onChange(of: settings.detectMeetings) { _, _ in delegate.syncMeetingDetection() }
                .onChange(of: settings.followOBS) { _, _ in delegate.syncOBS() }
        }
    }
}

/// Osobny widok, bo `App` nie obserwuje obiektu trzymanego przez delegata —
/// ikona nie zmieniałaby się przy starcie nasłuchu.
struct MenuBarLabel: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: recorder.isRunning ? "waveform.circle.fill" : "waveform.circle")
            if recorder.isRunning && !recorder.segments.isEmpty {
                Text("\(recorder.segments.count)")
            }
        }
    }
}

struct MenuBarView: View {
    @ObservedObject var recorder: Recorder
    @ObservedObject var settings: AppSettings
    var overlay: OverlayController
    @ObservedObject var meetings: MeetingWatcher

    var body: some View {
        Button(recorder.isRunning ? "Zatrzymaj" : "Słuchaj rozmowy") {
            Task { recorder.isRunning ? await recorder.stop() : await recorder.start() }
        }
        .disabled(recorder.status == "Zatrzymuję…" || recorder.isProcessing)
        .keyboardShortcut("l")

        Text(recorder.status)
        if let meeting = meetings.activeMeeting, !recorder.isRunning {
            Text("Trwa rozmowa w \(meeting)")
        }
        if !recorder.readiness.allGood {
            Text("⚠︎ Sprawdź gotowość w oknie głównym")
        }

        Divider()

        Button("Importuj nagranie…") { ImportPanel.run(recorder) }
            .disabled(recorder.isRunning || recorder.isProcessing)

        Button("Kopiuj Markdown") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(recorder.markdown, forType: .string)
        }
        .disabled(recorder.segments.isEmpty)

        Toggle("Podpowiedzi AI", isOn: Binding(
            get: { settings.assistantEnabled },
            set: { settings.assistantEnabled = $0 }))

        Button(overlay.isVisible ? "Ukryj nakładkę" : "Pokaż nakładkę") {
            overlay.toggle(recorder: recorder)
        }

        Divider()
        Button("Zakończ") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
