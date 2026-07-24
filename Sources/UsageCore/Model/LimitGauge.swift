import Foundation

/// Gravedad de un límite. La API ya manda un `severity`, pero lo cruzamos con el porcentaje para no
/// depender de que su umbral coincida con lo que queremos mostrar.
public enum Severity: String, Sendable, Comparable, CaseIterable {
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
    static func fromAPI(_ raw: String?) -> Severity? {
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
public struct LimitGauge: Identifiable, Sendable, Equatable {
    public enum Group: Sendable, Equatable {
        case session
        case weekly
        case other
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

// MARK: - Normalización desde la API

extension UsageResponse {
    /// Los límites listos para la interfaz: sesión primero, luego los semanales en el orden en que
    /// llegaron.
    ///
    /// Se construye sobre `limits[]` porque ya viene agrupado y con el nombre del modelo acotado
    /// (de ahí sale la fila «Fable»). `five_hour`/`seven_day` quedan sólo como respaldo por si esa
    /// lista llega vacía en alguna versión del endpoint.
    public var gauges: [LimitGauge] {
        let fromLimits = (limits ?? []).compactMap(Self.gauge(from:))
        let result = fromLimits.isEmpty ? fallbackGauges : fromLimits
        return result.sorted { lhs, rhs in
            Self.groupOrder(lhs.group) < Self.groupOrder(rhs.group)
        }
    }

    /// El límite que manda: el de mayor consumo, sin importar de qué ventana venga. Es el que gobierna
    /// el ícono de la barra de menú, porque es el que va a frenar el trabajo primero.
    public var criticalGauge: LimitGauge? {
        gauges.max { $0.percent < $1.percent }
    }

    private static func groupOrder(_ group: LimitGauge.Group) -> Int {
        switch group {
        case .session: return 0
        case .weekly: return 1
        case .other: return 2
        }
    }

    /// `monthly_experimental` → `Monthly experimental`: sólo la inicial en mayúscula, como en español.
    private static func humanize(_ kind: String) -> String {
        let spaced = kind.replacingOccurrences(of: "_", with: " ")
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    private static func gauge(from limit: Limit) -> LimitGauge? {
        guard let percent = limit.percent else { return nil }
        let scopedName = limit.scope?.model?.displayName

        let title: String
        switch limit.kind {
        case "session": title = "Sesión actual"
        case "weekly_all": title = "Todos los modelos"
        case "weekly_scoped": title = scopedName ?? "Modelo específico"
        default:
            // Un `kind` nuevo se muestra legible en vez de descartarse: preferimos enseñar un límite
            // con nombre feo antes que ocultarle al usuario que existe.
            title = scopedName ?? limit.kind.map(Self.humanize) ?? "Límite"
        }

        let group: LimitGauge.Group
        switch limit.group ?? limit.kind {
        case "session": group = .session
        case "weekly", "weekly_all", "weekly_scoped": group = .weekly
        default: group = .other
        }

        return LimitGauge(
            id: [limit.kind, limit.group, scopedName].compactMap { $0 }.joined(separator: "."),
            title: title,
            group: group,
            percent: percent,
            severity: max(Severity.fromAPI(limit.severity) ?? .normal, .derived(fromPercent: percent)),
            resetsAt: limit.resetsAt
        )
    }

    private var fallbackGauges: [LimitGauge] {
        var gauges: [LimitGauge] = []
        if let fiveHour, let percent = fiveHour.utilization {
            gauges.append(
                LimitGauge(
                    id: "five_hour",
                    title: "Sesión actual",
                    group: .session,
                    percent: percent,
                    severity: .derived(fromPercent: percent),
                    resetsAt: fiveHour.resetsAt
                )
            )
        }
        if let sevenDay, let percent = sevenDay.utilization {
            gauges.append(
                LimitGauge(
                    id: "seven_day",
                    title: "Todos los modelos",
                    group: .weekly,
                    percent: percent,
                    severity: .derived(fromPercent: percent),
                    resetsAt: sevenDay.resetsAt
                )
            )
        }
        return gauges
    }
}
