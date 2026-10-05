import Foundation
import CryptoKit

/// Silniki, które nie są częścią systemu: `whisper-server` i diaryzacja.
///
/// Wcześniej `whisper-server` trzeba było instalować przez Homebrew, bo build
/// z brew ładuje backendy ggml z katalogu wkompilowanego na stałe i nie daje
/// się zapakować do `.app`. OpenWhispr rozwiązał to po swojemu: publikuje
/// statycznie zlinkowany `whisper-server` (3,6 MB, tylko frameworki systemowe,
/// Metal wbudowany). Ten sam plik bierzemy tutaj — i nagle brew przestaje
/// być potrzebny.
///
/// Diaryzacja to też pomysł z OpenWhispr: pyannote (segmentacja) + CAM++
/// (odcisk głosu) przez `sherpa-onnx-offline-speaker-diarization`. Zastępuje
/// klastrowanie MFCC, które przy podobnych głosach rozsypywało jedną osobę
/// na kilka etykiet.
///
/// Kolejność szukania: wnętrze `.app` (dołączone przy budowaniu) -> katalog
/// aplikacji w Application Support (pobrane przez aplikację) -> Homebrew.
public enum Engines {
    public enum Component: String, Sendable, CaseIterable {
        case whisperServer = "whisper-server"
        case diarizer = "diarizer"
        case diarizationModels = "diarization-models"

        public var label: String {
            switch self {
            case .whisperServer: return "Silnik mowy (whisper-server)"
            case .diarizer: return "Silnik diaryzacji (sherpa-onnx)"
            case .diarizationModels: return "Modele rozpoznawania głosów"
            }
        }
    }

