// swift-tools-version: 6.2
import PackageDescription

// Zero zależności zewnętrznych — tak jak w wersji webowej. Wszystko, czego
// potrzebujemy, jest w systemie: Accelerate (FFT), ScreenCaptureKit (dźwięk
// aplikacji), Speech (rozpoznawanie on-device), SwiftUI (UI).
let package = Package(
    name: "CallWhisper",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "call-whisper", targets: ["CallWhisper"]),
        .library(name: "CallWhisperCore", targets: ["CallWhisperCore"]),
    ],
    targets: [
        // Czysta logika: tekst, transkrypt, markdown, DSP, wykrywanie pytań.
        // Bez UI i bez AV — dzięki temu chodzi w testach bez uprawnień systemowych.
        .target(name: "CallWhisperCore"),

        // Warstwa platformy: przechwytywanie dźwięku, ASR, klient asystenta.
        .target(name: "CallWhisperKit", dependencies: ["CallWhisperCore"]),

        // Aplikacja.
        .executableTarget(name: "CallWhisper", dependencies: ["CallWhisperKit"]),

        .testTarget(
            name: "CallWhisperCoreTests",
            dependencies: ["CallWhisperCore"],
            resources: [.copy("fixtures.json")]
        ),
    ]
)
