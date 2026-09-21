import AppKit
import SwiftUI

/// El desglose completo que se abre al hacer clic en el ícono.
public struct UsagePopoverView: View {
    @Bindable private var store: UsageStore
    private let onQuit: () -> Void

    /// Refresca el texto «Actualizado hace N s» y los plazos sin depender de que lleguen datos nuevos.
    @State private var now = Date()

    public init(store: UsageStore, onQuit: @escaping () -> Void) {
        self.store = store
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if case .needsReauth = store.state {
                notice(store.provider.reauthHint, tint: .orange)
            } else if case .failed(let message) = store.state, store.snapshot == nil {
                notice(message, tint: .red)
            }

            if let session = store.sessionGauge {
                GaugeRowView(gauge: session, now: now)
            }

            if !store.weeklyGauges.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Límites semanales")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    ForEach(store.weeklyGauges) { gauge in
                        GaugeRowView(gauge: gauge, now: now)
                    }
                }
            }

            extraUsageSection

            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .task {
            // Un tic por segundo mantiene vivos los plazos mientras el popover está abierto.
            while !Task.isCancelled {
                now = Date()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Secciones

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text("Uso de \(store.provider.displayName)")
                    .font(.system(size: 13, weight: .semibold))
                if let plan = store.snapshot?.planName {
                    Text(plan.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if let critical = store.criticalGauge {
                    Text(UsageFormat.percent(critical.percent))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(critical.severity.tint)
                        .monospacedDigit()
                }
            }
            if let critical = store.criticalGauge {
                Text(subtitle(for: critical))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else if store.snapshot == nil {
                Text("Consultando…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitle(for gauge: LimitGauge) -> String {
        guard let resetsAt = gauge.resetsAt else { return gauge.title }
        // La frase completa y no sólo el plazo: «se libera en dom, 5:59 a.m.» no se sostiene en español.
        let phrase = UsageFormat.resetPhrase(for: resetsAt, now: now)
        return "\(gauge.title) · \(phrase.prefix(1).lowercased())\(phrase.dropFirst())"
    }

    /// El gasto fuera del plan: «uso extra» en Claude, créditos en Codex.
    @ViewBuilder
    private var extraUsageSection: some View {
        if let spend = store.snapshot?.spend {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(spend.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let amount = spend.amount {
                        Text(UsageFormat.money(amount, currency: spend.currency))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let percent = spend.percent {
                    ProgressBar(
                        percent: percent,
                        tint: (spend.severity ?? .derived(fromPercent: percent)).tint
                    )
                }
                if let detail = spend.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle((spend.severity ?? .normal) == .critical ? .red : .secondary)
                }
            }
        }
    }

    /// Acciones como texto y no como SF Symbols: se leen sin adivinar y no dependen de que el
    /// símbolo exista en el contexto donde se dibuja la vista.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.isStale, case .failed(let message) = store.state {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if let lastUpdated = store.lastUpdated {
                    Text(UsageFormat.lastUpdated(lastUpdated, now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)

                footerButton("Actualizar") { store.refresh() }
                separator
                footerButton(store.provider.webUsageLabel) {
                    NSWorkspace.shared.open(store.provider.webUsageURL)
                }
                separator
                footerButton("Salir", action: onQuit)
            }
        }
    }

    private var separator: some View {
        Text("·")
            .font(.system(size: 10))
            .foregroundStyle(.quaternary)
    }

    private func footerButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
    }

    private func notice(_ message: String, tint: Color) -> some View {
        Text(.init(message))
            .font(.system(size: 11))
            .foregroundStyle(.primary)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
