import Foundation

/// Gravedad de un límite. La API ya manda un `severity`, pero lo cruzamos con el porcentaje para no
/// depender de que su umbral coincida con lo que queremos mostrar.
public enum Severity: String, Codable, Sendable, Comparable, CaseIterable {
    case normal
    case warning
    case critical

    /// Umbrales propios: a partir de 70 % avisamos, a partir de 90 % es crítico.
    public static func derived(fromPercent percent: Double) -> Severity {
        switch percent {
        case 90...: return .critical
        case 70...: return .warning
        default: return .normal
        }
    }

    /// Lo que dice la API, cuando lo entendemos.
    public static func fromAPI(_ raw: String?) -> Severity? {
        switch raw?.lowercased() {
        case "normal", "ok": return .normal
        case "warning", "warn": return .warning
        case "critical", "exceeded", "blocked": return .critical
        default: return nil
        }
    }

    private var rank: Int {
        switch self {
        case .normal: return 0
        case .warning: return 1
        case .critical: return 2
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

/// Una fila del popover: un límite listo para dibujar, sin rastros de la forma de la API.
public struct LimitGauge: Identifiable, Codable, Sendable, Equatable {
    public enum Group: String, Codable, Sendable, Equatable {
        case session
        case weekly
        case other

        /// A qué grupo pertenece una ventana según cuánto dura.
        ///
        /// Se clasifica por duración y no por el nombre que le ponga cada API: Anthropic habla de
        /// `five_hour`/`seven_day` y OpenAI de `primary`/`secondary`, pero una ventana de cinco
        /// horas es la sesión en los dos.
        public static func forWindow(seconds: TimeInterval) -> Group {
            switch seconds {
            case ..<0: return .other
            case ...(6 * 3600): return .session
            case ...(8 * 24 * 3600): return .weekly
            default: return .other
            }
        }
    }

    public var id: String
    public var title: String
    public var group: Group
    public var percent: Double
    public var severity: Severity
    public var resetsAt: Date?

    public init(
        id: String,
        title: String,
        group: Group,
        percent: Double,
        severity: Severity,
        resetsAt: Date?
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
    }
}

extension LimitGauge {
    /// `monthly_experimental` → `Monthly experimental`: sólo la inicial en mayúscula, como en español.
    static func humanize(_ kind: String) -> String {
        let spaced = kind.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    /// El orden en que se dibujan: la sesión primero, porque es la que frena el trabajo hoy.
    static func groupOrder(_ group: Group) -> Int {
        switch group {
        case .session: return 0
        case .weekly: return 1
        case .other: return 2
        }
    }
}
