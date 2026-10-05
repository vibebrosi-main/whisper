import Foundation

/// Kołowy bufor audio.
///
/// Diaryzator mówi „tura mówcy trwała od 12 340 ms do 17 800 ms" dopiero po jej
/// zakończeniu — więc surowe audio musi gdzieś czekać, żeby dało się je wtedy
/// wyciąć i wysłać do transkrypcji. Bufor trzyma ostatnie N sekund i pozwala
/// czytać po czasie, nie po indeksie.
///
/// Port z `extension/src/adapters/audio/ring.js`.
public final class AudioRing {
    public let sampleRate: Double
    public let epochMs: Double
    public let capacity: Int

    private var buffer: [Float]
    private var written = 0

    public init(sampleRate: Double = 16_000, seconds: Double = 90, epochMs: Double = 0) {
        self.sampleRate = sampleRate
        self.epochMs = epochMs
        self.capacity = Swift.max(1, Int((sampleRate * seconds).rounded()))
        self.buffer = [Float](repeating: 0, count: capacity)
    }

    public func write(_ samples: ArraySlice<Float>) {
        for (i, sample) in samples.enumerated() {
            buffer[(written + i) % capacity] = sample
        }
        written += samples.count
    }

    public func write(_ samples: [Float]) { write(samples[...]) }

    /// Najstarszy czas, który jeszcze pamiętamy.
    public var oldestMs: Double {
        let oldestSample = Swift.max(0, written - capacity)
        return epochMs + Double(oldestSample) / sampleRate * 1000
    }

    public var newestMs: Double {
        epochMs + Double(written) / sampleRate * 1000
    }

    public var writtenSamples: Int { written }

    /// Wycinek audio dla zakresu czasu. Zakres jest przycinany do tego, co bufor
    /// jeszcze pamięta — lepiej oddać krótszą wypowiedź niż nic.
    /// Zwraca `nil`, gdy zakres wypadł całkowicie poza bufor.
    public func readRange(from startMs: Double, to endMs: Double) -> [Float]? {
        guard endMs > startMs else { return nil }

        func toSample(_ ms: Double) -> Int { Int((((ms - epochMs) / 1000) * sampleRate).rounded()) }
        let oldest = Swift.max(0, written - capacity)
        let from = Swift.max(oldest, toSample(startMs))
        let to = Swift.min(written, toSample(endMs))
        guard to > from else { return nil }

        var out = [Float](repeating: 0, count: to - from)
        for i in 0..<out.count {
            out[i] = buffer[(from + i) % capacity]
        }
        return out
    }

    public func reset() {
        for i in buffer.indices { buffer[i] = 0 }
        written = 0
    }
}
