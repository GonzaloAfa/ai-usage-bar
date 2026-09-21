import Foundation

/// El gasto por fuera del plan, con la forma que necesita el popover.
///
/// Cada proveedor lo llama distinto —Anthropic cobra «uso extra», OpenAI vende créditos— así que se
/// normaliza aquí: un título, un monto opcional, un porcentaje opcional y una línea de detalle.
public struct SpendSummary: Codable, Sendable, Equatable {
    public var title: String
    public var amount: Double?
    public var currency: String?
    public var percent: Double?
    public var severity: Severity?
    public var detail: String?

    public init(
        title: String,
        amount: Double? = nil,
        currency: String? = nil,
        percent: Double? = nil,
        severity: Severity? = nil,
        detail: String? = nil
    ) {
        self.title = title
        self.amount = amount
        self.currency = currency
        self.percent = percent
        self.severity = severity
        self.detail = detail
    }
}

/// Lo que devuelve un proveedor una vez traducido: límites listos para dibujar, sin rastro de la
/// forma de su API.
///
/// Es lo que se guarda en la caché, así que cambiar el esquema de un endpoint no invalida lo que
/// hay en disco: `UserDefaults` guarda esta forma nuestra, no la suya.
public struct ProviderSnapshot: Codable, Sendable, Equatable {
    public var gauges: [LimitGauge]

    /// El plan contratado, cuando la API lo dice: `plus`, `max`…
    public var planName: String?
    public var spend: SpendSummary?

    public init(gauges: [LimitGauge], planName: String? = nil, spend: SpendSummary? = nil) {
        self.gauges = gauges
        self.planName = planName
        self.spend = spend
    }

    /// El límite que manda: el de mayor consumo, sin importar de qué ventana venga. Es el que
    /// gobierna el ícono de la barra de menú, porque es el que va a frenar el trabajo primero.
    public var criticalGauge: LimitGauge? {
        gauges.max { $0.percent < $1.percent }
    }
}
