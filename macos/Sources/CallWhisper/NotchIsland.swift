import SwiftUI
import AppKit
import Combine
import CallWhisperKit
import CallWhisperCore

/// Podpowiedzi w notchu, w stylu Dynamic Island (Atoll, boring.notch).
///
/// Nakładka w rogu ekranu ma jedną wadę: wzrok musi uciec od kamery, a na
/// rozmowie widać, że czytasz. Notch jest dokładnie nad kamerą, więc
/// podpowiedź czytana stamtąd wygląda jak patrzenie w oczy rozmówcy.
///
/// Trzy stany:
///  - ukryta: bez nasłuchu nic nie wystaje poza notch;
///  - nasłuch: „uszy" po bokach notcha, kropka i czas rozmowy;
///  - podpowiedź: wyspa rozwija się w dół, pytanie i odpowiedź na żywo.
///    Zwija się sama po czasie potrzebnym na przeczytanie, chyba że kursor
///    jest nad nią.
///
/// Na ekranie bez notcha ta sama wyspa wisi tuż pod paskiem menu.
@MainActor
final class NotchIslandController {
    private var panel: NotchPanel?
    private var host: NSHostingView<NotchIslandView>?
    /// Stan wyspy. Widok dostaje go jako wartość przy każdej zmianie
    /// (`render()`), a nie przez obserwowany obiekt: w panelu nad paskiem
    /// menu `ObservableObject` nie odświeżał widoku - zmiany modelu
    /// docierały, a na ekranie wisiało „Myślę…" (zmierzone na --notch-demo).
    private var model = NotchIslandState() { didSet { render() } }
    private var subscriptions: Set<AnyCancellable> = []
    private var collapseTask: Task<Void, Never>?
    private var shownAnswerID: String?
    /// Do kiedy odpowiedź ma zostać na ekranie, żeby dało się ją przeczytać.
    private var readUntil = Date.distantPast
    private weak var recorder: Recorder?

    var isActive: Bool { panel != nil }

    /// `call-whisper --notch-demo`, ustawiane w `main.swift`.
    nonisolated(unsafe) static var demoRequested = false

    func start(recorder: Recorder) {
        guard panel == nil else { return }
        self.recorder = recorder

        panel = makePanel()

        recorder.$isRunning.combineLatest(recorder.$answers, recorder.$startedAt)
            .receive(on: RunLoop.main)
            .sink { [weak self] running, answers, startedAt in
                self?.update(running: running, answers: answers, startedAt: startedAt)
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.layout() }
            .store(in: &subscriptions)
    }

    func stop() {
        subscriptions.removeAll()
        collapseTask?.cancel()
        panel?.orderOut(nil)
        panel = nil
        host = nil
        model.mode = .hidden
    }

