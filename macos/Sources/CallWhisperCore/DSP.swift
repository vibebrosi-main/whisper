import Foundation
import Accelerate

/// FFT rzeczywista, radix-2, na Accelerate.
///
/// W wersji webowej FFT była pisana ręcznie (brak zależności w przeglądarce).
/// Natywnie to zbędne: vDSP robi to samo na jednostkach wektorowych, a my
/// zyskujemy zapas czasu w pętli 10 ms.
public final class FFTProcessor {
    public let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realp: [Float]
    private var imagp: [Float]

    public init?(size: Int) {
        guard size > 1, size & (size - 1) == 0 else { return nil }
        self.size = size
        self.log2n = vDSP_Length(log2(Double(size)).rounded())
        guard let s = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.setup = s
        self.realp = [Float](repeating: 0, count: size / 2)
        self.imagp = [Float](repeating: 0, count: size / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// Widmo mocy sygnału rzeczywistego: |X(k)|² dla k = 0…n/2.
    public func powerSpectrum(_ frame: [Float]) -> [Float] {
        precondition(frame.count == size, "FFTProcessor: ramka musi mieć \(size) próbek")
        let half = size / 2
        var bins = [Float](repeating: 0, count: half + 1)

        realp.withUnsafeMutableBufferPointer { rp in
            imagp.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) { typed in
                        vDSP_ctoz(typed, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))

                // vDSP pakuje wynik: realp[0] to składowa stała, imagp[0] to
                // Nyquist, a całość jest przeskalowana ×2 względem zwykłej DFT.
                let dc = rp[0] / 2
                let nyquist = ip[0] / 2
                bins[0] = dc * dc
                bins[half] = nyquist * nyquist
                for k in 1..<half {
                    let re = rp[k] / 2
                    let im = ip[k] / 2
                    bins[k] = re * re + im * im
                }
            }
        }
        return bins
    }
}

public func nextPowerOfTwo(_ n: Int) -> Int {
    var size = 1
    while size < n { size <<= 1 }
    return size
}

public func hzToMel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
public func melToHz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }

/// Trójkątny filtr w skali mel — rzadki, trzyma tylko swój zakres prążków.
public struct MelFilter: Sendable {
    public var start: Int
    public var weights: [Float]
}

/// Bank filtrów mel.
public func melFilterbank(sampleRate: Double = 16_000, fftSize: Int = 512, filters: Int = 26,
                          fMin: Double = 80, fMax: Double = 7600) -> [MelFilter] {
    let nyquist = sampleRate / 2
    let top = Swift.min(fMax, nyquist)
    let melMin = hzToMel(fMin)
    let melMax = hzToMel(top)
    let bins = fftSize / 2 + 1

    // filters + 2 punktów: każdy filtr ma lewy, środkowy i prawy wierzchołek.
    var points = [Int](repeating: 0, count: filters + 2)
    for i in 0..<points.count {
        let mel = melMin + (melMax - melMin) * Double(i) / Double(filters + 1)
        points[i] = Int(floor(Double(fftSize + 1) * melToHz(mel) / sampleRate))
    }

    var bank: [MelFilter] = []
    for m in 1...filters {
        let left = points[m - 1], center = points[m], right = points[m + 1]
        let start = Swift.max(0, left)
        let end = Swift.min(bins - 1, right)
        var weights = [Float](repeating: 0, count: Swift.max(0, end - start + 1))
        if end >= start {
            for k in start...end {
                var value = 0.0
                if k >= left && k <= center && center > left {
                    value = Double(k - left) / Double(center - left)
                } else if k > center && k <= right && right > center {
                    value = Double(right - k) / Double(right - center)
                }
                weights[k - start] = Float(value)
            }
        }
        bank.append(MelFilter(start: start, weights: weights))
    }
    return bank
}

/// Energie logarytmiczne w pasmach mel.
public func logMelEnergies(_ spectrum: [Float], bank: [MelFilter], floor: Double = 1e-10) -> [Double] {
    var out = [Double](repeating: 0, count: bank.count)
    for (m, filter) in bank.enumerated() {
        var sum = 0.0
        for i in 0..<filter.weights.count {
            let bin = filter.start + i
            if bin < spectrum.count { sum += Double(spectrum[bin]) * Double(filter.weights[i]) }
        }
        out[m] = log(Swift.max(sum, floor))
    }
    return out
}

/// DCT-II (ortonormalna) — pierwsze `count` współczynników.
public func dct2(_ input: [Double], count: Int) -> [Double] {
    let n = input.count
    var out = [Double](repeating: 0, count: count)
    let scale0 = (1.0 / Double(n)).squareRoot()
    let scale = (2.0 / Double(n)).squareRoot()
    for k in 0..<count {
        var sum = 0.0
        for i in 0..<n {
            sum += input[i] * cos(Double.pi * Double(k) * Double(2 * i + 1) / Double(2 * n))
        }
        out[k] = sum * (k == 0 ? scale0 : scale)
    }
    return out
}

/// Ekstraktor MFCC — trzyma okno, bank filtrów i plan FFT.
/// Jedna instancja na źródło audio.
public final class MfccExtractor {
    public let sampleRate: Double
    public let frameSize: Int
    public let hopSize: Int
    public let fftSize: Int
    public let cepstra: Int
    private let preemphasisCoeff: Float
    private let window: [Float]
    private let bank: [MelFilter]
    private let fft: FFTProcessor

