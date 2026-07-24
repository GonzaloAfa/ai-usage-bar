import AppKit

// Modo diagnóstico: consulta una vez, imprime y termina, sin tocar la barra de menú.
if ProcessInfo.processInfo.environment["CLAUDE_USAGE_BAR_PRINT"] == "1" {
    exit(await printUsageSummary())
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// Sin ícono en el Dock ni ventanas: la app vive sólo en la barra de menú. Hacerlo en código y no sólo
// con `LSUIElement` permite ejecutar el binario suelto durante el desarrollo con el mismo comportamiento.
application.setActivationPolicy(.accessory)
application.run()
