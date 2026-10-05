import Foundation

/// Kodowanie PCM do WAV.
///
/// `whisper-server` przyjmuje pliki, nie strumienie, więc każdą wypowiedź
/// trzeba opakować w kontener. 16-bit PCM mono to najprostszy format, który
/// rozumie każdy dekoder.
///
/// Port z `extension/src/adapters/audio/wav.js`.
public enum Wav {
    private static let headerBytes = 44

    /// Float32 [-1, 1] -> int16 z obcięciem zakresu.
    private static func toInt16(_ sample: Float) -> Int16 {
        let clamped = Swift.max(-1, Swift.min(1, sample))
        let scaled = clamped < 0 ? Double(clamped) * 32768 : Double(clamped) * 32767
        return Int16(scaled.rounded(.towardZero))
    }

    public static func encode(_ samples: [Float], sampleRate: Int = 16_000, channels: Int = 1) -> Data {
        let bytesPerSample = 2
        let dataBytes = samples.count * bytesPerSample
        var data = Data(capacity: headerBytes + dataBytes)

        func ascii(_ text: String) { data.append(contentsOf: Array(text.utf8)) }
        func u32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        ascii("RIFF")
        u32(UInt32(36 + dataBytes))          // rozmiar pliku - 8
        ascii("WAVE")

        ascii("fmt ")
        u32(16)                              // długość bloku fmt
        u16(1)                               // 1 = PCM bez kompresji
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * channels * bytesPerSample))  // bajtów na sekundę
        u16(UInt16(channels * bytesPerSample))               // wyrównanie bloku
        u16(UInt16(8 * bytesPerSample))

        ascii("data")
        u32(UInt32(dataBytes))

        for sample in samples {
            withUnsafeBytes(of: toInt16(sample).littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Długość audio w ms dla danej liczby próbek.
    public static func durationMs(sampleCount: Int, sampleRate: Double = 16_000) -> Double {
        Double(sampleCount) / sampleRate * 1000
    }
}
