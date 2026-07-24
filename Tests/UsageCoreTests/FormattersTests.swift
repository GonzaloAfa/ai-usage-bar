import Foundation
import Testing

@testable import UsageCore

@Suite("Textos de la interfaz")
struct FormattersTests {
    private let now = Date(timeIntervalSince1970: 1_784_929_400)  // 2026-07-24 21:03:20 UTC

    @Test("Un reinicio dentro del día se expresa como plazo")
    func nearResetIsRelative() {
        let phrase = UsageFormat.resetPhrase(for: now.addingTimeInterval(3 * 3600 + 17 * 60), now: now)
        #expect(phrase == "Se restablece en 3 h 17 min")
    }

    @Test("Los plazos se escriben como en la pantalla de Uso, sin conjunción")
    func durationWording() {
        #expect(UsageFormat.duration(3 * 3600 + 17 * 60) == "3 h 17 min")
        #expect(UsageFormat.duration(48 * 60) == "48 min")
        #expect(UsageFormat.duration(2 * 3600) == "2 h")
        // Menos de un minuto no se muestra como «0 min».
        #expect(UsageFormat.duration(20) == "1 min")
    }

    @Test("Un reinicio a más de un día se expresa con día y hora")
    func farResetShowsWeekday() {
        // 2026-07-26 09:59:59 UTC = domingo 05:59 en Santiago.
        let resetsAt = Date(timeIntervalSince1970: 1_785_059_999)
        let phrase = UsageFormat.resetPhrase(
            for: resetsAt,
            now: now,
            timeZone: TimeZone(identifier: "America/Santiago")!
        )

        #expect(phrase.hasPrefix("Se restablece "))
        #expect(phrase.lowercased().contains("dom"))
        #expect(phrase.contains("5:59"))
    }

    @Test("Un límite ya vencido no muestra un plazo negativo")
    func pastResetDoesNotGoNegative() {
        let phrase = UsageFormat.resetPhrase(for: now.addingTimeInterval(-60), now: now)
        #expect(!phrase.contains("-"))
        #expect(phrase == "Se restablece en cualquier momento")
    }

    @Test("Los porcentajes vienen en escala 0–100 y se muestran sin decimales")
    func percentScale() {
        #expect(UsageFormat.percent(39).contains("39"))
        #expect(!UsageFormat.percent(39).contains("3900"))
        #expect(UsageFormat.percent(24.68).contains("25"))
        #expect(UsageFormat.percentUsed(76).hasSuffix("usado"))
    }

    @Test("La antigüedad de los datos se redondea a la unidad legible")
    func lastUpdatedWording() {
        #expect(UsageFormat.lastUpdated(now, now: now) == "Actualizado justo ahora")
        #expect(UsageFormat.lastUpdated(now.addingTimeInterval(-30), now: now) == "Actualizado hace 30 s")
        #expect(UsageFormat.lastUpdated(now.addingTimeInterval(-180), now: now) == "Actualizado hace 3 min")
        #expect(UsageFormat.lastUpdated(now.addingTimeInterval(-7200), now: now) == "Actualizado hace 2 h")
    }
}

@Suite("Lectura de credenciales")
struct TokenSourceTests {
    @Test("Del llavero sólo se toma la sesión de Claude, no los tokens de servidores MCP")
    func parsesOnlyClaudeSession() throws {
        let payload = Data(
            """
            {
              "mcpOAuth": { "algun-servidor": { "accessToken": "no-tocar" } },
              "claudeAiOauth": {
                "accessToken": "sk-ant-oat01-ejemplo",
                "refreshToken": "sk-ant-ort01-ejemplo",
                "expiresAt": 1784932202267,
                "subscriptionType": "team"
              }
            }
            """.utf8
        )

        let credentials = try KeychainTokenSource.parse(payload: payload)
        #expect(credentials.accessToken == "sk-ant-oat01-ejemplo")
        // expiresAt viene en milisegundos.
        #expect(credentials.expiresAt == Date(timeIntervalSince1970: 1_784_932_202.267))
        #expect(credentials.isExpired(now: Date(timeIntervalSince1970: 1_784_000_000)) == false)
        #expect(credentials.isExpired(now: Date(timeIntervalSince1970: 1_785_000_000)) == true)
    }

    @Test("Sin sesión de Claude en el llavero el error es explícito")
    func rejectsPayloadWithoutSession() {
        #expect(throws: TokenError.malformed) {
            try KeychainTokenSource.parse(payload: Data(#"{"mcpOAuth":{}}"#.utf8))
        }
        #expect(throws: TokenError.malformed) {
            try KeychainTokenSource.parse(payload: Data(#"{"claudeAiOauth":{"accessToken":""}}"#.utf8))
        }
    }

    @Test("Un token sin vencimiento conocido no se asume vencido")
    func missingExpiryIsNotExpired() throws {
        let credentials = try KeychainTokenSource.parse(
            payload: Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-x"}}"#.utf8)
        )
        #expect(credentials.expiresAt == nil)
        #expect(credentials.isExpired() == false)
    }
}
