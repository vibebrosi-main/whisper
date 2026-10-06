import Foundation
import Security

/// Klucz API w Keychainie.
///
/// Wersja webowa trzymała klucz w `chrome.storage.local`, czyli w zasięgu
/// każdego, kto ma dostęp do profilu Chrome — README wprost to odnotowywał
/// jako słabość. Natywnie nie ma powodu iść na ten kompromis.
///
/// Jedna rzecz wymaga świadomej decyzji, bo domyślne zachowanie jest tu
/// pułapką. Zakładając wpis, Keychain domyślnie wpisuje do listy zaufanych
/// programów **hash konkretnej binarki** (`requirement: cdhash H"…"`). Przy
/// podpisie ad-hoc każda przebudowa daje nowy hash, więc po każdym
/// `npm run mac:build` system blokowałby odczyt monitem o hasło. Nowszy
/// „data protection keychain" rozwiązałby to tożsamością aplikacji zamiast
/// hashem, ale wymaga uprawnienia `keychain-access-groups`, które bez Team ID
/// jest nieosiągalne — `SecItemAdd` zwraca wtedy -34018.
///
/// Zakładamy więc wpis z ACL, w którym lista zaufanych programów jest `nil`,
/// co w semantyce `SecACLSetContents` znaczy „wszystkie programy". Cena jest
/// realna i warto ją znać: **dowolny proces działający na Twoim koncie odczyta
/// ten klucz bez pytania**. To ta sama ekspozycja, co plik 0600 w katalogu
/// aplikacji — nie ma tu piaskownicy, która dawałaby więcej.
public enum Keychain {
    static let service = "ai.callwhisper.apikey"

    private static func base(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// ACL bez przypięcia do hashu binarki.
    ///
    /// `SecAccess`/`SecACL` są oznaczone jako przestarzałe od 10.10, a ich
    /// następcą jest data protection keychain — który, jak wyżej, bez Team ID
    /// jest zamknięty. Adnotacja poniżej wycisza cztery ostrzeżenia wewnątrz
    /// i zostawia jedno w miejscu wywołania — celowo: to jedyne miejsce
    /// w projekcie, gdzie sięgamy po przestarzałe API, i lepiej, żeby było
    /// widać.
    @available(macOS, deprecated: 10.10, message: "Świadomie: nowsze API wymaga uprawnienia niedostępnego przy podpisie ad-hoc.")
    private static func openAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate(service as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }

        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else { return access }

        for acl in acls {
            var applications: CFArray?
            var description: CFString?
            var prompt = SecKeychainPromptSelector()
            guard SecACLCopyContents(acl, &applications, &description, &prompt) == errSecSuccess else { continue }
            // `nil` zamiast listy = zaufane są wszystkie programy, czyli żadnego
            // monitu po przebudowie.
            SecACLSetContents(acl, nil, (description ?? "" as CFString), prompt)
        }
        return access
    }

