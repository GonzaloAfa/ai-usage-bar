import AppKit
import ServiceManagement
import SwiftUI
import UsageCore

/// Un ítem de la barra de menú: el de Claude o el de Codex.
///
/// Cada proveedor tiene el suyo, con su propio store y su propio popover. Van separados y no en un
/// solo ítem con dos cifras porque así cada uno conserva el color de su estado: un Codex al tope no
/// debe teñir de rojo el indicador de Claude, que puede estar holgado.
@MainActor
final class ProviderStatusItem {
    let store: UsageStore

    private let provider: Provider
    private let onQuit: () -> Void
    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private var appearanceObservation: NSKeyValueObservation?

    init(provider: Provider, onQuit: @escaping () -> Void) {
        self.provider = provider
        self.onQuit = onQuit
        self.store = UsageStore(provider: provider)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // El símbolo a la izquierda y el porcentaje a su derecha, con el espaciado del sistema.
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        store.onChange = { [weak self] in self?.update() }
        update()
        store.start()

        // El ícono coloreado no es plantilla, así que hay que redibujarlo cuando la barra cambia de
        // claro a oscuro.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    func stop() {
        store.stop()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    func refresh() {
        store.refresh()
    }

    // MARK: Barra de menú

    private func update() {
        guard let button = statusItem.button else { return }

        let needsReauth = store.state == .needsReauth
        let isFailed = if case .failed = store.state { store.snapshot == nil } else { false }
        let state = StatusItemState(
            gauge: store.criticalGauge,
            isFailed: isFailed,
            needsReauth: needsReauth
        )

        button.image = StatusItemRenderer.image(for: state, provider: provider)
        button.attributedTitle = StatusItemRenderer.title(for: state)
        button.toolTip = store.tooltip
        // Los datos servidos desde la caché se ven apagados hasta que la API confirma.
        button.appearsDisabled = store.isStale && store.snapshot != nil
    }

    @objc private func handleClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    // MARK: Popover

    func togglePopover() {
        guard let button = statusItem.button else { return }

        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let popover = self.popover ?? makePopover()
        self.popover = popover

        // Al abrirlo conviene tener datos frescos, pero sin gastar una llamada si acabamos de consultar.
        store.refreshIfOlderThan(20)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: UsagePopoverView(store: store, onQuit: onQuit)
        )
        return popover
    }

    // MARK: Menú contextual

    private func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: store.tooltip, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Actualizar ahora", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let open = NSMenuItem(
            title: "Abrir en \(provider.webUsageLabel)",
            action: #selector(openWebUsage),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let launch = NSMenuItem(
            title: "Iniciar al abrir sesión",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Salir", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // El menú se cuelga del ítem sólo durante este clic; si quedara puesto, el clic izquierdo
        // dejaría de abrir el popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        store.refresh()
    }

    @objc private func openWebUsage() {
        NSWorkspace.shared.open(provider.webUsageURL)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // Con firma ad-hoc macOS puede rechazar el registro; el README explica la alternativa
            // con un LaunchAgent.
            let alert = NSAlert()
            alert.messageText = "No se pudo cambiar el inicio automático"
            alert.informativeText = """
                \(error.localizedDescription)

                Si la app está firmada de forma ad-hoc, macOS puede rechazarlo. El README describe \
                cómo hacerlo con un LaunchAgent.
                """
            alert.runModal()
        }
    }
}
