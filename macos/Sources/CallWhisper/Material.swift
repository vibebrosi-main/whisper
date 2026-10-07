import SwiftUI
import AppKit

/// Material Design 3 (m3.material.io) odwzorowany w SwiftUI.
///
/// Bez biblioteki, tak samo jak HeroUI w rozszerzeniu: bierzemy wygląd design
/// systemu (role kolorów, skalę kształtów, typografię, warstwy stanu),
/// a nie zależność. Paleta to schemat Google Workspace (Gmail, Kalendarz,
/// Dysk), czyli M3 wygenerowany z niebieskiego #0B57D0, w wersji jasnej
/// i ciemnej. Kolory przełączają się same za wyglądem systemu.
enum M3 {
    // MARK: - kolory

    /// Role kolorów M3. Nazwy 1:1 z m3.material.io/styles/color/roles.
    enum color {
        static let primary = dyn(0x0B57D0, 0xA8C7FA)
        static let onPrimary = dyn(0xFFFFFF, 0x062E6F)
        static let primaryContainer = dyn(0xD3E3FD, 0x0842A0)
        static let onPrimaryContainer = dyn(0x041E49, 0xD3E3FD)
        static let secondaryContainer = dyn(0xC2E7FF, 0x004A77)
        static let onSecondaryContainer = dyn(0x001D35, 0xC2E7FF)
        static let tertiary = dyn(0x146C2E, 0x6DD58C)
        static let tertiaryContainer = dyn(0xC4EED0, 0x0F5223)
        static let onTertiaryContainer = dyn(0x072711, 0xC4EED0)
        static let error = dyn(0xB3261E, 0xF2B8B5)
        static let errorContainer = dyn(0xF9DEDC, 0x8C1D18)
        static let onErrorContainer = dyn(0x410E0B, 0xF9DEDC)

        static let surface = dyn(0xF8FAFD, 0x131314)
        static let surfaceContainerLowest = dyn(0xFFFFFF, 0x0E0E0E)
        static let surfaceContainerLow = dyn(0xF3F6FC, 0x1B1B1B)
        static let surfaceContainer = dyn(0xF0F4F9, 0x1E1F20)
        static let surfaceContainerHigh = dyn(0xE9EEF6, 0x282A2C)
        static let surfaceContainerHighest = dyn(0xDDE3EA, 0x333537)
        static let onSurface = dyn(0x1F1F1F, 0xE3E3E3)
        static let onSurfaceVariant = dyn(0x444746, 0xC4C7C5)
        static let outline = dyn(0x747775, 0x8E918F)
        static let outlineVariant = dyn(0xC4C7C5, 0x444746)

        /// Role układu jak w Gmailu i Gemini: strona, na niej karty treści,
        /// w kartach elementy wsunięte. W jasnym karty są białe na
        /// szaroniebieskiej stronie, w ciemnym jaśniejsze od strony, nie
        /// ciemniejsze (surface container lowest wyglądał tam jak dziura).
        static let page = dyn(0xF0F4F9, 0x131314)
        static let card = dyn(0xFFFFFF, 0x1E1F20)
        static let cardInset = dyn(0xF0F4F9, 0x282A2C)
        static let cardField = dyn(0xE9EEF6, 0x333537)

        /// Kolor zależny od wyglądu systemu, bez katalogu zasobów (SwiftPM
        /// go nie ma, a my nie chcemy kroku build).
        private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                let hex = isDark ? dark : light
                return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                               green: CGFloat((hex >> 8) & 0xFF) / 255,
                               blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
            })
        }
    }

    // MARK: - kształty

    /// Skala kształtów M3 (m3.material.io/styles/shape/corner-radius-scale).
    enum shape {
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let extraLarge: CGFloat = 28
    }

    // MARK: - typografia

    /// Skala typografii M3. Google Sans nie jest dostępny w systemie, więc
    /// rozmiary, grubości i interlinie z M3 dostaje krój systemowy.
    enum type {
        static let headlineSmall = Font.system(size: 24, weight: .regular)
        static let titleLarge = Font.system(size: 22, weight: .regular)
        static let titleMedium = Font.system(size: 16, weight: .medium)
        static let titleSmall = Font.system(size: 14, weight: .medium)
        static let bodyLarge = Font.system(size: 16, weight: .regular)
        static let bodyMedium = Font.system(size: 14, weight: .regular)
        static let bodySmall = Font.system(size: 12, weight: .regular)
        static let labelLarge = Font.system(size: 14, weight: .medium)
        static let labelMedium = Font.system(size: 12, weight: .medium)
        static let labelSmall = Font.system(size: 11, weight: .medium)
    }

    // MARK: - warstwy stanu

    /// Krycie warstwy stanu: najechanie 8 %, wciśnięcie 10 %
    /// (m3.material.io/foundations/interaction/states/state-layers).
    static func stateOpacity(hovered: Bool, pressed: Bool) -> Double {
        pressed ? 0.10 : (hovered ? 0.08 : 0)
    }
}

