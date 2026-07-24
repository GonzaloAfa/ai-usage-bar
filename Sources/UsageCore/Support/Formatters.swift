import Foundation

/// Todo el texto con formato de la interfaz, en español de Chile.
///
/// Los formateadores se construyen en cada llamada porque los de Foundation no son `Sendable` y
/// compartirlos exigiría sincronización. El costo es irrelevante: unas pocas cadenas por segundo
/// mientras el popover está abierto, y ninguna cuando está cerrado.
public enum UsageFormat {
    public static let locale = Locale(identifier: "es-CL")

    // MARK: Porcentajes

    private static func percentFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }

    /// `39` → `39 %`. La API entrega el valor ya en escala 0–100.
    public static func percent(_ value: Double) -> String {
        percentFormatter().string(from: NSNumber(value: value / 100))
            ?? "\(Int(value.rounded())) %"
    }

    public static func percentUsed(_ value: Double) -> String {
        "\(percent(value)) usado"
    }

    // MARK: Reinicios

    /// `3 h 17 min`, como en la pantalla de Uso de Claude.
    ///
    /// A mano y no con `DateComponentsFormatter`: en español intercala una conjunción («3 h y 17 min»)
    /// que alarga la línea sin aportar nada.
    static func duration(_ seconds: TimeInterval) -> String {
        let totalMinutes = max(Int(seconds / 60), 1)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        switch (hours, minutes) {
        case (0, let minutes): return "\(minutes) min"
        case (let hours, 0): return "\(hours) h"
        case (let hours, let minutes): return "\(hours) h \(minutes) min"
        }
    }

    private static func weekdayTimeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE jmm")
        return formatter
    }

    /// Cuándo se libera un límite.
    ///
    /// Dentro de las próximas 24 h la forma relativa es la útil («en 3 h 17 min»); más allá de eso
    /// deja de decir algo y conviene el día y la hora («dom, 5:59 a.m.»), igual que hace la pantalla
    /// de Uso de Claude.
    public static func resetPhrase(
        for date: Date,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) -> String {
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "Se restablece en cualquier momento" }

        if seconds < 24 * 3600 {
            return "Se restablece en \(duration(seconds))"
        }
        return "Se restablece \(weekdayTimeFormatter(timeZone: timeZone).string(from: date))"
    }

    // MARK: Última actualización

    public static func lastUpdated(_ date: Date, now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(date).rounded())
        switch seconds {
        case ..<10: return "Actualizado justo ahora"
        case ..<60: return "Actualizado hace \(seconds) s"
        case ..<3600: return "Actualizado hace \(seconds / 60) min"
        default: return "Actualizado hace \(seconds / 3600) h"
        }
    }

    // MARK: Dinero

    public static func money(_ amount: Double, currency: String?) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .currency
        formatter.currencyCode = currency ?? "USD"
        return formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    }
}
