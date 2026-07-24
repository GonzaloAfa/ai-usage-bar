import AppKit
import ServiceManagement
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // La estrella a la izquierda y el porcentaje a su derecha, con el espaciado del sistema.
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(handleClick)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        self.statusItem = statusItem

        store.onChange = { [weak self] in self?.updateStatusItem() }
        updateStatusItem()
        store.start()

        // Al volver de suspensión los datos siempre están viejos: la sesión de 5 h pudo reiniciarse
        // mientras el Mac dormía.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.store.refresh() }
        }

        // El ícono coloreado no es plantilla, así que hay que redibujarlo cuando la barra cambia de
        // claro a oscuro.
        appearanceObservation = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.updateStatusItem() }
        }

        // Abre el popover al arrancar para poder revisarlo con una captura de pantalla.
        if ProcessInfo.processInfo.environment["CLAUDE_USAGE_BAR_AUTO_OPEN"] == "1" {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                self.togglePopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
    }

    // MARK: Barra de menú

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        let needsReauth = store.state == .needsReauth
        let isFailed = if case .failed = store.state { store.snapshot == nil } else { false }
        let state = StatusItemState(
            gauge: store.criticalGauge,
            isFailed: isFailed,
            needsReauth: needsReauth
        )

        button.image = StatusItemRenderer.image(for: state)
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

    private func togglePopover() {
        guard let button = statusItem?.button else { return }

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
            rootView: UsagePopoverView(store: store) { NSApp.terminate(nil) }
        )
        return popover
    }

    // MARK: Menú contextual

    private func showContextMenu() {
        guard let statusItem else { return }

        let menu = NSMenu()
        menu.addItem(withTitle: store.tooltip, action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Actualizar ahora", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let open = NSMenuItem(title: "Abrir en claude.ai", action: #selector(openWebUsage), keyEquivalent: "")
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
        NSWorkspace.shared.open(URL(string: "https://claude.ai/settings/usage")!)
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
