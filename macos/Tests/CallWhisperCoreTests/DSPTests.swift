import Testing
import Foundation
@testable import CallWhisperCore

/// Syntetyczne głosy — dokładnie te same, co w testach JS.
///
/// Generator szumu odtwarza arytmetykę JS na `Double` (łącznie z utratą
/// precyzji przy mnożeniu powyżej 2^53), więc sygnał jest bit w bit ten sam
/// po obu stronach. Bez tego porównanie wyników nie miałoby sensu.
enum Synth {
    static let sr: Double = 16_000
    static let frame = 400   // 25 ms
    static let hop = 160     // 10 ms

    struct Noise {
        var state: Double
        init(seed: Double) { state = seed }
        mutating func next() -> Double {
            state = (state * 1103515245 + 12345).truncatingRemainder(dividingBy: 2147483648)
            return state / 2147483648 - 0.5
        }
    }

    struct Voice {
        var f0: Double
        var formants: [(Double, Double)]
    }

    static let anna = Voice(f0: 205, formants: [(520, 0.30), (2350, 0.26), (3100, 0.12)])
    static let jan = Voice(f0: 105, formants: [(330, 0.32), (1100, 0.24), (2400, 0.10)])

    static func voice(_ v: Voice, seconds: Double, gain: Double = 1, seed: Double = 7) -> [Double] {
        var random = Noise(seed: seed)
        let length = Int((seconds * sr).rounded())
        var out = [Double](repeating: 0, count: length)
        for i in 0..<length {
            let t = Double(i) / sr
            // Lekka modulacja amplitudy imituje sylaby.
            let envelope = 0.7 + 0.3 * sin(2 * Double.pi * 4 * t)
            var value = 0.4 * sin(2 * Double.pi * v.f0 * t)
            for (freq, amp) in v.formants { value += amp * sin(2 * Double.pi * freq * t + freq) }
            out[i] = gain * envelope * value + 0.004 * random.next()
        }
        return out
    }

    static func silence(seconds: Double, seed: Double = 3) -> [Double] {
        var random = Noise(seed: seed)
        var out = [Double](repeating: 0, count: Int((seconds * sr).rounded()))
        for i in out.indices { out[i] = 0.0015 * random.next() }
        return out
    }
}

struct DSPTests {
    /// FFT z Accelerate musi zgadzać się z naiwną DFT — to jedyny sposób, żeby
    /// upewnić się, że pakowanie wyniku i skalowanie ×2 rozpakowaliśmy dobrze.
    @Test func fftZgadzaSieZNaiwnaDFT() {
        let n = 64
        var signal = [Float](repeating: 0, count: n)
        for i in 0..<n {
            signal[i] = Float(sin(2 * Double.pi * 5 * Double(i) / Double(n))
                              + 0.5 * cos(2 * Double.pi * 13 * Double(i) / Double(n)) + 0.1)
        }

        let fft = FFTProcessor(size: n)!
        let fast = fft.powerSpectrum(signal)

        for k in 0...(n / 2) {
            var re = 0.0, im = 0.0
            for i in 0..<n {
                let angle = 2 * Double.pi * Double(k) * Double(i) / Double(n)
                re += Double(signal[i]) * cos(angle)
                im -= Double(signal[i]) * sin(angle)
            }
            let expected = re * re + im * im
            #expect(abs(Double(fast[k]) - expected) < 1e-2, "prążek \(k): \(fast[k]) vs \(expected)")
        }
    }

    @Test func fftOdrzucaRozmiarNieBedacyPotegaDwojki() {
        #expect(FFTProcessor(size: 100) == nil)
        #expect(FFTProcessor(size: 512) != nil)
    }

    @Test func l2NormalizeICosinus() {
        let v = l2Normalize([3, 4])
        #expect(abs((v[0] * v[0] + v[1] * v[1]).squareRoot() - 1) < 1e-12)
        #expect(abs(cosineSimilarity(v, v) - 1) < 1e-12)

        let orthogonal = l2Normalize([-4, 3])
        #expect(abs(cosineSimilarity(v, orthogonal)) < 1e-12)

        let expected = FixtureTests.fixtures["norm34"] as! [Double]
        for (a, e) in zip(v, expected) { #expect(abs(a - e) < 1e-12) }
    }

    /// MFCC liczymy w Float (Accelerate), JS liczył w Double — drobna
    /// rozbieżność jest oczekiwana, ale barwa głosu musi zostać ta sama.
    @Test func mfccZgadzaSieZJS() throws {
        let extractor = MfccExtractor()
        let signal = Synth.voice(Synth.anna, seconds: 0.2)
        let expected = FixtureTests.fixtures["mfccFrames"] as! [[Double]]

        for i in 0..<3 {
            let start = i * Synth.hop
            let frame = signal[start..<(start + Synth.frame)].map { Float($0) }
            let mfcc = extractor.frameToMfcc(frame)
            #expect(mfcc.count == expected[i].count)
            for j in 0..<mfcc.count {
                #expect(abs(mfcc[j] - expected[i][j]) < 0.05,
                        "ramka \(i), współczynnik \(j): \(mfcc[j]) vs \(expected[i][j])")
            }
        }
    }

    @Test func energiaRamkiZgadzaSieZJS() {
        let signal = Synth.voice(Synth.anna, seconds: 0.2)
        let expected = FixtureTests.fixtures["energyDb"] as! [Double]
        for i in 0..<3 {
            let start = i * Synth.hop
            let frame = signal[start..<(start + Synth.frame)].map { Float($0) }
            let db = MfccExtractor.frameEnergyDb(frame)
            #expect(abs(db - expected[i]) < 1e-3, "ramka \(i): \(db) vs \(expected[i])")
        }
    }

