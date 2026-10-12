import AppKit
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Un ítem por proveedor con sesión iniciada.
    private var items: [Provider: ProviderStatusItem] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        syncItems()

        // Al volver de suspensión los datos siempre están viejos: la sesión de 5 h pudo reiniciarse
        // mientras el Mac dormía. Es además el momento de revisar si apareció o se fue una sesión,
        // para no obligar a reiniciar la app tras instalar el otro proveedor.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `MainActor.assumeIsolated` no existe en Swift 5.8; la cola ya es la principal.
            Task { @MainActor [weak self] in
                self?.syncItems()
                self?.items.values.forEach { $0.refresh() }
            }
        }

        // Abre los popovers al arrancar para poder revisarlos con una captura de pantalla.
        if ProcessInfo.processInfo.environment["AI_USAGE_BAR_AUTO_OPEN"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                self.items.values.forEach { $0.togglePopover() }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        items.values.forEach { $0.stop() }
    }

    /// Crea los ítems que falten y retira los de proveedores que ya no tienen sesión.
    ///
    /// Sin sesión no hay nada que consultar, y un ítem permanentemente en error ocuparía la barra
    /// sin decir nada: quien sólo usa Claude ve un ícono, no dos.
    private func syncItems() {
        let available = Provider.available()

        for provider in available where items[provider] == nil {
            items[provider] = ProviderStatusItem(provider: provider) { NSApp.terminate(nil) }
        }
        for (provider, item) in items where !available.contains(provider) {
            item.stop()
            items[provider] = nil
        }

        // Sin ningún proveedor la app no tendría cómo mostrarse ni cómo salir.
        if items.isEmpty, let fallback = Provider.all.first {
            items[fallback] = ProviderStatusItem(provider: fallback) { NSApp.terminate(nil) }
        }
    }
}
