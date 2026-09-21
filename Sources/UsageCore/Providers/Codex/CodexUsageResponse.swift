import Foundation

/// Respuesta de `GET /backend-api/wham/usage`, el endpoint que alimenta `/status` en Codex.
///
/// Es interno y sin contrato público, así que todo es opcional y todo se decodifica a la defensiva:
/// un campo que cambie de forma deja su valor en `nil` en vez de tumbar la respuesta entera. La
/// regla es la misma que con Anthropic: una respuesta con campos nuevos nunca debe hacer fallar la
/// decodificación.
public struct CodexUsageResponse: Sendable, Equatable {
    /// Una ventana de consumo. `limit_window_seconds` es lo que la identifica: 18 000 son las cinco
    /// horas de la sesión, 604 800 la semana.
    public struct Window: Decodable, Sendable, Equatable {
        public var usedPercent: Double?
        public var limitWindowSeconds: Double?
        public var resetAfterSeconds: Double?
        public var resetAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercent = "used_percent"
            case limitWindowSeconds = "limit_window_seconds"
            case resetAfterSeconds = "reset_after_seconds"
            case resetAt = "reset_at"
        }

        public var resetsAtDate: Date? {
            if let resetAt { return Date(timeIntervalSince1970: resetAt) }
            if let resetAfterSeconds { return Date().addingTimeInterval(resetAfterSeconds) }
            return nil
        }
    }

    public struct RateLimit: Decodable, Sendable, Equatable {
        public var allowed: Bool?
        public var limitReached: Bool?
        public var limitName: String?
        public var primaryWindow: Window?
        public var secondaryWindow: Window?

        enum CodingKeys: String, CodingKey {
            case allowed
            case limitReached = "limit_reached"
            case limitName = "limit_name"
            case primaryWindow = "primary_window"
            case secondaryWindow = "secondary_window"
        }
    }

    public struct Credits: Decodable, Sendable, Equatable {
        public var hasCredits: Bool?
        public var unlimited: Bool?
        public var overageLimitReached: Bool?
        /// Llega como texto («"0"», «"12.50"»), no como número.
        public var balance: String?

        enum CodingKeys: String, CodingKey {
            case hasCredits = "has_credits"
            case unlimited
            case overageLimitReached = "overage_limit_reached"
            case balance
        }

        public var balanceAmount: Double? { balance.flatMap(Double.init) }
    }

    public struct SpendControl: Decodable, Sendable, Equatable {
        public var reached: Bool?
        public var individualLimit: Double?

        enum CodingKeys: String, CodingKey {
            case reached
            case individualLimit = "individual_limit"
        }
    }

    public var planType: String?
    public var rateLimit: RateLimit?
    public var codeReviewRateLimit: RateLimit?
    public var additionalRateLimits: [RateLimit]?
    public var credits: Credits?
    public var spendControl: SpendControl?

    public init(
        planType: String? = nil,
        rateLimit: RateLimit? = nil,
        codeReviewRateLimit: RateLimit? = nil,
        additionalRateLimits: [RateLimit]? = nil,
        credits: Credits? = nil,
        spendControl: SpendControl? = nil
    ) {
        self.planType = planType
        self.rateLimit = rateLimit
        self.codeReviewRateLimit = codeReviewRateLimit
        self.additionalRateLimits = additionalRateLimits
        self.credits = credits
        self.spendControl = spendControl
    }
}

// MARK: - Decodificación

extension CodexUsageResponse: Decodable {
    enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
        case codeReviewRateLimit = "code_review_rate_limit"
        case additionalRateLimits = "additional_rate_limits"
        case credits
        case spendControl = "spend_control"
    }

    /// Cada campo se intenta por separado: si `additional_rate_limits` dejara de ser una lista, o
    /// `credits` cambiara de forma, se pierde ese dato y el resto se sigue mostrando.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        planType = try? container.decodeIfPresent(String.self, forKey: .planType)
        rateLimit = try? container.decodeIfPresent(RateLimit.self, forKey: .rateLimit)
        codeReviewRateLimit = try? container.decodeIfPresent(RateLimit.self, forKey: .codeReviewRateLimit)
        additionalRateLimits = try? container.decodeIfPresent([RateLimit].self, forKey: .additionalRateLimits)
        credits = try? container.decodeIfPresent(Credits.self, forKey: .credits)
        spendControl = try? container.decodeIfPresent(SpendControl.self, forKey: .spendControl)
    }

    public static func decode(_ data: Data) throws -> CodexUsageResponse {
        try JSONDecoder().decode(CodexUsageResponse.self, from: data)
    }
}

