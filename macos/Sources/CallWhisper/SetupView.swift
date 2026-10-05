import SwiftUI
import AppKit
import CallWhisperKit

/// Panel gotowości: co jest, czego brakuje i co da się kliknąć.
///
/// Bez tego jedyną informacją o brakach jest komunikat błędu w pasku stanu,
/// który pojawia się dopiero po kliknięciu „Słuchaj" — czyli w najgorszym
/// możliwym momencie.
struct SetupView: View {
    @ObservedObject var recorder: Recorder
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Okno dialogowe M3: ikona, nagłówek, treść, akcje tekstowe po prawej.
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: recorder.readiness.allGood ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(M3.color.primary)
                Text("Gotowość").font(M3.type.headlineSmall).foregroundStyle(M3.color.onSurface)
                Text(recorder.readiness.allGood
                     ? "Wszystko na miejscu, możesz zaczynać."
                     : "Kilku rzeczy jeszcze brakuje. Większość aplikacja załatwi sama.")
                    .font(M3.type.bodyMedium)
                    .foregroundStyle(M3.color.onSurfaceVariant)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(recorder.readiness.checks) { check in row(check) }
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Sprawdź ponownie") { recorder.refreshReadiness() }
                    .buttonStyle(M3ButtonStyle(kind: .text))
                Button("Gotowe") { dismiss() }
                    .buttonStyle(M3ButtonStyle(kind: .filled))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(24)
        }
        .frame(width: 540, height: 480)
        .background(M3.color.surfaceContainerHigh)
        .tint(M3.color.primary)
        .onAppear { recorder.refreshReadiness() }
    }

    @ViewBuilder
    private func row(_ check: Readiness.Check) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: check.ok ? "checkmark" : "exclamationmark")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(check.ok ? M3.color.onTertiaryContainer : M3.color.onErrorContainer)
                .frame(width: 32, height: 32)
                .background(check.ok ? M3.color.tertiaryContainer : M3.color.errorContainer, in: Circle())

            VStack(alignment: .leading, spacing: 4) {
                Text(check.title).font(M3.type.titleSmall).foregroundStyle(M3.color.onSurface)
                Text(check.detail).font(M3.type.bodyMedium).foregroundStyle(M3.color.onSurfaceVariant)
                if !check.ok, let fix = check.fix { action(fix).padding(.top, 6) }
            }
            Spacer()
        }
        .padding(16)
        .background(M3.color.surfaceContainerLowest, in: RoundedRectangle(cornerRadius: M3.shape.medium))
    }

    @ViewBuilder
    private func action(_ fix: Readiness.Check.Fix) -> some View {
        switch fix {
        case .openScreenRecordingSettings:
            Button("Otwórz Ustawienia systemowe") {
                // Pierwszy raz pokaże systemowy monit; potem trzeba już ręcznie.
                _ = Readiness.requestScreenRecording()
                NSWorkspace.shared.open(Readiness.screenRecordingSettingsURL)
            }
            .buttonStyle(M3ButtonStyle(kind: .tonal, compact: true))

        case .downloadEngine(let component):
            HStack(spacing: 8) {
                Button(recorder.isProcessing ? "Pobieram…" : "Pobierz teraz") {
                    Task { await recorder.install(component) }
                }
                .buttonStyle(M3ButtonStyle(kind: .tonal, compact: true))
                .disabled(recorder.isProcessing)
                if recorder.isProcessing {
                    Text(recorder.status).font(M3.type.bodySmall).foregroundStyle(M3.color.onSurfaceVariant)
                }
            }

        case .downloadModel:
            Text("Pobierze się sam przy pierwszym kliknięciu „Słuchaj”.")
                .font(M3.type.bodySmall).foregroundStyle(M3.color.onSurfaceVariant)

        case .installClaudeCode:
            Button("Jak zainstalować Claude Code") {
                NSWorkspace.shared.open(Readiness.claudeInstallURL)
            }
            .buttonStyle(M3ButtonStyle(kind: .tonal, compact: true))
        }
    }
}
