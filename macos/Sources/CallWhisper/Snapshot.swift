import SwiftUI
import AppKit
import CallWhisperKit

/// `call-whisper --snapshot <katalog> [nagranie]` - render okna głównego do PNG,
/// w jasnym i ciemnym wyglądzie.
///
/// Narzędzie do pracy nad wyglądem (Material 3): okno rysowane poza ekranem
/// przez `cacheDisplay`, więc nie wymaga zgody na nagrywanie ekranu
/// i pokazuje prawdziwe kontrolki AppKit, których `ImageRenderer` nie umie.
@MainActor
func runSnapshot(directory: String, file: String?) async -> Int32 {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let recorder = Recorder()
    if let file {
        recorder.importFile(URL(fileURLWithPath: file))
        while recorder.isProcessing { try? await Task.sleep(for: .milliseconds(200)) }
    }
    recorder.refreshReadiness()

    let out = URL(fileURLWithPath: directory)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for (name, appearance) in [("jasny", NSAppearance.Name.aqua), ("ciemny", .darkAqua)] {
        let view = MainView(recorder: recorder, settings: .shared, overlay: OverlayController(),
                            meetings: MeetingWatcher())
            .frame(width: 980, height: 680)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 980, height: 680)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .milliseconds(600))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return 1 }
        host.cacheDisplay(in: host.bounds, to: rep)
        let path = out.appendingPathComponent("okno-\(name).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: path)
        print(path.path)
    }
    return 0
}