    public static func read(account: String) -> String? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)
        else { return nil }
        return value
    }

    /// Zapis klucza.
    ///
    /// Aktualizacja istniejącego wpisu zamiast „skasuj i dodaj": ta druga
    /// kolejność przy nieudanym `SecItemAdd` zostawiała użytkownika bez klucza,
    /// który przed chwilą działał.
    @discardableResult
    public static func write(_ value: String, account: String) -> Bool {
        let base = base(account)

        guard !value.isEmpty else {
            let status = SecItemDelete(base as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(value.utf8)
        let update = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        if update != errSecItemNotFound {
            // Wpis istnieje, ale nie daje się zmienić — najczęściej dlatego, że
            // powstał poza aplikacją i ma listę zaufanych programów, na której
            // nas nie ma. Wtedy jedyne wyjście to skasować i założyć własny.
            SecItemDelete(base as CFDictionary)
        }

        var insert = base
        insert[kSecValueData as String] = data
        if let access = openAccess() { insert[kSecAttrAccess as String] = access }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }
}

/// Ustawienia aplikacji. Wszystko poza kluczem API siedzi w `UserDefaults`.
@MainActor
public final class AppSettings: ObservableObject {
    private let defaults = UserDefaults.standard
    public static let shared = AppSettings()

    public enum Key: String {
        case language, modelID, assistantEnabled, autoAsk, useMicrophone, assistantBackend, claudeModel
        case markdownLocale, absoluteTimestamps, minConfidence, title, projectContextPath
        case asrBackend, whisperModel, whisperPort, autoStartWhisper, identifySpeakers
        case diarizeAfter, detectMeetings, autoStartOnMeeting, followOBS, whisperVocabulary
    }

    /// Domyślny język mowy bierzemy z systemu, a nie na sztywno — inaczej
    /// użytkownik z innym językiem interfejsu dostaje polski bez powodu.
    static var systemLanguage: String {
        let locale = Locale.current
        guard let code = locale.language.languageCode?.identifier else { return "pl-PL" }
        let region = locale.region?.identifier ?? code.uppercased()
        return "\(code)-\(region)"
    }

    private init() {
        defaults.register(defaults: [
            Key.language.rawValue: Self.systemLanguage,
            Key.modelID.rawValue: Models.fastDefault.id,
            // Domyślnie most do Claude Code: nie wymaga klucza ani opłat,
            // a jest 2-3x szybszy od darmowych modeli w API.
            Key.assistantBackend.rawValue: ClaudeBridge.isAvailable
                ? AssistantBackend.claudeCode.rawValue : AssistantBackend.api.rawValue,
            Key.claudeModel.rawValue: "sonnet",
            Key.assistantEnabled.rawValue: true,
            Key.autoAsk.rawValue: true,
            // Domyślnie tylko dźwięk systemu. Mikrofon dokładany do głośników
            // łapie echo i każda wypowiedź trafia do transkryptu dwa razy —
            // raz jako „Rozmówcy", raz jako „Ty".
            Key.useMicrophone.rawValue: false,
            Key.markdownLocale.rawValue: "pl",
            Key.absoluteTimestamps.rawValue: false,
            Key.minConfidence.rawValue: 0.35,
            // whisper.cpp jest domyślny, bo rozpoznawanie Apple nie zna
            // polskiego — patrz `ASRBackend`.
            Key.asrBackend.rawValue: ASRBackend.whisperLocal.rawValue,
            Key.whisperModel.rawValue: "small",
            Key.whisperPort.rawValue: 8899,
            Key.autoStartWhisper.rawValue: true,
            // Domyślnie wyłączone: klastrowanie MFCC przy kilku podobnych
            // głosach rozsypuje jedną osobę na kilka etykiet, co psuje
            // transkrypt bardziej niż brak etykiet.
            Key.identifySpeakers.rawValue: false,
            // Diaryzacja neuronowa po rozmowie też domyślnie wyłączona: na
            // nagraniu wzorcowym rozdziela prawdziwe głosy, ale na polskim
            // materiale z kilkoma osobami nie jest jeszcze zmierzona,
            // a pomylone etykiety szkodzą bardziej niż ich brak.
            Key.diarizeAfter.rawValue: false,
            // Wykrywanie rozmów tylko podpowiada (powiadomienie), niczego nie
            // nagrywa samo — dlatego może być włączone od razu.
            Key.detectMeetings.rawValue: true,
            Key.autoStartOnMeeting.rawValue: false,
            Key.followOBS.rawValue: true,
        ])
    }

    private func get<T>(_ key: Key, _ fallback: T) -> T { defaults.object(forKey: key.rawValue) as? T ?? fallback }
    private func set(_ key: Key, _ value: Any?) {
        objectWillChange.send()
        defaults.set(value, forKey: key.rawValue)
    }

    /// Język rozpoznawania mowy, np. „pl-PL".
    public var language: String {
        get { get(.language, Self.systemLanguage) }
        set { set(.language, newValue) }
    }
    public var locale: Locale { Locale(identifier: language) }

    /// Dwuliterowy kod dla whisper.cpp („pl-PL" -> „pl").
    public var languageCode: String { String(language.prefix(2)) }

    /// Model podpowiadający. Domyślnie darmowy — patrz `Models`.
    public var modelID: String {
        get { get(.modelID, Models.fastDefault.id) }
        set { set(.modelID, newValue) }
    }

    /// Skąd biorą się podpowiedzi.
    public var assistantBackend: AssistantBackend {
        get {
            let fallback = ClaudeBridge.isAvailable ? AssistantBackend.claudeCode : .api
            return AssistantBackend(rawValue: get(.assistantBackend, fallback.rawValue)) ?? fallback
        }
        set { set(.assistantBackend, newValue.rawValue) }
    }

    /// Model przekazywany do CLI Claude Code. Pusty = domyślny z Claude Code.
    public var claudeModel: String {
        get { get(.claudeModel, "sonnet") }
        set { set(.claudeModel, newValue) }
    }

    public var assistantEnabled: Bool {
        get { get(.assistantEnabled, true) }
        set { set(.assistantEnabled, newValue) }
    }

    /// Czy pytania wykryte w transkrypcji lecą do modelu same z siebie.
    public var autoAsk: Bool {
        get { get(.autoAsk, true) }
        set { set(.autoAsk, newValue) }
    }

    public var useMicrophone: Bool {
        get { get(.useMicrophone, false) }
        set { set(.useMicrophone, newValue) }
    }

    public var markdownLocale: String {
        get { get(.markdownLocale, "pl") }
        set { set(.markdownLocale, newValue) }
    }

    public var absoluteTimestamps: Bool {
        get { get(.absoluteTimestamps, false) }
        set { set(.absoluteTimestamps, newValue) }
    }

    public var minConfidence: Double {
        get { get(.minConfidence, 0.35) }
        set { set(.minConfidence, newValue) }
    }

    /// Domyślne miejsce na opis projektu, o którym jest rozmowa.
    public static var defaultProjectContextURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/call-whisper/project-context.md")
    }

    /// Plik z opisem projektu. Trafia do każdego promptu jako tło rozmowy,
    /// żeby model wiedział, jak rzeczy są zrobione, zamiast zgadywać.
    public var projectContextPath: String {
        get { get(.projectContextPath, Self.defaultProjectContextURL.path) }
        set { set(.projectContextPath, newValue) }
    }

    /// Treść pliku kontekstu albo pusty napis, gdy go nie ma.
    public var projectContext: String {
        let path = projectContextPath
        guard !path.isEmpty,
              let text = try? String(contentsOfFile: path, encoding: .utf8)
        else { return "" }
        return text
    }

    public var title: String {
        get { get(.title, "") }
        set { set(.title, newValue) }
    }

    /// Czy próbować rozpoznawać, kto mówi. Podział „Ty" vs „Rozmówcy"
    /// (mikrofon vs dźwięk systemu) działa niezależnie od tego ustawienia.
    public var identifySpeakers: Bool {
        get { get(.identifySpeakers, false) }
        set { set(.identifySpeakers, newValue) }
    }

    /// Diaryzacja neuronowa (pyannote + CAM++) po zatrzymaniu nasłuchu
    /// i przy imporcie nagrań. Przepisuje etykiety dźwięku systemu na
    /// „Rozmówca 1", „Rozmówca 2"…
    public var diarizeAfter: Bool {
        get { get(.diarizeAfter, false) }
        set { set(.diarizeAfter, newValue) }
    }

    /// Powiadomienie „Wykryto rozmowę w Zoom — słuchać?".
    public var detectMeetings: Bool {
        get { get(.detectMeetings, true) }
        set { set(.detectMeetings, newValue) }
    }

    /// Zaczynaj nasłuch sam, gdy wykryjesz rozmowę, i kończ, gdy się skończy.
    public var autoStartOnMeeting: Bool {
        get { get(.autoStartOnMeeting, false) }
        set { set(.autoStartOnMeeting, newValue) }
    }

    /// Nasłuch razem z nagrywaniem w OBS, transkrypt obok pliku wideo.
    public var followOBS: Bool {
        get { get(.followOBS, true) }
        set { set(.followOBS, newValue) }
    }

    /// Słownictwo podpowiadane whisperowi: nazwy technologii, firm i osób,
    /// które padną w rozmowie. Najtańsza poprawa jakości (patrz `WhisperClient`).
    public var whisperVocabulary: String {
        get { get(.whisperVocabulary, "") }
        set { set(.whisperVocabulary, newValue) }
    }

    /// Silnik rozpoznawania mowy.
    public var asrBackend: ASRBackend {
        get { ASRBackend(rawValue: get(.asrBackend, ASRBackend.whisperLocal.rawValue)) ?? .whisperLocal }
        set { set(.asrBackend, newValue.rawValue) }
    }

    /// Model whisper.cpp. `small` bije `large-v3-turbo` czterokrotnie przy tej
    /// samej jakości po polsku — stąd domyślny.
    public var whisperModel: String {
        get { get(.whisperModel, "small") }
        set { set(.whisperModel, newValue) }
    }

    public var whisperPort: Int {
        get { get(.whisperPort, 8899) }
        set { set(.whisperPort, newValue) }
    }

    /// Czy aplikacja ma sama podnieść `whisper-server`.
    public var autoStartWhisper: Bool {
        get { get(.autoStartWhisper, true) }
        set { set(.autoStartWhisper, newValue) }
    }

    /// Plik z kluczem API, prawa 0600.
    nonisolated public static var apiKeyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/call-whisper/api-key")
    }

    /// Klucz API z pliku 0600, nie z Keychaina.
    ///
    /// Keychain przy podpisie ad-hoc nie działa „plug and play": wpis jest
    /// związany z hashem konkretnej binarki (lista partycji), więc po każdej
    /// przebudowie macOS pytał o hasło do pęku kluczy, i to w środku rozmowy.
    /// Otwarte ACL, którego używaliśmy wcześniej, i tak dawało dostęp każdemu
    /// procesowi na koncie, czyli tę samą ochronę co plik 0600.
    ///
    /// Odczyt nigdy nie dotyka Keychaina. Stary wpis przenosi
    /// `migrateLegacyAPIKey`, wołane tylko tam, gdzie klucz jest naprawdę
    /// potrzebny (backend API).
    ///
    /// Przycinamy białe znaki: klucz prawie zawsze trafia tu przez wklejenie,
    /// a doklejony znak nowej linii daje nagłówek `Bearer xpl_…\n` i 401
    /// „invalid_key" - błąd, który wygląda na zły klucz, a jest złym wklejeniem.
    public var apiKey: String {
        get {
            if let stored = try? String(contentsOf: Self.apiKeyURL, encoding: .utf8) {
                return stored.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return migrateLegacyAPIKey()
        }
        set { _ = setAPIKey(newValue) }
    }

    /// Jednorazowe przeniesienie klucza z Keychaina do pliku. Może raz
    /// zapytać o hasło, ale tylko komuś, kto używa API i ma tam stary klucz;
    /// przy Claude Code nie jest wołane wcale.
    private func migrateLegacyAPIKey() -> String {
        guard assistantBackend == .api,
              !UserDefaults.standard.bool(forKey: "legacyKeyMigrated") else { return "" }
        UserDefaults.standard.set(true, forKey: "legacyKeyMigrated")
        guard let legacy = Keychain.read(account: "experientiallabs"), !legacy.isEmpty else { return "" }
        setAPIKey(legacy)
        return legacy.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Jak `apiKey`, ale mówi, czy zapis się powiódł.
    @discardableResult
    public func setAPIKey(_ value: String) -> Bool {
        objectWillChange.send()
        let url = Self.apiKeyURL
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return true
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // Plik zakładamy od razu z prawami 0600, zanim trafi do niego klucz.
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(trimmed.utf8))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            return false
        }
    }
}
