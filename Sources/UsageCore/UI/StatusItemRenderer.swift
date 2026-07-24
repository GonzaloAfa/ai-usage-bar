import AppKit

public enum StatusItemState: Equatable {
    case level(percent: Double, severity: Severity)
    case loading
    case error

    /// El ícono se construye a partir del límite más consumido: es el que va a frenar el trabajo primero.
    public init(gauge: LimitGauge?, isFailed: Bool, needsReauth: Bool) {
        if needsReauth || isFailed {
            self = .error
        } else if let gauge {
            self = .level(percent: gauge.percent, severity: gauge.severity)
        } else {
            self = .loading
        }
    }

    public var severity: Severity {
        switch self {
        case .level(_, let severity): return severity
        case .loading: return .normal
        case .error: return .critical
        }
    }
}

/// Compone lo que se ve en la barra de menú: la estrella de IA y, al lado, el porcentaje.
///
/// El número se lee de un vistazo, sin tener que interpretar cuánto ocupa un dibujo, y la estrella
/// evita que el indicador se confunda con la batería del sistema, que vive a pocos íconos de distancia.
public enum StatusItemRenderer {
    /// La estrella de cuatro puntas que el sistema ya usa para lo relacionado con IA.
    public static func image(for state: StatusItemState) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        let image = NSImage(
            systemSymbolName: "sparkle",
            accessibilityDescription: accessibilityDescription(for: state)
        )?.withSymbolConfiguration(configuration) ?? fallbackImage(for: state)

        // En estado normal es plantilla y la barra de menú la colorea sola, adaptándose a claro y
        // oscuro. Al avisar el color es parte del mensaje, así que se pinta explícitamente.
        if state.severity == .normal {
            image.isTemplate = true
        } else {
            image.isTemplate = false
            return image.tinted(with: state.severity.menuBarTint)
        }
        return image
    }

    /// El porcentaje del límite más consumido.
    public static func title(for state: StatusItemState) -> NSAttributedString {
        let text: String
        switch state {
        case .level(let percent, _): text = UsageFormat.percent(percent)
        case .loading: text = "—"
        case .error: text = "!"
        }

        return NSAttributedString(
            string: text,
            attributes: [
                // Dígitos de ancho fijo: si no, el ítem se ensancha y se angosta al cambiar la cifra.
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: state.severity.menuBarTint,
            ]
        )
    }

    public static func accessibilityDescription(for state: StatusItemState) -> String {
        switch state {
        case .level(let percent, _): return "Uso de Claude: \(UsageFormat.percent(percent))"
        case .loading: return "Consultando el uso de Claude"
        case .error: return "Error al consultar el uso de Claude"
        }
    }

    /// Si el símbolo del sistema no estuviera disponible, un asterisco cumple el mismo papel.
    private static func fallbackImage(for state: StatusItemState) -> NSImage {
        let glyph = NSAttributedString(
            string: "✳",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
        )
        let size = glyph.size()
        let image = NSImage(size: NSSize(width: ceil(size.width), height: ceil(size.height)))
        image.lockFocus()
        glyph.draw(at: .zero)
        image.unlockFocus()
        return image
    }
}

extension NSImage {
    /// Colorea una imagen de plantilla conservando su forma.
    ///
    /// La barra de menú hace esto sola con las imágenes de plantilla; hace falta hacerlo a mano al
    /// dibujar el ítem fuera de ella, como en las láminas de la documentación.
    public func tinted(with color: NSColor) -> NSImage {
        let tinted = NSImage(size: size, flipped: false) { rect in
            color.set()
            self.draw(in: rect)
            rect.fill(using: .sourceAtop)
            return true
        }
        tinted.isTemplate = false
        tinted.accessibilityDescription = accessibilityDescription
        return tinted
    }
}

extension Severity {
    /// El color en la barra de menú, donde la legibilidad manda sobre el parecido con la web.
    ///
    /// El ámbar de las barras del popover casi no contrasta sobre una barra de menú clara, así que
    /// para avisar se usa naranja. En estado normal se cede el color al sistema.
    public var menuBarTint: NSColor {
        switch self {
        case .normal: return .labelColor
        case .warning: return .systemOrange
        case .critical: return .systemRed
        }
    }
}
