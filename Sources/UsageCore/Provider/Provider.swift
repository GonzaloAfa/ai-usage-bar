import Foundation

/// Un servicio del que se muestra el consumo: Claude o Codex.
///
/// Reúne todo lo que cambia entre uno y otro fuera de la forma de su API — el nombre visible, el
/// símbolo de la barra de menú, dónde se revisa el uso en la web y qué hacer cuando la sesión
/// caduca. La interfaz no conoce ningún proveedor en particular: lee estos campos.
public struct Provider: Sendable, Identifiable, Equatable, Hashable {
    /// Identificador estable: nombra las claves de caché y las variables de entorno de desarrollo.
    public let id: String
    public let displayName: String

    /// SF Symbol del ítem en la barra de menú.
    public let symbolName: String

    /// Glifo de respaldo por si el símbolo no existiera en esta versión de macOS.
    public let fallbackGlyph: String

    /// Dónde se revisa el uso en la web, y cómo se nombra ese enlace en el popover.
    public let webUsageURL: URL
    public let webUsageLabel: String

    /// Qué hacer cuando la sesión caducó. Se muestra tal cual en el popover, con formato Markdown.
    public let reauthHint: String

    public init(
        id: String,
        displayName: String,
        symbolName: String,
        fallbackGlyph: String,
        webUsageURL: URL,
        webUsageLabel: String,
        reauthHint: String
    ) {
        self.id = id
        self.displayName = displayName
        self.symbolName = symbolName
        self.fallbackGlyph = fallbackGlyph
        self.webUsageURL = webUsageURL
        self.webUsageLabel = webUsageLabel
        self.reauthHint = reauthHint
    }

    /// La estrella de cuatro puntas que el sistema ya usa para lo relacionado con IA.
    public static let claude = Provider(
        id: "claude",
        displayName: "Claude",
        symbolName: "sparkle",
        fallbackGlyph: "✳",
        webUsageURL: URL(string: "https://claude.ai/settings/usage")!,
        webUsageLabel: "claude.ai",
        reauthHint: """
            La sesión de Claude Code caducó. Abre `claude` en una terminal para renovarla; el \
            indicador se pondrá al día solo.
            """
    )

    /// Un hexágono: se distingue de la estrella de un vistazo y no compite con ella en la barra.
    public static let codex = Provider(
        id: "codex",
        displayName: "Codex",
        symbolName: "hexagon",
        fallbackGlyph: "⬡",
        webUsageURL: URL(string: "https://chatgpt.com/codex/settings/usage")!,
        webUsageLabel: "chatgpt.com",
        reauthHint: """
            La sesión de Codex caducó. Abre Codex e inicia sesión de nuevo; el indicador se pondrá \
            al día solo.
            """
    )

    /// En el orden en que se quieren ver en la barra de menú.
    public static let all: [Provider] = [.claude, .codex]
}
