@preconcurrency import AVFoundation

/// Jednorazowa konwersja bufora przez `AVAudioConverter`.
///
/// `convert(to:error:withInputFrom:)` woła domknięcie synchronicznie i prosi
/// o dane tak długo, aż powiemy „nie mam więcej". Podajemy więc wejście
/// dokładnie raz. Domknięcie jest oznaczone `@Sendable`, choć nie opuszcza
/// wątku — stąd pudełko zamiast zwykłej zmiennej.
public func convertOnce(_ converter: AVAudioConverter, input: AVAudioPCMBuffer, into out: AVAudioPCMBuffer) -> Bool {
    final class Once: @unchecked Sendable { var done = false }
    let once = Once()
    let box = UncheckedBox(input)
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if once.done {
            status.pointee = .noDataNow
            return nil
        }
        once.done = true
        status.pointee = .haveData
        return box.value
    }
    return error == nil && out.frameLength > 0
}

/// Opakowanie dla typów Apple, które nie są `Sendable`, a i tak nie opuszczają
/// wątku wywołania.
public struct UncheckedBox<T>: @unchecked Sendable {
    public let value: T
    public init(_ value: T) { self.value = value }
}
