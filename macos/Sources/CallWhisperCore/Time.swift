import Foundation

/// Formatowanie czasu. Port z `extension/src/core/time.js`.
public enum TimeFormat {
    private static func pad(_ n: Int, _ width: Int = 2) -> String {
        String(abs(n)).leftPadded(to: width, with: "0")
    }

    /// Offset od początku sesji jako HH:MM:SS (godziny nieograniczone).
    public static func offset(_ ms: Double) -> String {
        let seconds = ms.isFinite ? (ms / 1000).rounded() : 0
        let total = Swift.max(0, Int(seconds))
        return "\(pad(total / 3600)):\(pad((total % 3600) / 60)):\(pad(total % 60))"
    }

    /// Czas trwania w formacie zwięzłym: 42m 11s / 1h 02m / 8s
    public static func duration(_ ms: Double) -> String {
        let seconds = ms.isFinite ? (ms / 1000).rounded() : 0
        let total = Swift.max(0, Int(seconds))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return "\(h)h \(pad(m))m" }
        if m > 0 { return "\(m)m \(pad(s))s" }
        return "\(s)s"
    }

    private static func components(_ ts: Double) -> DateComponents {
        let date = Date(timeIntervalSince1970: ts / 1000)
        return Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    }

    public static func localDate(_ ts: Double) -> String {
        let c = components(ts)
        return "\(c.year ?? 0)-\(pad(c.month ?? 0))-\(pad(c.day ?? 0))"
    }

    public static func localTime(_ ts: Double, withSeconds: Bool = true) -> String {
        let c = components(ts)
        let base = "\(pad(c.hour ?? 0)):\(pad(c.minute ?? 0))"
        return withSeconds ? "\(base):\(pad(c.second ?? 0))" : base
    }

    public static func localDateTime(_ ts: Double, withSeconds: Bool = true) -> String {
        "\(localDate(ts)) \(localTime(ts, withSeconds: withSeconds))"
    }

    /// Stempel do nazwy pliku: 2026-08-23_1015
    public static func filenameStamp(_ ts: Double) -> String {
        let c = components(ts)
        return "\(localDate(ts))_\(pad(c.hour ?? 0))\(pad(c.minute ?? 0))"
    }
}

extension String {
    func leftPadded(to width: Int, with pad: Character) -> String {
        count >= width ? self : String(repeating: String(pad), count: width - count) + self
    }
}

/// Czas w milisekundach od epoki — ten sam „zegar", którym posługiwał się JS.
public func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