// MARK: - przyciski

/// Wspólna mechanika przycisków M3: kapsuła, wysokość 40, warstwa stanu
/// w kolorze treści, przygaszenie wyłączonego do 38 %.
struct M3ButtonStyle: ButtonStyle {
    enum Kind { case filled, tonal, outlined, text, error }
    var kind: Kind = .filled
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        M3ButtonBody(configuration: configuration, kind: kind, compact: compact)
    }
}

private struct M3ButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: M3ButtonStyle.Kind
    let compact: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    private var container: Color {
        switch kind {
        case .filled: return M3.color.primary
        case .tonal: return M3.color.secondaryContainer
        case .error: return M3.color.errorContainer
        case .outlined, .text: return .clear
        }
    }

    private var content: Color {
        switch kind {
        case .filled: return M3.color.onPrimary
        case .tonal: return M3.color.onSecondaryContainer
        case .error: return M3.color.onErrorContainer
        case .outlined, .text: return M3.color.primary
        }
    }

    var body: some View {
        configuration.label
            .font(M3.type.labelLarge)
            .labelStyle(M3LabelStyle())
            .foregroundStyle(isEnabled ? content : M3.color.onSurface.opacity(0.38))
            .padding(.horizontal, kind == .text ? 12 : (compact ? 16 : 24))
            .frame(height: compact ? 32 : 40)
            .background {
                Capsule().fill(isEnabled ? container
                               : (kind == .outlined || kind == .text ? .clear : M3.color.onSurface.opacity(0.12)))
            }
            .overlay {
                Capsule().fill(content.opacity(M3.stateOpacity(hovered: hovered, pressed: configuration.isPressed)))
            }
            .overlay {
                if kind == .outlined {
                    Capsule().strokeBorder(isEnabled ? M3.color.outline : M3.color.onSurface.opacity(0.12))
                }
            }
            .contentShape(Capsule())
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.12), value: hovered)
    }
}

/// Ikona 18 pt i 8 pt odstępu, jak w przyciskach M3 z ikoną.
struct M3LabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.font(.system(size: 16, weight: .medium))
            configuration.title
        }
    }
}

/// Przycisk-ikona M3: okrąg 40 pt, warstwa stanu w kolorze ikony.
/// `selected` daje wariant przełącznika (tonalne wypełnienie).
struct M3IconButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        M3IconButtonBody(configuration: configuration, selected: selected)
    }
}

private struct M3IconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let tint = selected ? M3.color.onSecondaryContainer : M3.color.onSurfaceVariant
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 18, weight: .regular))
            .foregroundStyle(isEnabled ? tint : M3.color.onSurface.opacity(0.38))
            .frame(width: 40, height: 40)
            .background(Circle().fill(selected ? M3.color.secondaryContainer : .clear))
            .overlay(Circle().fill(tint.opacity(M3.stateOpacity(hovered: hovered, pressed: configuration.isPressed))))
            .contentShape(Circle())
            .onHover { hovered = $0 }
    }
}

/// Rozszerzony FAB M3: główna akcja ekranu. Kontener primary w wersji
/// „primary container", róg 16, wysokość 56, uniesienie poziomu 3.
struct M3FABStyle: ButtonStyle {
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        M3FABBody(configuration: configuration, active: active)
    }
}

private struct M3FABBody: View {
    let configuration: ButtonStyleConfiguration
    let active: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let container = active ? M3.color.errorContainer : M3.color.primaryContainer
        let content = active ? M3.color.onErrorContainer : M3.color.onPrimaryContainer
        configuration.label
            .font(M3.type.labelLarge)
            .labelStyle(M3LabelStyle())
            .foregroundStyle(content)
            .padding(.horizontal, 20)
            .frame(height: 56)
            .background(RoundedRectangle(cornerRadius: M3.shape.large).fill(container))
            .overlay(RoundedRectangle(cornerRadius: M3.shape.large)
                .fill(content.opacity(M3.stateOpacity(hovered: hovered, pressed: configuration.isPressed))))
            .shadow(color: .black.opacity(0.18), radius: hovered ? 8 : 5, y: hovered ? 4 : 3)
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(RoundedRectangle(cornerRadius: M3.shape.large))
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: 0.15), value: hovered)
    }
}