    /// `call-whisper --notch-demo`: przejście przez wszystkie stany na
    /// prawdziwym ekranie, bez rozmowy i bez modelu. Do pracy nad wyglądem.
    func demo() async {
        let recorder = Recorder()
        self.recorder = recorder
        let panel = makePanel()
        // W demie wyspa ma być widoczna na zrzutach ekranu; w rozmowie nie.
        panel.sharingType = .readOnly
        self.panel = panel

        // Jak w nasłuchu (`Recorder`): bez tego App Nap dławi demo w tle.
        let activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "Demo wyspy w notchu")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let started = nowMs()
        let session = AssistantSession()
        func push() { update(running: true, answers: session.all, startedAt: started) }
        push()
        try? await Task.sleep(for: .seconds(3))
        let item = session.add(question: "Jak radzisz sobie z presją czasu?", auto: true)
        push()
        try? await Task.sleep(for: .seconds(2.5))
        let answer = "Najpierw tnę zakres, nie jakość: ustalam z zespołem, co musi wyjść na termin, a co może poczekać. Dowożę małymi krokami, codziennie coś działa na produkcji, więc presja nie kumuluje się na koniec sprintu."
        for word in answer.split(separator: " ") {
            session.append(item.id, delta: word + " ")
            push()
            try? await Task.sleep(for: .milliseconds(70))
        }
        session.complete(item.id)
        push()
        try? await Task.sleep(for: .seconds(Self.readingTime(answer) + 2))
    }

    // MARK: - stan

    private func update(running: Bool, answers: [AssistantItem], startedAt: Double?) {
        model.running = running
        model.startedAt = startedAt
        model.item = answers.last

        if let last = answers.last {
            // Nowe pytanie rozwija wyspę od razu, zanim przyjdzie odpowiedź:
            // samo „myślę" mówi, że pomoc jest w drodze.
            if last.id != shownAnswerID, last.status == .pending || last.status == .streaming {
                shownAnswerID = last.id
                collapseTask?.cancel()
                collapseTask = nil
                set(.expanded)
                return
            }
            if model.mode == .expanded, last.status == .done || last.status == .error,
               collapseTask == nil, !model.hovering, !model.pinned {
                let reading = Self.readingTime(last.answer)
                readUntil = Date().addingTimeInterval(reading)
                scheduleCollapse(after: reading)
            }
        }
        if model.mode != .expanded { set(running ? .compact : .hidden) } else { layout() }
    }

    /// Ile trzeba, żeby przeczytać odpowiedź na głos: ~2,5 słowa na sekundę
    /// mówione, plus zapas na start. Krócej niż 8 s nie ma sensu.
    static func readingTime(_ text: String) -> Double {
        max(8, Double(Text.wordCount(text)) / 2.5 + 4)
    }

    private func scheduleCollapse(after seconds: Double) {
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self else { return }
            self.collapseTask = nil
            guard !self.model.hovering, !self.model.pinned else { return }
            self.set(self.model.running ? .compact : .hidden)
        }
    }

    private func hoverChanged(_ hovering: Bool) {
        guard model.hovering != hovering else { return }
        model.hovering = hovering
        if hovering {
            collapseTask?.cancel()
            collapseTask = nil
            // Najechanie na „uszy" pokazuje ostatnią podpowiedź jeszcze raz.
            if model.mode == .compact, model.item != nil { set(.expanded) }
        } else if model.mode == .expanded, !model.pinned, !answering {
            // Wyspa rozwinięta pod kursorem nie może zniknąć 1,5 s po jego
            // odsunięciu, zanim odpowiedź da się przeczytać: wraca reszta
            // czasu czytania.
            scheduleCollapse(after: max(1.5, readUntil.timeIntervalSinceNow))
        }
    }

    /// Odpowiedź w drodze - wtedy wyspa nie zwija się wcale.
    private var answering: Bool {
        model.item?.status == .pending || model.item?.status == .streaming
    }

    private func handle(_ action: NotchIslandView.Action) {
        switch action {
        case .copy:
            guard let answer = model.item?.answer, !answer.isEmpty else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
        case .pin:
            model.pinned.toggle()
            if !model.pinned, !model.hovering, !answering {
                scheduleCollapse(after: max(1.5, readUntil.timeIntervalSinceNow))
            }
        case .collapse:
            model.pinned = false
            collapseTask?.cancel()
            collapseTask = nil
            set(model.running ? .compact : .hidden)
        case .toggleListening:
            guard let recorder else { return }
            Task { recorder.isRunning ? await recorder.stop() : await recorder.start() }
        }
    }

    // MARK: - okno

    private func view() -> NotchIslandView {
        NotchIslandView(state: model,
                        onHover: { [weak self] in self?.hoverChanged($0) },
                        onAction: { [weak self] in self?.handle($0) })
    }

    private func render() { host?.rootView = view() }

    private func makePanel() -> NotchPanel {
        let panel = NotchPanel()
        let host = NSHostingView(rootView: view())
        self.host = host
        // Rozmiar okna ustawiamy sami. Z domyślnymi opcjami NSHostingView
        // przy każdym `setFrame` przeliczał rozmiar z SwiftUI i przepychał się
        // z oknem: przy odpowiedzi napływającej co 70 ms główny wątek się
        // zapychał, a wyspa stała na „Myślę…" z niedokończoną animacją.
        host.sizingOptions = []
        // Hosting view w zwykłym kontenerze na autoresizingu, a nie jako
        // `contentView`: inaczej każda zmiana rozmiaru okna szła przez
        // constrainty okna i przy odpowiedzi napływającej co kilkadziesiąt ms
        // AppKit rzucał wyjątkiem o pętli „Update Constraints" (crash).
        let container = NSView()
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        panel.contentView = container
        host.frame = container.bounds
        return panel
    }

    private func set(_ mode: NotchIslandState.Mode) {
        guard model.mode != mode else { return }
        let growing = mode.rank > model.mode.rank
        // Okno rośnie przed animacją, a maleje po niej: inaczej wyspa byłaby
        // ucięta w połowie ruchu. Samą animację robi widok (`.animation`).
        if growing { layout(for: mode) }
        model.mode = mode
        if !growing {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(420))
                guard let self, self.model.mode == mode else { return }
                self.layout(for: mode)
            }
        }
    }

    private func layout() { layout(for: model.mode) }

    private func layout(for mode: NotchIslandState.Mode) {
        guard let panel else { return }
        let screen = NotchGeometry.screen
        let geometry = NotchGeometry(screen: screen)
        // Publikujemy tylko zmianę: każda publikacja to przebieg widoku.
        if model.geometry != geometry { model.geometry = geometry }
        guard mode != .hidden else { panel.orderOut(nil); return }
        let size = geometry.size(for: mode, item: model.item)
        // W notchu wyspa przylega do górnej krawędzi; bez notcha wisi pod
        // paskiem menu, którego nie zasłania.
        let top = geometry.hasNotch ? screen.frame.maxY : screen.visibleFrame.maxY - NotchGeometry.pillGap
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height,
                           width: size.width, height: size.height)
        guard panel.frame != frame || !panel.isVisible else { return }
        // Poza bieżącą transakcją SwiftUI: zmiana rozmiaru w jej trakcie
        // unieważniała widok, który właśnie się układał.
        DispatchQueue.main.async {
            panel.setFrame(frame, display: false)
            panel.orderFrontRegardless()
        }
    }
}

