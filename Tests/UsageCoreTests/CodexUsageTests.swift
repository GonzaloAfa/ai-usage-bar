import Foundation
import Testing

@testable import UsageCore

@Suite("Decodificación de /backend-api/wham/usage")
struct CodexUsageResponseTests {
    private func fixture(_ name: String) throws -> CodexUsageResponse {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"))
        return try CodexUsageResponse.decode(try Data(contentsOf: url))
    }

    @Test("La respuesta real se traduce a la sesión de 5 h y al límite semanal")
    func realResponseBecomesTwoGauges() throws {
        let gauges = try fixture("codex-usage").gauges

        #expect(gauges.count == 2)
        #expect(gauges[0].group == .session)
        #expect(gauges[0].title == "Sesión actual")
        #expect(gauges[0].percent == 32)
        #expect(gauges[1].group == .weekly)
        #expect(gauges[1].title == "Semanal")
        #expect(gauges[1].percent == 25)
    }

    @Test("Las ventanas se clasifican por su duración, no por llamarse primary o secondary")
    func windowsAreClassifiedByDuration() throws {
        // Misma respuesta con los papeles invertidos: la semana llega primero.
        let json = """
            {"rate_limit":{
              "primary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_at":2000000000},
              "secondary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":2000000000}}}
            """
        let gauges = try CodexUsageResponse.decode(Data(json.utf8)).gauges

        // La sesión se dibuja primero aunque haya llegado segunda.
        #expect(gauges.first?.group == .session)
        #expect(gauges.first?.percent == 10)
        #expect(gauges.last?.group == .weekly)
        #expect(gauges.last?.percent == 40)
    }

    @Test("Una ventana sin duración conocida no se hace pasar por la sesión")
    func unknownWindowIsNotTheSession() throws {
        let json = #"{"rate_limit":{"primary_window":{"used_percent":50}}}"#
        let gauge = try #require(try CodexUsageResponse.decode(Data(json.utf8)).gauges.first)

        #expect(gauge.group == .other)
        #expect(gauge.title == "Otro límite")
    }

    @Test("Estar bloqueado es crítico, y el plan viaja en el snapshot")
    func limitReachedIsCritical() throws {
        let snapshot = try fixture("codex-limit-reached").snapshot

        #expect(snapshot.planName == "plus")
        #expect(snapshot.criticalGauge?.percent == 100)
        #expect(snapshot.criticalGauge?.severity == .critical)
        // El semanal sigue holgado: el bloqueo no debe teñir todas las filas.
        #expect(snapshot.gauges.last?.severity == .normal)
    }

    @Test("Los campos nulos no producen límites fantasma ni rompen la decodificación")
    func nullFieldsProduceNothing() throws {
        let response = try fixture("codex-minimal")

        #expect(response.gauges.count == 1)
        #expect(response.gauges[0].percent == 7)
        #expect(response.snapshot.spend == nil)
        #expect(response.snapshot.planName == nil)
    }

    @Test("Un campo que cambia de forma se pierde solo, sin llevarse el resto")
    func malformedFieldDoesNotSinkTheResponse() throws {
        // `additional_rate_limits` pasa de lista a objeto: el consumo principal debe seguir saliendo.
        let json = """
            {"rate_limit":{"primary_window":{"used_percent":21,"limit_window_seconds":18000}},
             "additional_rate_limits":{"ya":"no es una lista"},
             "credits":"tampoco es un objeto"}
            """
        let response = try CodexUsageResponse.decode(Data(json.utf8))

        #expect(response.gauges.count == 1)
        #expect(response.gauges[0].percent == 21)
        #expect(response.additionalRateLimits == nil)
        #expect(response.credits == nil)
    }

    @Test("Los créditos sólo se muestran cuando hay algo que decir")
    func creditsOnlyWhenRelevant() throws {
        #expect(try fixture("codex-usage").snapshot.spend == nil, "con saldo cero la sección sobra")

        let spend = try #require(try fixture("codex-limit-reached").snapshot.spend)
        #expect(spend.title == "Créditos")
        #expect(spend.amount == 12.5)
        #expect(spend.currency == "USD")
    }

    @Test("El tope de gasto alcanzado se avisa como crítico")
    func spendControlReached() throws {
        let json = """
            {"rate_limit":{"primary_window":{"used_percent":5,"limit_window_seconds":18000}},
             "credits":{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0"},
             "spend_control":{"reached":true,"individual_limit":50}}
            """
        let spend = try #require(try CodexUsageResponse.decode(Data(json.utf8)).snapshot.spend)

        #expect(spend.severity == .critical)
        #expect(spend.detail == "Tope de gasto alcanzado")
    }

    @Test("Sin reset_at absoluto se usa el plazo relativo")
    func relativeResetIsEnough() throws {
        let json = """
            {"rate_limit":{"primary_window":
              {"used_percent":60,"limit_window_seconds":18000,"reset_after_seconds":600}}}
            """
        let gauge = try #require(try CodexUsageResponse.decode(Data(json.utf8)).gauges.first)
        let resetsAt = try #require(gauge.resetsAt)

        #expect(abs(resetsAt.timeIntervalSinceNow - 600) < 5)
    }
}