    /// VAD musi otworzyć i zamknąć wypowiedź w tych samych ramkach co JS.
    /// To pilnuje statystyki minimum — regresja tutaj oznacza, że wentylator
    /// znowu jest mową albo że długa wypowiedź się ucina.
    @Test func vadOtwieraIZamykaWTychSamychRamkach() {
        var signal = Synth.silence(seconds: 0.4)
        signal += Synth.voice(Synth.anna, seconds: 0.8)
        signal += Synth.silence(seconds: 0.6)

        let vad = Vad()
        var events: [(String, Int)] = []
        var start = 0
        while start + Synth.frame <= signal.count {
            let frame = signal[start..<(start + Synth.frame)].map { Float($0) }
            let s = vad.push(MfccExtractor.frameEnergyDb(frame))
            if s.started { events.append(("start", start / Synth.hop)) }
            if s.ended { events.append(("end", start / Synth.hop)) }
            start += Synth.hop
        }

        let expected = FixtureTests.fixtures["vadEvents"] as! [[String: Any]]
        #expect(events.count == expected.count, "liczba zdarzeń VAD: \(events)")
        for (a, e) in zip(events, expected) {
            #expect(a.0 == e["event"] as! String)
            #expect(a.1 == (e["frame"] as! NSNumber).intValue, "ramka zdarzenia \(a.0)")
        }
    }

    /// Pełny łańcuch diaryzacji na dwóch syntetycznych głosach.
    /// Anna -> Jan -> Anna musi dać dwóch mówców i etykiety 0,1,0.
    @Test func diaryzacjaRozdzielaDwaGlosy() {
        var signal = Synth.silence(seconds: 0.3)
        signal += Synth.voice(Synth.anna, seconds: 1.2, seed: 11)
        signal += Synth.silence(seconds: 0.5)
        signal += Synth.voice(Synth.jan, seconds: 1.2, seed: 13)
        signal += Synth.silence(seconds: 0.5)
        signal += Synth.voice(Synth.anna, seconds: 1.2, seed: 17)
        signal += Synth.silence(seconds: 0.4)

        let diarizer = Diarizer()
        var start = 0
        while start + Synth.frame <= signal.count {
            let frame = signal[start..<(start + Synth.frame)].map { Float($0) }
            diarizer.pushFrame(frame, at: Double(start) / Synth.sr * 1000)
            start += Synth.hop
        }
        diarizer.flush(at: Double(signal.count) / Synth.sr * 1000)

        let expectedTurns = FixtureTests.fixtures["turns"] as! [[String: Any]]
        let expectedCount = (FixtureTests.fixtures["speakerCount"] as! NSNumber).intValue

        #expect(diarizer.speakerCount == expectedCount, "liczba mówców")
        #expect(diarizer.turns.count == expectedTurns.count, "liczba tur")

        let labels = diarizer.turns.map(\.speaker)
        let expectedLabels = expectedTurns.map { ($0["speaker"] as! NSNumber).intValue }
        #expect(labels == expectedLabels, "etykiety mówców: \(labels)")

        // Ta sama osoba na początku i na końcu — to jest cały sens diaryzacji.
        #expect(labels.first == labels.last)
        #expect(labels.count >= 3 && labels[0] != labels[1])

        // Granice tur mogą przesunąć się o ramkę przez arytmetykę Float,
        // ale nie o więcej.
        for (a, e) in zip(diarizer.turns, expectedTurns) {
            let expStart = (e["startMs"] as! NSNumber).doubleValue
            let expEnd = (e["endMs"] as! NSNumber).doubleValue
            #expect(abs(a.startMs - expStart) <= 20, "start tury: \(a.startMs) vs \(expStart)")
            #expect(abs(a.endMs - expEnd) <= 20, "koniec tury: \(a.endMs) vs \(expEnd)")
        }
    }

    @Test func framerTnieNaRamkiZeSkokiem() {
        let framer = Framer(frameSize: 4, hopSize: 2)
        let first = framer.push([1, 2, 3, 4, 5])
        #expect(first.count == 1)
        #expect(first[0].frame == [1, 2, 3, 4])
        #expect(first[0].startSample == 0)

        // Bufor trzyma [3,4,5]; po dołożeniu 6,7 wychodzi dokładnie jedna
        // kolejna ramka, przesunięta o skok — nie dwie.
        let second = framer.push([6, 7])
        #expect(second.count == 1)
        #expect(second[0].frame == [3, 4, 5, 6])
        #expect(second[0].startSample == 2)

        let third = framer.push([8, 9])
        #expect(third.count == 1)
        #expect(third[0].frame == [5, 6, 7, 8])
        #expect(third[0].startSample == 4)
    }

    @Test func trackerZakladaNowegoMowceGdyGlosOdlegly() {
        let tracker = SpeakerTracker(threshold: 0.9)
        let a = l2Normalize([1, 0, 0, 0])
        let b = l2Normalize([0, 1, 0, 0])
        #expect(tracker.assign(a).isNew)
        #expect(tracker.assign(b).isNew)
        #expect(!tracker.assign(a).isNew)
        #expect(tracker.count == 2)
    }

    @Test func trackerNiePrzekraczaLimituMowcow() {
        let tracker = SpeakerTracker(threshold: 0.99, maxSpeakers: 2)
        _ = tracker.assign(l2Normalize([1, 0, 0]))
        _ = tracker.assign(l2Normalize([0, 1, 0]))
        let third = tracker.assign(l2Normalize([0, 0, 1]))
        #expect(!third.isNew)
        #expect(tracker.count == 2)
    }
}
