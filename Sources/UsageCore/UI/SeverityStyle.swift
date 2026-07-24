import AppKit
import SwiftUI

extension Severity {
    /// Los mismos colores que usa la pantalla de Uso de Claude: azul mientras hay margen, ámbar al
    /// acercarse al límite, rojo al borde.
    public var nsTint: NSColor {
        switch self {
        case .normal: return .systemBlue
        case .warning: return .systemYellow
        case .critical: return .systemRed
        }
    }

    public var tint: Color {
        Color(nsColor: nsTint)
    }
}