    public init(sampleRate: Double = 16_000, frameMs: Double = 25, hopMs: Double = 10,
                melFilters: Int = 26, cepstra: Int = 12, fMin: Double = 80, fMax: Double = 7600,
                preemphasis: Double = 0.97) {
        self.sampleRate = sampleRate
        self.frameSize = Int((frameMs / 1000 * sampleRate).rounded())
        self.hopSize = Int((hopMs / 1000 * sampleRate).rounded())
        self.fftSize = nextPowerOfTwo(frameSize)
        self.cepstra = cepstra
        self.preemphasisCoeff = Float(preemphasis)
        // Okno Hamminga.
        var w = [Float](repeating: 0, count: frameSize)
        for i in 0..<frameSize {
            w[i] = Float(0.54 - 0.46 * cos(2 * Double.pi * Double(i) / Double(frameSize - 1)))
        }
        self.window = w
        self.bank = melFilterbank(sampleRate: sampleRate, fftSize: fftSize, filters: melFilters,
                                  fMin: fMin, fMax: fMax)
        self.fft = FFTProcessor(size: fftSize)!
    }

    /// MFCC pojedynczej ramki (bez c0 — c0 to głośność, nie barwa głosu).
    public func frameToMfcc(_ frame: [Float]) -> [Double] {
        precondition(frame.count == frameSize, "MfccExtractor: ramka musi mieć \(frameSize) próbek")
        // Preemfaza y[n] = x[n] - a·x[n-1]: podbija wysokie częstotliwości,
        // gdzie siedzi informacja o formantach.
        var padded = [Float](repeating: 0, count: fftSize)
        padded[0] = frame[0] * window[0]
        for i in 1..<frameSize {
            padded[i] = (frame[i] - preemphasisCoeff * frame[i - 1]) * window[i]
        }
        let spectrum = fft.powerSpectrum(padded)
        let mel = logMelEnergies(spectrum, bank: bank)
        let cepstrum = dct2(mel, count: cepstra + 1)
        return Array(cepstrum.dropFirst()) // odrzucamy c0
    }

    /// Energia ramki w dB — używana przez VAD.
    public static func frameEnergyDb(_ frame: [Float]) -> Double {
        var meanSquare: Float = 0
        vDSP_measqv(frame, 1, &meanSquare, vDSP_Length(frame.count))
        return 10 * log10(Swift.max(Double(meanSquare), 1e-12))
    }
}

/// Detekcja aktywności głosowej (VAD) na energii ramki.
///
/// Podłogę szumu wyznaczamy metodą statystyki minimum: sygnał tniemy na
/// podokna i pamiętamy minimum z każdego z nich, a podłoga to minimum z całego
/// bufora. To odporne na dwa przeciwne przypadki, na których wykłada się
/// naiwna średnia ruchoma:
///
///  - stały hałas (wentylator, muzyka) — średnia uznaje go za mowę na zawsze,
///    minimum poprawnie ustawia się na jego poziomie;
///  - długa nieprzerwana wypowiedź — minimum trzyma się przerw międzysylabowych,
///    więc podłoga nie wspina się do poziomu mowy i nie ucina jej w połowie.
public final class Vad {
    public struct State: Sendable {
        public var speaking: Bool
        public var started: Bool
        public var ended: Bool
        public var loud: Bool
    }

    /// O ile dB ponad podłogą szumu ramka liczy się jako mowa.
    public var thresholdDb: Double
    /// Ile kolejnych głośnych ramek otwiera wypowiedź (10 ms na ramkę).
    public var onsetFrames: Int
    /// Ile cichych ramek ją zamyka — krótkie pauzy w zdaniu nie mają jej ciąć.
    public var hangoverFrames: Int
    public var subwindowFrames: Int
    public let initialFloorDb: Double

    public private(set) var noiseFloorDb: Double
    public private(set) var speaking = false

    private var loudRun = 0
    private var quietRun = 0
    private var subMin = Double.infinity
    private var subCount = 0
    private var ring: [Double]
    private var ringIndex = 0

    public init(thresholdDb: Double = 12, onsetFrames: Int = 3, hangoverFrames: Int = 25,
                subwindowFrames: Int = 50, subwindows: Int = 6, initialFloorDb: Double = -70) {
        self.thresholdDb = thresholdDb
        self.onsetFrames = onsetFrames
        self.hangoverFrames = hangoverFrames
        self.subwindowFrames = subwindowFrames
        self.initialFloorDb = initialFloorDb
        // Bufor wypełniony podłogą startową: zanim uzbieramy historię, VAD ma
        // działać, a nie uznawać wszystkiego za ciszę.
        self.ring = [Double](repeating: initialFloorDb, count: subwindows)
        self.noiseFloorDb = initialFloorDb
    }

    @discardableResult
    public func push(_ energyDb: Double) -> State {
        trackNoiseFloor(energyDb)
        let loud = energyDb > noiseFloorDb + thresholdDb

        var started = false
        var ended = false

        if loud {
            loudRun += 1
            quietRun = 0
            if !speaking && loudRun >= onsetFrames {
                speaking = true
                started = true
            }
        } else {
            quietRun += 1
            loudRun = 0
            if speaking && quietRun >= hangoverFrames {
                speaking = false
                ended = true
            }
        }

        return State(speaking: speaking, started: started, ended: ended, loud: loud)
    }

    private func trackNoiseFloor(_ energyDb: Double) {
        if energyDb < subMin { subMin = energyDb }
        subCount += 1
        if subCount >= subwindowFrames {
            ring[ringIndex] = subMin
            ringIndex = (ringIndex + 1) % ring.count
            subMin = .infinity
            subCount = 0
        }
        var floor = ring.min() ?? initialFloorDb
        if subMin < floor { floor = subMin }
        noiseFloorDb = floor
    }

    public func reset() {
        speaking = false
        loudRun = 0
        quietRun = 0
        subMin = .infinity
        subCount = 0
        for i in ring.indices { ring[i] = initialFloorDb }
        noiseFloorDb = initialFloorDb
    }
}
