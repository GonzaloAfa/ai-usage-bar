import Foundation
import Testing

@testable import UsageCore

private func fixture(_ name: String) throws -> UsageResponse {
    let url = try #require(
        Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json"),
        "falta el fixture \(name).json"
    )
    return try UsageResponse.decode(try Data(contentsOf: url))
}

@Suite("Decodificación de /api/oauth/usage")
struct UsageResponseTests {
    @Test("La respuesta real se traduce a los tres límites que muestra la pantalla de Uso")
    func realResponse() throws {
        let response = try fixture("usage-real")
        let gauges = response.gauges

        #expect(gauges.count == 3)
        #expect(gauges.map(\.title) == ["Sesión actual", "Todos los modelos", "Fable"])
        #expect(gauges.map(\.percent) == [39, 76, 59])
        #expect(gauges.map(\.group) == [.session, .weekly, .weekly])

        // El nombre del modelo acotado sale de scope.model.display_name.
        #expect(gauges[2].title == "Fable")
    }

    @Test("El límite crítico es el más consumido, no el primero ni el activo")
    func criticalIsTheHighest() throws {
        let response = try fixture("usage-real")
        let critical = try #require(response.criticalGauge)

        #expect(critical.percent == 76)
        #expect(critical.title == "Todos los modelos")
        #expect(critical.severity == .warning)
    }

    @Test("Un 95 % es crítico aunque la API lo reporte como normal")
    func ownThresholdsWinWhenStricter() throws {
        let response = try fixture("usage-critical")
        let gauges = response.gauges

        let session = try #require(gauges.first { $0.group == .session })
        #expect(session.percent == 95)
        #expect(session.severity == .critical)

        // 71 % supera nuestro umbral de aviso aunque la API diga "normal".
        let weekly = try #require(gauges.first { $0.title == "Todos los modelos" })
        #expect(weekly.severity == .warning)
    }

    @Test("Campos y valores desconocidos no rompen la decodificación")
    func unknownFieldsAreIgnored() throws {
        let response = try fixture("usage-critical")

        // `severity: "una_gravedad_nueva"` cae en el umbral derivado del porcentaje.
        let experimental = try #require(response.gauges.first { $0.percent == 5 })
        #expect(experimental.severity == .normal)
        #expect(experimental.group == .other)
        // Un `kind` que no conocemos se muestra legible en vez de descartarse.
        #expect(experimental.title == "Monthly experimental")
    }

    @Test("Con limits vacío se recurre a five_hour y seven_day")
    func fallsBackToWindows() throws {
        let response = try fixture("usage-legacy")
        let gauges = response.gauges

        #expect(gauges.count == 2)
        #expect(gauges.map(\.title) == ["Sesión actual", "Todos los modelos"])
        #expect(gauges.map(\.percent) == [12.5, 44])
        #expect(response.criticalGauge?.percent == 44)
    }

    @Test("Los límites sin porcentaje se descartan en vez de dibujarse en cero")
    func gaugesWithoutPercentAreDropped() {
        let response = UsageResponse(
            limits: [
                .init(kind: "session", group: "session", percent: nil, severity: "normal"),
                .init(kind: "weekly_all", group: "weekly", percent: 10, severity: "normal"),
            ]
        )
        #expect(response.gauges.map(\.percent) == [10])
    }

    @Test("El monto de gasto pasa de unidades menores a mayores")
    func spendMoneyConversion() throws {
        let response = try fixture("usage-critical")
        #expect(response.spend?.used?.amount == 12.34)
        #expect(response.spend?.enabled == true)
    }
}

@Suite("Fechas ISO-8601 del endpoint")
struct ISO8601ParserTests {
    @Test(
        "Se aceptan las variantes de fracción que devuelve el servidor",
        arguments: [
            "2026-07-25T00:59:59.492655+00:00",  // 6 dígitos, la forma real
            "2026-07-25T00:59:59.1+00:00",       // 1 dígito
            "2026-07-25T00:59:59+00:00",         // sin fracción
            "2026-07-25T00:59:59.492655Z",       // Z en vez de offset
        ]
    )
    func parsesFractionalVariants(raw: String) throws {
        let date = try #require(ISO8601Parser.date(from: raw))
        // Todas apuntan al mismo segundo.
        #expect(abs(date.timeIntervalSince1970 - 1784941199) < 1)
    }

    @Test("Una fecha ilegible se reporta como error de decodificación, no se inventa")
    func rejectsGarbage() {
        #expect(ISO8601Parser.date(from: "ayer por la tarde") == nil)
        #expect(throws: DecodingError.self) {
            try UsageResponse.decode(Data(#"{"five_hour":{"resets_at":"mañana"}}"#.utf8))
        }
    }
}
