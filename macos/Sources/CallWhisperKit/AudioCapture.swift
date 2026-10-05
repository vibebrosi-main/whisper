import Foundation
@preconcurrency import AVFoundation
import ScreenCaptureKit
import CallWhisperCore

/// Docelowy format dla całego łańcucha: 16 kHz, mono, Float32.
/// To ten sam format, na którym pracował `AudioWorklet` w wersji webowej —
/// MFCC, VAD i whisper.cpp wszystkie go zakładają.
public let asrSampleRate: Double = 16_000

/// Skąd przyszedł dźwięk. Rozdzielenie źródeł daje darmowy i bezbłędny podział
/// „ja" vs „oni": mikrofon to Ty i osoby obok, dźwięk systemu to zdalni
/// uczestnicy. Diaryzacja pracuje osobno wewnątrz każdego źródła.
public enum AudioSource: String, Sendable, CaseIterable {
    case system
    case microphone

    public var label: String {
        switch self {
        case .system: return "Zdalni"
        case .microphone: return "Ty"
        }
    }
}

public struct PCMChunk: Sendable {
    public var source: AudioSource
    public var samples: [Float]
    /// Czas pierwszej próbki względem startu sesji, w ms.
    public var startMs: Double
}

/// Konwersja dowolnego formatu wejściowego na 16 kHz mono Float32.
///
/// `AVAudioConverter` radzi sobie i z downmiksem, i z resamplingiem, ale trzeba
/// mu podawać bufory wyjściowe z zapasem — inaczej gubi ogon przy niecałkowitym
/// stosunku częstotliwości.
final class Downsampler {
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat: AVAudioFormat

    init() {
        outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: asrSampleRate,
                                     channels: 1,
                                     interleaved: false)!
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        let format = buffer.format
        if converter == nil || inputFormat?.settings as NSDictionary? != format.settings as NSDictionary? {
            converter = AVAudioConverter(from: format, to: outputFormat)
            inputFormat = format
        }
        guard let converter else { return [] }

        let ratio = outputFormat.sampleRate / format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        guard convertOnce(converter, input: buffer, into: out) else { return [] }

        guard let channel = out.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
    }
}

/// Przechwytywanie dźwięku systemowego przez ScreenCaptureKit.
///
/// To jest największy zysk z przejścia na natywne: wersja webowa umiała słuchać
/// wyłącznie karty Chrome (`tabCapture`). Tutaj słyszymy dowolną aplikację —
/// Zoom, Teams, huddle w Slacku, FaceTime — bez żadnej wtyczki.
public final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let downsampler = Downsampler()
    private let queue = DispatchQueue(label: "call-whisper.system-audio")
    /// Kotwica czasu.
    ///
    /// Czasu NIE wolno liczyć z licznika próbek: ScreenCaptureKit nie wysyła
    /// buforów, gdy w systemie panuje cisza, więc licznik zostaje w tyle za
    /// zegarem. Kosztowało to całą wypowiedź — `TranscriptStore.finalizeIdle`
    /// porównuje `updatedAt` z zegarem ściennym, uznawał segment za martwy
    /// i odrzucał każdą kolejną aktualizację tego klucza.
    ///
    /// Bierzemy więc znacznik prezentacji z `CMSampleBuffer` (prawdziwy zegar
    /// przechwytywania, uwzględnia przerwy), zakotwiczony w czasie startu sesji.
    private var firstPTS: Double?
    private var baseMs: Double = 0
    private var sessionStartMs: Double = 0
    private var onChunk: (@Sendable (PCMChunk) -> Void)?
    private var onStop: (@Sendable (Error?) -> Void)?

    public override init() { super.init() }

    /// Uruchamia przechwytywanie całego dźwięku systemu poza naszym własnym.
    public func start(sessionStartMs: Double = nowMs(),
                      onChunk: @escaping @Sendable (PCMChunk) -> Void,
                      onStop: @escaping @Sendable (Error?) -> Void = { _ in }) async throws {
        self.onChunk = onChunk
        self.onStop = onStop
        self.sessionStartMs = sessionStartMs
        firstPTS = nil

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }
        // Filtr obejmuje cały ekran, ale interesuje nas z niego wyłącznie
        // ścieżka dźwiękowa — wideo konfigurujemy na możliwie najtańsze.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Nie potrzebujemy obrazu, a nie da się go całkiem wyłączyć —
        // bierzemy najmniejszy dopuszczalny i najrzadszy możliwy.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 5

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let onChunk else { return }
        guard let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
        let samples = downsampler.convert(buffer)
        guard !samples.isEmpty else { return }

        let pts = sampleBuffer.presentationTimeStamp.seconds
        if firstPTS == nil {
            firstPTS = pts
            // Ile realnie minęło od startu sesji do pierwszej próbki dźwięku.
            baseMs = Swift.max(0, nowMs() - sessionStartMs)
        }
        let startMs = baseMs + (pts - (firstPTS ?? pts)) * 1000
        onChunk(PCMChunk(source: .system, samples: samples, startMs: startMs))
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }

    /// CMSampleBuffer -> AVAudioPCMBuffer, kopiując listę buforów kanał po kanale.
    static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = sampleBuffer.formatDescription,
              var asbd = description.audioStreamBasicDescription,
              let format = AVAudioFormat(streamDescription: &asbd)
        else { return nil }

        let frames = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames

        do {
            try sampleBuffer.withAudioBufferList { source, _ in
                let destination = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
                for i in 0..<Swift.min(source.count, destination.count) {
                    guard let from = source[i].mData, let to = destination[i].mData else { continue }
                    memcpy(to, from, Int(Swift.min(source[i].mDataByteSize, destination[i].mDataByteSize)))
                }
            }
        } catch {
            return nil
        }
        return buffer
    }

    public enum CaptureError: LocalizedError {
        case noDisplay
        public var errorDescription: String? {
            switch self {
            case .noDisplay: return "Nie znalazłem ekranu do przechwycenia dźwięku."
            }
        }
    }
}

/// Przechwytywanie mikrofonu przez AVAudioEngine.
public final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let downsampler = Downsampler()
    private var firstHostTime: UInt64?
    private var baseMs: Double = 0
    private var sessionStartMs: Double = 0
    private var running = false

    public init() {}

    public static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func start(sessionStartMs: Double = nowMs(),
                      onChunk: @escaping @Sendable (PCMChunk) -> Void) throws {
        guard !running else { return }
        self.sessionStartMs = sessionStartMs
        firstHostTime = nil
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw MicError.noInput }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self else { return }
            let samples = self.downsampler.convert(buffer)
            guard !samples.isEmpty else { return }

            // Ta sama zasada, co przy dźwięku systemu: czas z zegara urządzenia,
            // zakotwiczony w starcie sesji.
            if self.firstHostTime == nil {
                self.firstHostTime = when.hostTime
                self.baseMs = Swift.max(0, nowMs() - self.sessionStartMs)
            }
            let elapsed = AVAudioTime.seconds(forHostTime: when.hostTime - (self.firstHostTime ?? when.hostTime))
            onChunk(PCMChunk(source: .microphone, samples: samples, startMs: self.baseMs + elapsed * 1000))
        }

        engine.prepare()
        try engine.start()
        running = true
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }

    public enum MicError: LocalizedError {
        case noInput
        public var errorDescription: String? {
            switch self {
            case .noInput: return "Brak urządzenia wejściowego audio."
            }
        }
    }
}
