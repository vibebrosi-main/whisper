import SwiftUI
import AppKit
import CallWhisperKit

/// Przechwytuje ⌘V na poziomie okna i oddaje obrazek ze schowka.
///
/// Dwa powody, dla których nie wystarcza `.onPasteCommand` ani przycisk:
///
///  1. `TextField` sam obsługuje ⌘V i potrafi zjeść zdarzenie, zanim dotrze
///     do modyfikatora SwiftUI. W nakładce jest gorzej, bo to okno
///     nieaktywujące i routing skrótów bywa tam nieoczywisty.
///  2. Stan schowka wyliczany w `body` **nie odświeża się**, gdy użytkownik
///     kopiuje coś po narysowaniu widoku — przycisk zostawał wyszarzony,
///     mimo że zrzut był już w schowku. Stąd `changeCount` odpytywany
///     cyklicznie zamiast sprawdzania w locie.
@MainActor
final class PasteWatcher: ObservableObject {
    /// Czy w schowku jest w tej chwili obrazek. Odświeżane, nie wyliczane w `body`.
    @Published private(set) var hasImage = false

    private var monitor: Any?
    private var timer: Timer?
    private var lastChangeCount = -1
    private var onPaste: ((AssistantImage) -> Void)?

    func start(onPaste: @escaping (AssistantImage) -> Void) {
        guard monitor == nil else { return }
        self.onPaste = onPaste

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "v"
            else { return event }

            let pasteboard = NSPasteboard.general
            // Zdarzenie połykamy TYLKO wtedy, gdy w schowku jest obrazek i nie
            // ma tekstu — inaczej zwykłe wklejanie tekstu przestałoby działać.
            let hasText = pasteboard.string(forType: .string)?.isEmpty == false
            guard !hasText, let image = AssistantImage.fromPasteboard(pasteboard) else {
                return event
            }
            self.onPaste?(image)
            return nil
        }

        // Schowek nie powiadamia o zmianach — trzeba go odpytywać.
        let timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        refresh()
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timer?.invalidate()
        timer = nil
    }

    private func refresh() {
        let count = NSPasteboard.general.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        hasImage = AssistantImage.pasteboardHasImage()
    }

    // Bez `deinit`: sprzątanie idzie przez `stop()` wołane z `onDisappear`.
    // Dostęp do monitora i timera z nieizolowanego `deinit` nie przechodzi
    // kontroli współbieżności, a duplikowanie tej logiki nic by nie dało.
}