    /// Plik do pobrania. Wersje i sumy przypięte — pobieramy wykonywalny kod,
    /// więc „najnowsza wersja z GitHuba" nie wchodzi w grę.
    struct Asset: Sendable {
        enum Kind: Sendable { case zip, tarBz2, file }
        var url: String
        var sha256: String
        var bytes: Int64
        var kind: Kind
        /// Ścieżka w archiwum (po rozpakowaniu) -> ścieżka względem katalogu docelowego.
        var members: [(from: String, to: String)]
    }

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x64"
        #endif
    }

    static let sherpaDir = "sherpa-onnx-v1.12.23-osx-universal2-shared-no-tts"

    static func assets(_ component: Component) -> [Asset] {
        switch component {
        case .whisperServer:
            let sha = arch == "arm64"
                ? "6a5f794e42549d61e7b46e1c1f296f05ec6569bfcb81b7e39c14860021f477de"
                : "000395055f5cf058562e4fb8a882b679657beb02d6cbd890cb336fa789365e14"
            return [Asset(
                url: "https://github.com/OpenWhispr/whisper.cpp/releases/download/0.0.10/whisper-server-darwin-\(arch).zip",
                sha256: sha, bytes: arch == "arm64" ? 1_326_241 : 1_368_068, kind: .zip,
                members: [("whisper-server-darwin-\(arch)", "bin/whisper-server")])]
        case .diarizer:
            // Binarka szuka `libonnxruntime` w `@loader_path/../lib`, więc
            // układ bin/ + lib/ musi zostać zachowany.
            return [Asset(
                url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.12.23/\(sherpaDir).tar.bz2",
                sha256: "a304cce7db9ac20a3b28f9d9205f5ad4e48e372ab91018373a3a1432aaf1fcde",
                bytes: 62_677_386, kind: .tarBz2,
                members: [("\(sherpaDir)/bin/sherpa-onnx-offline-speaker-diarization",
                           "sherpa/bin/sherpa-onnx-offline-speaker-diarization"),
                          ("\(sherpaDir)/lib/libonnxruntime.1.23.2.dylib",
                           "sherpa/lib/libonnxruntime.1.23.2.dylib")])]
        case .diarizationModels:
            return [
                Asset(url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2",
                      sha256: "24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488",
                      bytes: 6_958_444, kind: .tarBz2,
                      members: [("sherpa-onnx-pyannote-segmentation-3-0/model.onnx", "models/segmentation.onnx")]),
                Asset(url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx",
                      sha256: "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b",
                      bytes: 29_596_978, kind: .file,
                      members: [("", "models/campplus.onnx")]),
            ]
        }
    }

    /// Ile trzeba pobrać — do pokazania, na co użytkownik się pisze.
    public static func downloadBytes(_ component: Component) -> Int64 {
        assets(component).reduce(0) { $0 + $1.bytes }
    }

    // MARK: - gdzie szukać

    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/call-whisper")
    }

    /// `Contents/Resources` uruchomionej aplikacji. Przy `swift run` to katalog
    /// builda — wtedy po prostu nic tam nie ma.
    static var bundledDirectory: URL? { Bundle.main.resourceURL }

    static func firstExisting(_ relative: String, extra: [String] = []) -> URL? {
        var candidates: [URL] = []
        if let bundled = bundledDirectory { candidates.append(bundled.appendingPathComponent(relative)) }
        candidates.append(supportDirectory.appendingPathComponent(relative))
        candidates += extra.map { URL(fileURLWithPath: $0) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path)
            || (relative.hasSuffix(".onnx") && FileManager.default.isReadableFile(atPath: $0.path)) }
    }

    public static var whisperServer: URL? {
        // Homebrew na końcu: działa, ale to już tylko zapasowa droga dla tych,
        // którzy mają go z czasów przed scaleniem.
        firstExisting("bin/whisper-server", extra: [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
            "/opt/homebrew/opt/whisper-cpp/bin/whisper-server",
        ])
    }

    public static var diarizer: URL? {
        firstExisting("sherpa/bin/sherpa-onnx-offline-speaker-diarization")
    }

    public static var diarizationModels: (segmentation: URL, embedding: URL)? {
        guard let seg = firstExisting("models/segmentation.onnx"),
              let emb = firstExisting("models/campplus.onnx") else { return nil }
        return (seg, emb)
    }

    public static func isInstalled(_ component: Component) -> Bool {
        switch component {
        case .whisperServer: return whisperServer != nil
        case .diarizer: return diarizer != nil
        case .diarizationModels: return diarizationModels != nil
        }
    }

    public static var canDiarize: Bool { diarizer != nil && diarizationModels != nil }

    // MARK: - instalacja

    public enum InstallError: LocalizedError {
        case http(Int, String)
        case checksum(String)
        case extract(String)
        case missingMember(String)

        public var errorDescription: String? {
            switch self {
            case .http(let status, let url): return "Pobieranie \(url) zwróciło \(status)."
            case .checksum(let url): return "Suma kontrolna się nie zgadza: \(url). Plik odrzucony."
            case .extract(let detail): return "Nie udało się rozpakować: \(detail)"
            case .missingMember(let name): return "W archiwum brakuje \(name)."
            }
        }
    }

    /// Pobiera i rozpakowuje komponent do `root` (domyślnie Application Support).
    /// `bundle.sh` woła to samo z katalogiem `Contents/Resources`, żeby nie
    /// trzymać adresów i sum w dwóch miejscach.
    public static func install(_ component: Component, into root: URL? = nil,
                               onProgress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let root = root ?? supportDirectory
        let all = assets(component)
        let total = Double(all.reduce(0) { $0 + $1.bytes })
        var done: Int64 = 0

        for asset in all {
            let offset = Double(done)
            let reporter = ProgressReporter(expected: asset.bytes) { p in
                onProgress((offset + Double(p.receivedBytes)) / total)
            }
            let (temporary, response) = try await URLSession.shared.download(
                from: URL(string: asset.url)!, delegate: reporter)
            defer { try? FileManager.default.removeItem(at: temporary) }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallError.http(http.statusCode, asset.url)
            }
            guard try sha256(of: temporary) == asset.sha256 else { throw InstallError.checksum(asset.url) }

            let work = FileManager.default.temporaryDirectory
                .appendingPathComponent("cw-engine-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }

            switch asset.kind {
            case .zip: try run("/usr/bin/ditto", ["-x", "-k", temporary.path, work.path])
            case .tarBz2: try run("/usr/bin/tar", ["-xjf", temporary.path, "-C", work.path])
            case .file: break
            }

            for member in asset.members {
                let source = asset.kind == .file ? temporary : work.appendingPathComponent(member.from)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    throw InstallError.missingMember(member.from)
                }
                let target = root.appendingPathComponent(member.to)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.copyItem(at: source, to: target)
                // Plik z `URLSession` ma 0600; binarki muszą być wykonywalne.
                let mode = member.to.hasSuffix(".onnx") ? 0o644 : 0o755
                try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: target.path)
            }
            done += asset.bytes
            onProgress(Double(done) / total)
        }
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func run(_ tool: String, _ arguments: [String]) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: tool)
        task.arguments = arguments
        let errors = Pipe()
        task.standardError = errors
        task.standardOutput = FileHandle.nullDevice
        try task.run()
        // Błędy czytamy przed `waitUntilExit`: pełny potok zablokowałby proces
        // (ta sama pułapka, którą już raz zaliczył whisper-server).
        let stderr = errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw InstallError.extract(String(decoding: stderr, as: UTF8.self).suffix(200).description)
        }
    }
}
