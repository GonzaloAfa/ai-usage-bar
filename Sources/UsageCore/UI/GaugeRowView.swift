import SwiftUI

/// Una fila del popover: nombre del límite, barra de consumo y cuándo se restablece.
public struct GaugeRowView: View {
    private let gauge: LimitGauge
    private let now: Date

    public init(gauge: LimitGauge, now: Date = Date()) {
        self.gauge = gauge
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(gauge.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                Text(UsageFormat.percentUsed(gauge.percent))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            ProgressBar(percent: gauge.percent, tint: gauge.severity.tint)

            if let resetsAt = gauge.resetsAt {
                Text(UsageFormat.resetPhrase(for: resetsAt, now: now))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(gauge.title)
        .accessibilityValue(UsageFormat.percentUsed(gauge.percent))
    }
}

/// Barra de consumo. El fondo es el mismo color atenuado, como en la pantalla de Uso de Claude.
struct ProgressBar: View {
    let percent: Double
    let tint: Color

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(percent, 0), 100) / 100
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity(0.22))
                Capsule()
                    .fill(tint)
                    // Un consumo distinto de cero siempre debe dejar rastro visible.
                    .frame(width: fraction > 0 ? max(geometry.size.width * fraction, 4) : 0)
            }
        }
        .frame(height: 6)
        .animation(.easeOut(duration: 0.25), value: percent)
    }
}