@Suite("Sesión de Codex en ~/.codex/auth.json")
struct CodexAuthFileTokenSourceTests {
    /// Un JWT sin firmar con la expiración que se le indique: sólo se lee el payload.
    private func token(expiring at: Date?) -> String {
        let claims = at.map { #"{"exp":\#(Int($0.timeIntervalSince1970))}"# } ?? "{}"
        let payload = Data(claims.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "encabezado.\(payload).firma"
    }

    @Test("Se leen el token y la cuenta, y la expiración sale del propio JWT")
    func parsesTokenAndAccount() throws {
        let expiry = Date().addingTimeInterval(10 * 24 * 3600)
        let json = """
            {"auth_mode":"chatgpt","OPENAI_API_KEY":null,
             "tokens":{"access_token":"\(token(expiring: expiry))","account_id":"cuenta-1",
                       "refresh_token":"no-se-usa"}}
            """
        let credentials = try CodexAuthFileTokenSource.parse(payload: Data(json.utf8))

        #expect(credentials.accountId == "cuenta-1")
        #expect(!credentials.isExpired())
        let expiresAt = try #require(credentials.expiresAt)
        #expect(abs(expiresAt.timeIntervalSince(expiry)) < 1)
    }

    @Test("Un token ya vencido se detecta antes de gastar una llamada")
    func expiredTokenIsDetected() throws {
        let json = """
            {"auth_mode":"chatgpt",
             "tokens":{"access_token":"\(token(expiring: Date().addingTimeInterval(-60)))"}}
            """
        #expect(try CodexAuthFileTokenSource.parse(payload: Data(json.utf8)).isExpired())
    }

    @Test("Un token que no es JWT no impide consultar: se deja hablar al servidor")
    func opaqueTokenHasNoExpiry() throws {
        let json = #"{"auth_mode":"chatgpt","tokens":{"access_token":"opaco"}}"#
        let credentials = try CodexAuthFileTokenSource.parse(payload: Data(json.utf8))

        #expect(credentials.expiresAt == nil)
        #expect(!credentials.isExpired())
    }

    @Test("Con clave de API no hay plan que consultar")
    func apiKeyModeIsRejected() {
        let json = #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-proj-no-debe-salir","tokens":null}"#
        #expect(throws: TokenError.unsupportedAuthMode) {
            try CodexAuthFileTokenSource.parse(payload: Data(json.utf8))
        }
    }

    @Test("Un archivo sin tokens se reporta como formato inesperado, sin citar su contenido")
    func malformedFileIsReportedSafely() {
        let json = #"{"auth_mode":"chatgpt","tokens":{}}"#
        #expect(throws: TokenError.malformed) {
            try CodexAuthFileTokenSource.parse(payload: Data(json.utf8))
        }
        #expect(TokenError.malformed.errorDescription?.contains("chatgpt") == false)
    }

    @Test("Sin archivo no hay sesión, y sin sesión el proveedor no ocupa la barra")
    func missingFileMeansNoSession() {
        let source = CodexAuthFileTokenSource(
            url: URL(fileURLWithPath: "/no/existe/auth.json")
        )
        #expect(!source.hasSession())
        #expect(throws: TokenError.notFound) { try source.currentCredentials() }
    }
}

@MainActor
@Suite("Dos proveedores a la vez")
struct MultiProviderTests {
    private struct SnapshotClient: UsageFetching {
        let snapshot: ProviderSnapshot
        func fetch() async throws -> ProviderSnapshot { snapshot }
    }

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "cl.alisonvivanco.ai-usage-bar.tests.\(UUID().uuidString)")!
    }

    private func snapshot(percent: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            gauges: [
                LimitGauge(
                    id: "session",
                    title: "Sesión actual",
                    group: .session,
                    percent: percent,
                    severity: .derived(fromPercent: percent),
                    resetsAt: nil
                )
            ]
        )
    }

    @Test("Cada proveedor guarda su caché aparte y no pisa la del otro")
    func cachesAreNamespaced() async {
        let defaults = makeDefaults()

        let claude = UsageStore(
            provider: .claude,
            client: SnapshotClient(snapshot: snapshot(percent: 11)),
            defaults: defaults
        )
        let codex = UsageStore(
            provider: .codex,
            client: SnapshotClient(snapshot: snapshot(percent: 97)),
            defaults: defaults
        )
        await claude.refreshAndWait()
        await codex.refreshAndWait()

        // Stores nuevos sobre las mismas preferencias: cada uno debe recuperar lo suyo.
        let claudeAgain = UsageStore(
            provider: .claude,
            client: SnapshotClient(snapshot: snapshot(percent: 0)),
            defaults: defaults
        )
        let codexAgain = UsageStore(
            provider: .codex,
            client: SnapshotClient(snapshot: snapshot(percent: 0)),
            defaults: defaults
        )

        #expect(claudeAgain.gauges.first?.percent == 11)
        #expect(codexAgain.gauges.first?.percent == 97)
    }

    @Test("El tooltip y los textos dicen de qué proveedor se trata")
    func textsNameTheProvider() async {
        let codex = UsageStore(
            provider: .codex,
            client: SnapshotClient(snapshot: snapshot(percent: 97)),
            defaults: makeDefaults()
        )
        await codex.refreshAndWait()

        #expect(codex.tooltip.contains("Codex"))
        #expect(!codex.tooltip.contains("Claude"))
        #expect(
            StatusItemRenderer
                .accessibilityDescription(for: .level(percent: 97, severity: .critical), provider: .codex)
                .contains("Codex")
        )
    }

    @Test("Cada proveedor tiene su propio símbolo en la barra")
    func eachProviderHasItsOwnSymbol() {
        #expect(Provider.claude.symbolName != Provider.codex.symbolName)
        let state = StatusItemState.level(percent: 50, severity: .normal)
        #expect(StatusItemRenderer.image(for: state, provider: .codex).size.width > 0)
    }

    @Test("Una variable de fixture basta para que el proveedor aparezca sin credenciales reales")
    func fixtureEnvironmentEnablesProvider() {
        let environment = ["AI_USAGE_BAR_FIXTURE_CODEX": "/tmp/codex.json"]

        #expect(Provider.codex.hasSession(environment: environment))
        #expect(Provider.available(environment: environment).contains(.codex))
    }
}