/// Przycisk szyny nawigacji M3: ikona we wskaźniku 56×32 (kapsuła), pod nią
/// etykieta. `selected` daje wypełnienie secondary container.
struct M3RailButtonStyle: ButtonStyle {
    var selected = false

    func makeBody(configuration: Configuration) -> some View {
        M3RailButtonBody(configuration: configuration, selected: selected)
    }
}

private struct M3RailButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .labelStyle(M3RailLabelStyle(selected: selected,
                                         overlayOpacity: M3.stateOpacity(hovered: hovered, pressed: configuration.isPressed)))
            .opacity(isEnabled ? 1 : 0.38)
            .onHover { hovered = $0 }
    }
}

/// Wygląd pozycji szyny; osobno, bo etykieta `Menu` nie przechodzi przez
/// `ButtonStyle`.
struct M3RailLabelStyle: LabelStyle {
    var selected = false
    var overlayOpacity: Double = 0

    func makeBody(configuration: Configuration) -> some View {
        VStack(spacing: 4) {
            configuration.icon
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(selected ? M3.color.onSecondaryContainer : M3.color.onSurfaceVariant)
                .frame(width: 56, height: 32)
                .background(Capsule().fill(selected ? M3.color.secondaryContainer : .clear))
                .overlay(Capsule().fill((selected ? M3.color.onSecondaryContainer : M3.color.onSurfaceVariant)
                    .opacity(overlayOpacity)))
            configuration.title
                .font(M3.type.labelMedium)
                .foregroundStyle(selected ? M3.color.onSurface : M3.color.onSurfaceVariant)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 72)
        .contentShape(Rectangle())
    }
}

// MARK: - powierzchnie

extension View {
    /// Karta M3. `filled` = surface container highest, `outlined` = obrys
    /// outline variant na surface, `elevated` = low + cień poziomu 1.
    func m3Card(_ style: M3CardStyle = .filled, radius: CGFloat = M3.shape.medium) -> some View {
        modifier(M3CardModifier(style: style, radius: radius))
    }
}

enum M3CardStyle { case filled, outlined, elevated }

private struct M3CardModifier: ViewModifier {
    let style: M3CardStyle
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        switch style {
        case .filled:
            content.background(M3.color.surfaceContainerHighest, in: shape)
        case .outlined:
            content.background(M3.color.surface, in: shape)
                .overlay(shape.strokeBorder(M3.color.outlineVariant))
        case .elevated:
            content.background(M3.color.surfaceContainerLow, in: shape)
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
    }
}

/// Chip M3 (asystujący / informacyjny): róg 8, wysokość 32, obrys albo
/// tonalne wypełnienie, gdy wybrany.
struct M3Chip: View {
    var text: String
    var systemImage: String?
    var selected = false
    var tint: Color? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 13, weight: .medium))
                    .foregroundStyle(tint ?? (selected ? M3.color.onSecondaryContainer : M3.color.primary))
            }
            Text(text).font(M3.type.labelLarge)
                .foregroundStyle(selected ? M3.color.onSecondaryContainer : M3.color.onSurfaceVariant)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: M3.shape.small)
            .fill(selected ? M3.color.secondaryContainer : .clear))
        .overlay(RoundedRectangle(cornerRadius: M3.shape.small)
            .strokeBorder(selected ? .clear : M3.color.outlineVariant))
    }
}

/// Pole tekstowe M3 w wariancie „filled": tło surface container highest,
/// górne rogi 4, dolna linia aktywna w kolorze primary.
struct M3FieldBackground: ViewModifier {
    var focused: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(M3.color.surfaceContainerHighest,
                        in: UnevenRoundedRectangle(topLeadingRadius: M3.shape.extraSmall,
                                                   topTrailingRadius: M3.shape.extraSmall))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(focused ? M3.color.primary : M3.color.onSurfaceVariant)
                    .frame(height: focused ? 2 : 1)
            }
    }
}

/// Wskaźnik liniowy M3: tor secondary container, wskaźnik primary.
struct M3LinearProgress: View {
    @State private var phase: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(M3.color.secondaryContainer)
                Capsule().fill(M3.color.primary)
                    .frame(width: geo.size.width * 0.4)
                    .offset(x: geo.size.width * phase)
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
        }
    }
}