/// Stan wyspy, niezależny od `Recorder` - widok da się wyrenderować
/// z przykładowych danych (`--snapshot`).
struct NotchIslandState: Equatable {
    enum Mode: Equatable {
        case hidden, compact, expanded
        var rank: Int { self == .hidden ? 0 : self == .compact ? 1 : 2 }
    }

    var mode: Mode = .hidden
    var running = false
    var startedAt: Double?
    var item: AssistantItem?
    var hovering = false
    var pinned = false
    var geometry = NotchGeometry(notchWidth: 0, notchHeight: 24, hasNotch: false)
}

/// Wymiary notcha i wyspy na danym ekranie.
struct NotchGeometry: Equatable {
    /// Szerokość i wysokość wycięcia; na ekranie bez notcha zero i wysokość
    /// paska menu.
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool

    static let earWidth: CGFloat = 74
    static let expandedWidth: CGFloat = 560
    /// Pasek statusu wyspy bez notcha.
    static let pillHeight: CGFloat = 30
    /// Odstęp pigułki od paska menu.
    static let pillGap: CGFloat = 6

    /// Ekran z notchem, jeśli jest podłączony; inaczej główny.
    @MainActor static var screen: NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    @MainActor init(screen: NSScreen) {
        let top = screen.safeAreaInsets.top
        if top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            notchWidth = screen.frame.width - left.width - right.width
            notchHeight = top
        } else {
            hasNotch = false
            notchWidth = 0
            notchHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
        }
    }

    init(notchWidth: CGFloat, notchHeight: CGFloat, hasNotch: Bool) {
        self.notchWidth = notchWidth; self.notchHeight = notchHeight; self.hasNotch = hasNotch
    }

    /// Wysokość paska statusu: w notchu tyle co wycięcie, bez notcha pigułka.
    var headerHeight: CGFloat { hasNotch ? notchHeight : Self.pillHeight }

    func size(for mode: NotchIslandState.Mode, item: AssistantItem? = nil) -> CGSize {
        switch mode {
        case .hidden, .compact:
            // Bez notcha „uszy" nie mają czego obejmować: zostaje sama pigułka.
            let width = hasNotch ? notchWidth + 2 * Self.earWidth : 2 * Self.earWidth + 40
            return CGSize(width: width, height: headerHeight)
        case .expanded:
            return CGSize(width: max(Self.expandedWidth, notchWidth + 2 * Self.earWidth),
                          height: headerHeight + Self.bodyHeight(item))
        }
    }

    /// Wysokość treści dopasowana do odpowiedzi, żeby krótka podpowiedź nie
    /// wisiała w pustej czerni, a długa rosła razem ze strumieniem. Liczona
    /// z długości tekstu, a nie mierzona: okno musi znać rozmiar, zanim
    /// SwiftUI cokolwiek narysuje. Szerokość linii przy 16 pt to ~58 znaków.
    static func bodyHeight(_ item: AssistantItem?) -> CGFloat {
        guard let item else { return 80 }
        let questionLines = min(2, max(1, (item.question.count + 69) / 70))
        let answerLines: Int
        switch item.status {
        case .pending: answerLines = 1
        case .error: answerLines = max(1, ((item.error ?? "").count + 57) / 58)
        default:
            answerLines = item.answer.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ($1.count + 57) / 58) }
        }
        let height = CGFloat(questionLines) * 17 + 10 + CGFloat(answerLines) * 21 + 22
        return min(320, max(84, height))
    }
}

