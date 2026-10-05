import Foundation
import AppKit
import CoreAudio
import CallWhisperCore

/// Wykrywanie rozmowy — z OpenWhispr (`meetingDetectionEngine`
/// + `macos-mic-listener.swift`), bez osobnego procesu nasłuchującego.
///
/// Co dwie sekundy pytamy CoreAudio, czy ktoś trzyma domyślne wejście,
/// i `NSWorkspace`, czy działa znany komunikator. To dwa tanie odczyty
/// właściwości, bez żadnych uprawnień — zgoda na mikrofon nie jest potrzebna,
/// żeby wiedzieć, *że* ktoś go używa.
@MainActor
public final class MeetingWatcher: ObservableObject {
    /// Nazwa aplikacji trwającej rozmowy albo `nil`.
    @Published public private(set) var activeMeeting: String?

    public var onChange: ((MeetingDetection.Debouncer.Change) -> Void)?

    private var debouncer = MeetingDetection.Debouncer()
    private var timer: Timer?

    public init() {}

    public var isRunning: Bool { timer != nil }

    public func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        debouncer = MeetingDetection.Debouncer()
        activeMeeting = nil
    }

    private func poll() {
        let workspace = NSWorkspace.shared
        let running = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
        let meeting = MeetingDetection.activeMeeting(
            micInUse: Self.microphoneInUse(),
            running: running,
            frontmost: workspace.frontmostApplication?.bundleIdentifier)
        if let change = debouncer.feed(meeting) {
            activeMeeting = debouncer.active
            onChange?(change)
        }
    }

    /// Czy jakikolwiek proces nagrywa z domyślnego wejścia.
    ///
    /// Uwaga: gdy nasłuch z mikrofonem jest włączony, to my sami trzymamy
    /// wejście — wtedy koniec rozmowy poznajemy już tylko po zamknięciu
    /// komunikatora.
    public static func microphoneInUse() -> Bool {
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}
