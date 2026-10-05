import Foundation
import AppKit
import UniformTypeIdentifiers

/// Obrazek dołączony do pytania — zwykle zrzut ekranu wklejony przez Cmd+V.
public struct AssistantImage: Sendable, Equatable {
    public var data: Data
    public var mediaType: String

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }

    /// Dłuższy bok, do którego przeskalowujemy.
    ///
    /// Zrzut z ekranu Retina to często 3000 px i kilka MB. Po zakodowaniu
    /// base64 rośnie o kolejną jedną trzecią i prompt robi się wolniejszy niż
    /// sama odpowiedź, a modele i tak nie korzystają z rozdzielczości powyżej
    /// ~1500 px.
    static let maxDimension: CGFloat = 1568

    /// Wyciąga obrazek ze schowka i przeskalowuje, jeśli trzeba.
    @MainActor
    public static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> AssistantImage? {
        // Kolejność ma znaczenie: PNG zachowuje ostrość zrzutu, TIFF bywa
        // ogromny, a `NSImage` jest ostatnią deską ratunku.
        if let data = pasteboard.data(forType: .png) {
            return downscaled(data) ?? AssistantImage(data: data, mediaType: "image/png")
        }
        if let data = pasteboard.data(forType: .tiff), let downscaled = downscaled(data) {
            return downscaled
        }
        guard let image = NSImage(pasteboard: pasteboard) else { return nil }
        return encode(image)
    }

    /// Czy w schowku jest cokolwiek, co da się dołączyć.
    @MainActor
    public static func pasteboardHasImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        pasteboard.canReadItem(withDataConformingToTypes: [
            UTType.png.identifier, UTType.tiff.identifier, UTType.jpeg.identifier,
        ])
    }

    /// Przeskalowuje obrazek z surowych danych. Publiczne, bo tą samą drogą
    /// idzie wklejanie w oknie i wczytanie pliku z linii poleceń.
    public static func downscaled(_ data: Data) -> AssistantImage? {
        guard let source = NSBitmapImageRep(data: data) else { return nil }
        let width = CGFloat(source.pixelsWide), height = CGFloat(source.pixelsHigh)
        let longest = Swift.max(width, height)
        guard longest > maxDimension else {
            // Mieści się — ale i tak przepuszczamy przez PNG, żeby ujednolicić typ.
            return source.representation(using: .png, properties: [:])
                .map { AssistantImage(data: $0, mediaType: "image/png") }
        }

        let scale = maxDimension / longest
        let target = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let image = NSImage(size: target)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        source.draw(in: NSRect(origin: .zero, size: target))
        image.unlockFocus()
        return encode(image)
    }

    static func encode(_ image: NSImage) -> AssistantImage? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        return AssistantImage(data: png, mediaType: "image/png")
    }

    public var base64: String { data.base64EncodedString() }
    public var dataURI: String { "data:\(mediaType);base64,\(base64)" }
    public var sizeDescription: String {
        String(format: "%.0f kB", Double(data.count) / 1024)
    }

    /// Podgląd do interfejsu.
    @MainActor
    public var preview: NSImage? { NSImage(data: data) }
}