// MARK: - Normalización

extension CodexUsageResponse {
    public var snapshot: ProviderSnapshot {
        ProviderSnapshot(gauges: gauges, planName: planType, spend: spendSummary)
    }

    /// Los límites listos para la interfaz.
    ///
    /// Las ventanas se clasifican por su duración y no por el nombre `primary`/`secondary`: ese
    /// nombre describe el orden en que la API las manda, no lo que miden.
    public var gauges: [LimitGauge] {
        var result: [LimitGauge] = []
        let reached = rateLimit?.limitReached == true

        if let window = rateLimit?.primaryWindow {
            result.append(contentsOf: gauge(from: window, id: "primary", limitReached: reached))
        }
        if let window = rateLimit?.secondaryWindow {
            result.append(contentsOf: gauge(from: window, id: "secondary", limitReached: reached))
        }

        if let review = codeReviewRateLimit {
            for (index, window) in [review.primaryWindow, review.secondaryWindow].enumerated() {
                guard let window else { continue }
                result.append(
                    contentsOf: gauge(
                        from: window,
                        id: "code_review.\(index)",
                        title: "Revisión de código",
                        group: .other,
                        limitReached: review.limitReached == true
                    )
                )
            }
        }

        for (index, extra) in (additionalRateLimits ?? []).enumerated() {
            for (position, window) in [extra.primaryWindow, extra.secondaryWindow].enumerated() {
                guard let window else { continue }
                // Un límite nuevo se muestra con el nombre que traiga en vez de descartarse.
                let title = extra.limitName.map(LimitGauge.humanize) ?? "Otro límite"
                result.append(
                    contentsOf: gauge(
                        from: window,
                        id: "additional.\(index).\(position)",
                        title: title,
                        group: .other,
                        limitReached: extra.limitReached == true
                    )
                )
            }
        }

        return result.sorted { LimitGauge.groupOrder($0.group) < LimitGauge.groupOrder($1.group) }
    }

    private func gauge(
        from window: Window,
        id: String,
        title: String? = nil,
        group: LimitGauge.Group? = nil,
        limitReached: Bool
    ) -> [LimitGauge] {
        guard let percent = window.usedPercent else { return [] }
        let resolvedGroup = group
            ?? LimitGauge.Group.forWindow(seconds: window.limitWindowSeconds ?? -1)

        let resolvedTitle: String
        switch (title, resolvedGroup) {
        case (let given?, _): resolvedTitle = given
        case (nil, .session): resolvedTitle = "Sesión actual"
        case (nil, .weekly): resolvedTitle = "Semanal"
        case (nil, .other): resolvedTitle = "Otro límite"
        }

        // El aviso de la API manda sobre el porcentaje: al estar bloqueado, un 98 % es crítico igual.
        let severity: Severity = limitReached && percent >= 99
            ? .critical
            : .derived(fromPercent: percent)

        return [
            LimitGauge(
                id: id,
                title: resolvedTitle,
                group: resolvedGroup,
                percent: percent,
                severity: severity,
                resetsAt: window.resetsAtDate
            )
        ]
    }

    /// Los créditos, que es lo que se consume cuando el plan ya se agotó.
    ///
    /// Sólo aparece si hay algo que decir: con saldo cero y sin tope alcanzado, la sección sobra.
    private var spendSummary: SpendSummary? {
        let balance = credits?.balanceAmount
        let unlimited = credits?.unlimited == true
        let spendReached = spendControl?.reached == true
        let overage = credits?.overageLimitReached == true

        guard unlimited || spendReached || overage || (balance ?? 0) > 0 else { return nil }

        let detail: String?
        switch (unlimited, spendReached || overage) {
        case (true, _): detail = "Créditos ilimitados"
        case (_, true): detail = "Tope de gasto alcanzado"
        default: detail = nil
        }

        return SpendSummary(
            title: "Créditos",
            amount: unlimited ? nil : balance,
            currency: "USD",
            percent: nil,
            severity: (spendReached || overage) ? .critical : nil,
            detail: detail
        )
    }
}