/// Panel bez ramki nad paskiem menu. Nie przejmuje fokusu: kliknięcie
/// w wyspę nie może zabrać klawiatury rozmowie.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Nad paskiem menu, także nad aplikacją na pełnym ekranie.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        // Udostępnianie ekranu nie może pokazać rozmówcy podpowiedzi.
        sharingType = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Kształt notcha: górne rogi wklęsłe (wyspa „wyrasta" z krawędzi ekranu),
/// dolne zaokrąglone.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = topRadius, b = min(bottomRadius, rect.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchIslandView: View {
    enum Action { case copy, pin, collapse, toggleListening }

    let state: NotchIslandState
    var onHover: (Bool) -> Void = { _ in }
    var onAction: (Action) -> Void = { _ in }

    private var model: NotchIslandState { state }
    private var expanded: Bool { model.mode == .expanded }

    var body: some View {
        let geometry = model.geometry
        let size = geometry.size(for: model.mode, item: model.item)
        let topRadius: CGFloat = geometry.hasNotch ? (expanded ? 14 : 8) : 0
        let bottomRadius: CGFloat = expanded ? 26 : (geometry.hasNotch ? 10 : NotchGeometry.pillHeight / 2)

        ZStack(alignment: .top) {
            if geometry.hasNotch {
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius).fill(.black)
            } else {
                // Bez notcha nie ma z czego „wyrastać": zwykła pigułka.
                RoundedRectangle(cornerRadius: expanded ? 22 : NotchGeometry.pillHeight / 2, style: .continuous)
                    .fill(.black)
            }

            VStack(spacing: 0) {
                header(geometry, inset: topRadius)
                    .frame(height: geometry.headerHeight)
                if expanded, let item = model.item {
                    answerView(item)
                        .padding(.horizontal, topRadius + 18)
                        .padding(.bottom, 16)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: model.mode)
        .onHover { onHover($0) }
        .environment(\.colorScheme, .dark)
    }

    /// Pasek na wysokości notcha: status po lewej, czas po prawej. Środek
    /// zostaje pusty, bo zasłania go kamera.
    private func header(_ geometry: NotchGeometry, inset: CGFloat) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                statusDot
                if expanded || !geometry.hasNotch {
                    Text(statusText).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1).fixedSize()
                }
            }
            // Rozwinięta wyspa ma miejsce na całą etykietę; „uszy" nie.
            .frame(width: expanded ? 140 : NotchGeometry.earWidth - 10, alignment: .leading)
            // `inset`: wklęsłe rogi rozwiniętej wyspy zjadają brzeg.
            .padding(.leading, (geometry.hasNotch ? 14 : 12) + inset)

            Spacer(minLength: geometry.notchWidth)

            clock
                .frame(width: NotchGeometry.earWidth - 10, alignment: .trailing)
                .padding(.trailing, (geometry.hasNotch ? 14 : 12) + inset)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onAction(.toggleListening) }
    }

    /// Odpowiedź w drodze: iskierki zamiast kropki nasłuchu.
    private var thinking: Bool {
        guard let item = model.item else { return false }
        return item.status == .pending || (item.status == .streaming && item.answer.isEmpty)
    }

    /// Iskierki są statyczne. `.symbolEffect(.pulse, options: .repeating)`
    /// w tym panelu zatykał główny wątek: 2,5 s czekania trwało 6,2 s,
    /// a odpowiedź pojawiała się z kilkusekundowym opóźnieniem.
    @ViewBuilder private var statusDot: some View {
        if thinking {
            Image(systemName: "sparkles")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(red: 0.55, green: 0.75, blue: 1))
        } else {
            Circle()
                .fill(model.running ? Color.red : Color.gray)
                .frame(width: 7, height: 7)
                .shadow(color: model.running ? .red.opacity(0.7) : .clear, radius: 4)
        }
    }

    private var statusText: String {
        switch model.item?.status {
        case .pending?: return "Myślę…"
        case .streaming?: return "Podpowiedź"
        case .error?: return "Błąd"
        default: return model.running ? "Słucham" : "Pauza"
        }
    }

    private var clock: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text(elapsed(at: context.date))
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(model.running ? 0.8 : 0.4))
        }
    }

    private func elapsed(at date: Date) -> String {
        guard let startedAt = model.startedAt, model.running else { return "--:--" }
        let seconds = max(0, Int((date.timeIntervalSince1970 * 1000 - startedAt) / 1000))
        let h = seconds / 3600, m = seconds / 60 % 60, s = seconds % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }

    private func answerView(_ item: AssistantItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.question)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(2)
                Spacer(minLength: 8)
                controls
            }
            // Bez przewijania do końca: na głos czyta się od początku, a
            // `scrollTo` przy każdym słowie dokładał przebiegi układu.
            ScrollView(showsIndicators: false) {
                Group {
                    switch item.status {
                    case .pending:
                        // `ProgressView` na czarnym tle jest prawie niewidoczny.
                        Text("Składam odpowiedź z kontekstu…")
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.45))
                    case .error:
                        Text(item.error ?? "Błąd").foregroundStyle(.orange)
                    default:
                        // Duża czcionka: to się czyta na głos, zerkając.
                        MarkdownText(text: item.answer, font: .system(size: 16, weight: .regular))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 2) {
            button("doc.on.doc", help: "Kopiuj odpowiedź") { onAction(.copy) }
            button(model.pinned ? "pin.fill" : "pin", help: "Nie zwijaj") { onAction(.pin) }
            button("chevron.up", help: "Zwiń") { onAction(.collapse) }
        }
    }

    private func button(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 24, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
