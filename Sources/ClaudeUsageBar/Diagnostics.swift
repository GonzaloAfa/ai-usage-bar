import Foundation
import UsageCore

/// Consulta el uso una vez y lo escribe en la salida estándar.
///
/// Sirve para comprobar sin interfaz que la lectura del llavero y el endpoint funcionan, y para
/// comparar las cifras con lo que muestra `/usage` en Claude Code. Se activa con
/// `CLAUDE_USAGE_BAR_PRINT=1`.
@MainActor
func printUsageSummary() async -> Int32 {
    let client = makeDefaultUsageClient()

    do {
        let response = try await client.fetch()
        let gauges = response.gauges

        guard !gauges.isEmpty else {
            print("La respuesta no trae ningún límite.")
            return 1
        }

        for gauge in gauges {
            let reset = gauge.resetsAt.map { " — \(UsageFormat.resetPhrase(for: $0).lowercased())" } ?? ""
            let mark = gauge.severity == .normal ? " " : (gauge.severity == .warning ? "!" : "!!")
            print("\(mark) \(gauge.title): \(UsageFormat.percentUsed(gauge.percent))\(reset)")
        }

        if let critical = response.criticalGauge {
            print("\nManda: \(critical.title) con \(UsageFormat.percent(critical.percent)).")
        }
        return 0
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        print("Error: \(message)")
        return 1
    }
}
