import Foundation
import UsageCore

/// Consulta el uso de cada proveedor una vez y lo escribe en la salida estándar.
///
/// Sirve para comprobar sin interfaz que la lectura de credenciales y los endpoints funcionan, y
/// para comparar las cifras con lo que muestran `/usage` en Claude Code y `/status` en Codex. Se
/// activa con `AI_USAGE_BAR_PRINT=1`.
@MainActor
func printUsageSummary() async -> Int32 {
    let providers = Provider.available()

    guard !providers.isEmpty else {
        print("No hay ninguna sesión iniciada: ni Claude Code ni Codex.")
        return 1
    }

    var failures = 0
    for provider in providers {
        print("— \(provider.displayName) —")
        if await !printUsage(of: provider) { failures += 1 }
        print("")
    }
    return failures == 0 ? 0 : 1
}

@MainActor
private func printUsage(of provider: Provider) async -> Bool {
    do {
        let snapshot = try await provider.makeUsageClient().fetch()

        guard !snapshot.gauges.isEmpty else {
            print("La respuesta no trae ningún límite.")
            return false
        }

        if let plan = snapshot.planName { print("Plan: \(plan)") }

        for gauge in snapshot.gauges {
            let reset = gauge.resetsAt.map { " — \(UsageFormat.resetPhrase(for: $0).lowercased())" } ?? ""
            let mark = gauge.severity == .normal ? " " : (gauge.severity == .warning ? "!" : "!!")
            print("\(mark) \(gauge.title): \(UsageFormat.percentUsed(gauge.percent))\(reset)")
        }

        if let spend = snapshot.spend {
            let amount = spend.amount.map { UsageFormat.money($0, currency: spend.currency) }
            print("  \(spend.title): \(amount ?? spend.detail ?? "—")")
        }

        if let critical = snapshot.criticalGauge {
            print("  Manda: \(critical.title) con \(UsageFormat.percent(critical.percent)).")
        }
        return true
    } catch {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        print("Error: \(message)")
        return false
    }
}
