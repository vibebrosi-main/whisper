import Testing
import Foundation
@testable import CallWhisperCore

/// Bufor kołowy i koder WAV — obie rzeczy stoją między diaryzatorem
/// a whisperem, więc cicha rozbieżność z wersją JS dałaby transkrypcję
/// przesuniętą w czasie albo szum zamiast mowy.
struct AudioIOTests {
    @Test func buforKolowyZgadzaSieZJS() {
        let ring = AudioRing(sampleRate: 1000, seconds: 1, epochMs: 0)
        ring.write((0..<600).map { Float($0) / 1000 })

        let expectedA = (FixtureTests.fixtures["ringA"] as! [Double]).map { Float($0) }
        let a = ring.readRange(from: 100, to: 300)
        #expect(a != nil)
        #expect(a!.count == expectedA.count)
        for (x, y) in zip(a!, expectedA) { #expect(abs(x - y) < 1e-6) }

        ring.write((0..<600).map { Float(600 + $0) / 1000 })

        // Bufor się zawinął — najstarsze próbki wypadły i zakres jest przycinany
        // do tego, co jeszcze pamiętamy. Lepiej krótsza wypowiedź niż żadna.
        let expectedB = (FixtureTests.fixtures["ringB"] as! [Double]).map { Float($0) }
        let b = ring.readRange(from: 0, to: 400)
        #expect(b != nil)
        #expect(b!.count == expectedB.count, "po zawinięciu: \(b!.count) vs \(expectedB.count)")
        for (x, y) in zip(b!, expectedB) { #expect(abs(x - y) < 1e-6) }

        let meta = FixtureTests.fixtures["ringMeta"] as! [String: Any]
        #expect(ring.oldestMs == (meta["oldestMs"] as! NSNumber).doubleValue)
        #expect(ring.newestMs == (meta["newestMs"] as! NSNumber).doubleValue)
        #expect(ring.writtenSamples == (meta["written"] as! NSNumber).intValue)
        #expect((ring.readRange(from: 2000, to: 2500) == nil) == (meta["outOfRange"] as! Bool))
        #expect((ring.readRange(from: 300, to: 300) == nil) == (meta["inverted"] as! Bool))
    }

    @Test func wavZgadzaSieZJSCoDoBajtu() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        let data = Wav.encode(samples, sampleRate: 16_000)
        let expected = (FixtureTests.fixtures["wavBytes"] as! [Int]).map { UInt8($0) }
        #expect(data.count == expected.count, "długość WAV")
        #expect(Array(data) == expected, "bajty WAV muszą się zgadzać co do jednego")
    }

    @Test func czyszczenieTekstuWhisperaZgadzaSieZJS() {
        let cases = FixtureTests.cases("cleanCases")
        #expect(!cases.isEmpty)
        for c in cases {
            let input = c["input"] as! String
            #expect(Text.cleanWhisper(input) == c["result"] as! String, "cleanWhisper(\(input))")
        }
    }

    @Test func nagłówekWavJestPoprawny() {
        let data = Wav.encode([Float](repeating: 0, count: 160), sampleRate: 16_000)
        #expect(data.count == 44 + 320)
        #expect(Array(data[0..<4]) == Array("RIFF".utf8))
        #expect(Array(data[8..<12]) == Array("WAVE".utf8))
        #expect(Array(data[36..<40]) == Array("data".utf8))
    }
}
