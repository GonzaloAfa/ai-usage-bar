import Foundation

// MARK: - Normalización desde la API de Anthropic

extension UsageResponse {
    /// La respuesta traducida a la forma que consume la interfaz.
    public var snapshot: ProviderSnapshot {
        ProviderSnapshot(gauges: gauges, planName: nil, spend: spendSummary)
    }

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
            LimitGauge.groupOrder(lhs.group) < LimitGauge.groupOrder(rhs.group)
        }
    }

    /// El límite que manda: el de mayor consumo, sin importar de qué ventana venga. Es el que gobierna
    /// el ícono de la barra de menú, porque es el que va a frenar el trabajo primero.
    public var criticalGauge: LimitGauge? {
        gauges.max { $0.percent < $1.percent }
    }

    /// El uso extra, cuando la cuenta lo tiene habilitado.
    private var spendSummary: SpendSummary? {
        guard let spend, spend.enabled == true else { return nil }
        return SpendSummary(
            title: "Uso extra",
            amount: spend.used?.amount,
            currency: spend.used?.currency,
            percent: spend.percent,
            severity: spend.percent.map {
                max(Severity.fromAPI(spend.severity) ?? .normal, .derived(fromPercent: $0))
            }
        )
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
            title = scopedName ?? limit.kind.map(LimitGauge.humanize) ?? "Límite"
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
