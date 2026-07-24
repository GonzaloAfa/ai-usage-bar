import Foundation

/// Respuesta de `GET /api/oauth/usage`.
///
/// El endpoint es interno y agrega campos sin avisar (`tangelo`, `nimbus_quill`, `seven_day_opus`…),
/// así que todo es opcional y las claves que no declaramos se ignoran en silencio. La regla es que
/// una respuesta con campos nuevos nunca debe hacer fallar la decodificación.
public struct UsageResponse: Codable, Sendable, Equatable {
    /// Una ventana de consumo con porcentaje y momento de reinicio (`five_hour`, `seven_day`).
    public struct Window: Codable, Sendable, Equatable {
        public var utilization: Double?
        public var resetsAt: Date?
    }

    /// A qué está acotado un límite. Sólo declaramos `model`: `surface` viene siempre `null` y no
    /// conocemos su tipo real, así que declararlo sería arriesgar un fallo de decodificación.
    public struct Scope: Codable, Sendable, Equatable {
        public struct Model: Codable, Sendable, Equatable {
            public var id: String?
            public var displayName: String?
        }

        public var model: Model?
    }

    /// Entrada de `limits[]`, la fuente principal de la interfaz.
    public struct Limit: Codable, Sendable, Equatable {
        public var kind: String?
        public var group: String?
        public var percent: Double?
        public var severity: String?
        public var resetsAt: Date?
        public var scope: Scope?
        public var isActive: Bool?
    }

    public struct ExtraUsage: Codable, Sendable, Equatable {
        public var isEnabled: Bool?
        public var utilization: Double?
        public var monthlyLimit: Double?
        public var usedCredits: Double?
        public var currency: String?
        public var decimalPlaces: Int?
    }

    public struct Spend: Codable, Sendable, Equatable {
        public struct Money: Codable, Sendable, Equatable {
            public var amountMinor: Double?
            public var currency: String?
            public var exponent: Int?

            /// El monto en unidades mayores: 1234 minor con exponente 2 → 12.34.
            public var amount: Double? {
                guard let amountMinor else { return nil }
                return amountMinor / pow(10, Double(exponent ?? 2))
            }
        }

        public var used: Money?
        public var limit: Money?
        public var percent: Double?
        public var severity: String?
        public var enabled: Bool?
    }

    public var fiveHour: Window?
    public var sevenDay: Window?
    public var limits: [Limit]?
    public var extraUsage: ExtraUsage?
    public var spend: Spend?

    public init(
        fiveHour: Window? = nil,
        sevenDay: Window? = nil,
        limits: [Limit]? = nil,
        extraUsage: ExtraUsage? = nil,
        spend: Spend? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
        self.extraUsage = extraUsage
        self.spend = spend
    }
}

// MARK: - Decodificación

extension UsageResponse {
    /// Decoder configurado para la forma real del endpoint: snake_case y fechas ISO-8601 con
    /// fracciones de segundo de precisión variable.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = ISO8601Parser.date(from: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Fecha ISO-8601 no reconocida: \(raw)"
                )
            }
            return date
        }
        return decoder
    }

    public static func decode(_ data: Data) throws -> UsageResponse {
        try decoder().decode(UsageResponse.self, from: data)
    }
}

/// Las fechas del endpoint traen 6 dígitos de fracción (`…:59.492655+00:00`), que no todos los
/// formateadores de Foundation aceptan. Probamos en cascada en vez de asumir un formato fijo.
///
/// Los formateadores se crean en cada llamada en vez de compartirse: los de Foundation no son
/// `Sendable`, y construirlos cuesta microsegundos frente a las seis fechas por respuesta que
/// procesamos una vez por minuto.
enum ISO8601Parser {
    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    static func date(from raw: String) -> Date? {
        let fractional = formatter(fractionalSeconds: true)
        let plain = formatter(fractionalSeconds: false)

        if let date = fractional.date(from: raw) { return date }
        if let date = plain.date(from: raw) { return date }

        // Recortar la fracción a 3 dígitos y reintentar; también cubre el caso sin fracción.
        if let dot = raw.firstIndex(of: ".") {
            let afterFraction = raw[dot...].firstIndex { !$0.isNumber && $0 != "." }
                ?? raw.endIndex
            let fraction = raw[raw.index(after: dot)..<afterFraction]
            let truncated = raw[raw.startIndex..<dot]
                + "." + fraction.prefix(3)
                + raw[afterFraction...]
            if let date = fractional.date(from: String(truncated)) { return date }
            let withoutFraction = raw[raw.startIndex..<dot] + raw[afterFraction...]
            if let date = plain.date(from: String(withoutFraction)) { return date }
        }
        return nil
    }
}
