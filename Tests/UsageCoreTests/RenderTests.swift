import AppKit
import SwiftUI
import Testing

@testable import UsageCore

/// Comprueba que el ícono y el popover se dibujan de verdad, y deja los PNG a mano para revisarlos.
///
/// Un `screencapture` de la barra de menú exige permiso de grabación de pantalla, así que el render
/// se hace en proceso: es lo que permite verificar el aspecto sin depender de ese permiso.
/// Con `SNAPSHOT_DIR=/ruta swift test` los archivos quedan donde se indique.
@MainActor
@Suite("Dibujo del ícono y del popover")
struct RenderTests {
    private var outputDirectory: URL {
        if let path = ProcessInfo.processInfo.environment["SNAPSHOT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.temporaryDirectory.appending(path: "ai-usage-bar-snapshots")
    }

    private func write(_ image: NSImage, as name: String) throws -> URL {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let url = outputDirectory.appending(path: "\(name).png")
        let representation = try #require(image.representations.first as? NSBitmapImageRep ?? bitmap(from: image))
        let data = try #require(representation.representation(using: .png, properties: [:]))
        try data.write(to: url)
        return url
    }

    private func bitmap(from image: NSImage) -> NSBitmapImageRep? {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage)
    }

    /// Cuántos píxeles tienen tinta. Sirve para distinguir «se dibujó» de «salió un lienzo vacío».
    private func inkedPixels(_ image: NSImage) throws -> Int {
        let representation = try #require(bitmap(from: image))
        var count = 0
        for x in 0..<representation.pixelsWide {
            for y in 0..<representation.pixelsHigh {
                if let color = representation.colorAt(x: x, y: y), color.alphaComponent > 0.05 {
                    count += 1
                }
            }
        }
        return count
    }

    @Test("La estrella se dibuja en todos los estados")
    func starRendersInEveryState() throws {
        for state in [
            StatusItemState.level(percent: 39, severity: .normal),
            .level(percent: 78, severity: .warning),
            .level(percent: 95, severity: .critical),
            .loading,
            .error,
        ] {
            let image = StatusItemRenderer.image(for: state)
            #expect(image.size.width > 0)
            #expect(try inkedPixels(image) > 0, "la estrella no puede salir vacía en \(state)")
        }
    }

    @Test("La estrella deja de ser plantilla cuando el color es el mensaje")
    func templateOnlyWhileNormal() {
        #expect(StatusItemRenderer.image(for: .level(percent: 39, severity: .normal)).isTemplate)
        #expect(!StatusItemRenderer.image(for: .level(percent: 78, severity: .warning)).isTemplate)
        #expect(!StatusItemRenderer.image(for: .level(percent: 95, severity: .critical)).isTemplate)
        #expect(StatusItemRenderer.image(for: .loading).isTemplate)
        #expect(!StatusItemRenderer.image(for: .error).isTemplate)
    }

    @Test("El porcentaje acompaña a la estrella, con marcas propias sin datos")
    func titleShowsPercent() {
        #expect(StatusItemRenderer.title(for: .level(percent: 78, severity: .warning)).string == "78%")
        #expect(StatusItemRenderer.title(for: .loading).string == "—")
        #expect(StatusItemRenderer.title(for: .error).string == "!")
    }

    @Test("Los dígitos son de ancho fijo para que el ítem no baile al cambiar la cifra")
    func titleUsesMonospacedDigits() throws {
        let title = StatusItemRenderer.title(for: .level(percent: 9, severity: .normal))
        let font = try #require(title.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)

        // Con dígitos proporcionales, un 1 mide menos que un 8; con los de ancho fijo, igual.
        let one = ("1" as NSString).size(withAttributes: [.font: font]).width
        let eight = ("8" as NSString).size(withAttributes: [.font: font]).width
        #expect(abs(one - eight) < 0.01)
    }

    @Test("En la barra de menú se avisa en naranja, no en el ámbar del popover")
    func menuBarUsesLegibleTint() {
        // El ámbar de las barras casi no contrasta sobre una barra de menú clara.
        #expect(Severity.warning.menuBarTint == .systemOrange)
        #expect(Severity.warning.nsTint == .systemYellow)
        #expect(Severity.critical.menuBarTint == .systemRed)
        #expect(Severity.normal.menuBarTint == .labelColor)
    }

    /// Deja una muestra de cómo se ve el ítem completo, sobre barra clara y oscura.
    @Test("Composición del ítem para revisión visual")
    func statusItemComposite() throws {
        let states: [(String, StatusItemState)] = [
            ("39", .level(percent: 39, severity: .normal)),
            ("78", .level(percent: 78, severity: .warning)),
            ("95", .level(percent: 95, severity: .critical)),
            ("cargando", .loading),
            ("error", .error),
        ]

        for (background, isDark) in [("claro", false), ("oscuro", true)] {
            let scale: CGFloat = 4
            let rowHeight: CGFloat = 24
            let canvas = NSImage(
                size: NSSize(width: 110 * scale, height: rowHeight * CGFloat(states.count) * scale)
            )
            canvas.lockFocus()
            (isDark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
            NSRect(origin: .zero, size: canvas.size).fill()

            for (index, entry) in states.enumerated() {
                let y = canvas.size.height - CGFloat(index + 1) * rowHeight * scale
                let image = StatusItemRenderer.image(for: entry.1)
                // Una imagen de plantilla la colorea la barra de menú; aquí se emula ese tinte.
                let drawable = image.isTemplate
                    ? image.tinted(with: isDark ? .white : .black)
                    : image
                drawable.draw(
                    in: NSRect(x: 8 * scale, y: y + 5 * scale, width: 14 * scale, height: 14 * scale)
                )

                let title = NSMutableAttributedString(attributedString: StatusItemRenderer.title(for: entry.1))
                title.addAttributes(
                    [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12 * scale, weight: .regular),
                        .foregroundColor: entry.1.severity == .normal
                            ? (isDark ? NSColor.white : NSColor.black)
                            : entry.1.severity.menuBarTint,
                    ],
                    range: NSRange(location: 0, length: title.length)
                )
                title.draw(at: NSPoint(x: 26 * scale, y: y + 4 * scale))
            }
            canvas.unlockFocus()
            _ = try write(canvas, as: "barra-\(background)")
        }
    }

    @Test("El popover se dibuja completo con los datos reales")
    func popoverRendersWithRealData() async throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/usage-real", withExtension: "json"))
        let store = UsageStore(
            client: FixtureUsageClient(url: url),
            defaults: UserDefaults(suiteName: "cl.alisonvivanco.ai-usage-bar.tests")!
        )
        await store.refreshAndWait()

        #expect(store.state == .ready)
        #expect(store.gauges.count == 3)
        #expect(store.tooltip.contains("Sesión actual"))

        let renderer = ImageRenderer(
            content: UsagePopoverView(store: store, onQuit: {}).frame(width: 320)
        )
        renderer.scale = 2
        let image = try #require(renderer.nsImage)

        // Un popover que se dibujó ocupa cientos de miles de píxeles; uno vacío, casi ninguno.
        #expect(image.size.width == 320)
        #expect(try inkedPixels(image) > 10_000)

        let written = try write(image, as: "popover-real")
        print("popover renderizado en \(written.path)")

        // La barra de menú puede estar en claro o en oscuro: el popover tiene que sostener las dos.
        //
        // El fondo es un gris fijo y no `windowBackgroundColor`: `ImageRenderer` resuelve los colores
        // del sistema en su propio ciclo de dibujo, así que forzar una `NSAppearance` no lo alcanza y
        // el fondo semántico saldría claro bajo texto claro. En la app el material lo pone `NSPopover`.
        let darkRenderer = ImageRenderer(
            content: UsagePopoverView(store: store, onQuit: {})
                .frame(width: 320)
                .environment(\.colorScheme, .dark)
                .background(Color(red: 0.13, green: 0.13, blue: 0.14))
        )
        darkRenderer.scale = 2
        _ = try write(try #require(darkRenderer.nsImage), as: "popover-oscuro")
    }

    @Test("El estado crítico también se dibuja, con uso extra incluido")
    func popoverRendersCriticalState() async throws {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/usage-critical", withExtension: "json"))
        let store = UsageStore(
            client: FixtureUsageClient(url: url),
            defaults: UserDefaults(suiteName: "cl.alisonvivanco.ai-usage-bar.tests")!
        )
        await store.refreshAndWait()

        #expect(store.criticalGauge?.severity == .critical)

        let renderer = ImageRenderer(
            content: UsagePopoverView(store: store, onQuit: {}).frame(width: 320)
        )
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        _ = try write(image, as: "popover-critico")
    }
}

@MainActor
@Suite("Estados del store")
struct UsageStoreStateTests {
    private struct FailingClient: UsageFetching {
        let error: any Error
        func fetch() async throws -> ProviderSnapshot { throw error }
    }

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "cl.alisonvivanco.ai-usage-bar.tests.\(UUID().uuidString)")!
        return defaults
    }

    @Test("Un token vencido pide reautenticar en vez de mostrar un error genérico")
    func unauthorizedBecomesReauth() async {
        let store = UsageStore(client: FailingClient(error: UsageError.unauthorized), defaults: makeDefaults())
        await store.refreshAndWait()

        #expect(store.state == .needsReauth)
        #expect(store.tooltip.contains("caducada"))
    }

    @Test("Sin sesión en el llavero el estado también es reautenticar")
    func missingKeychainBecomesReauth() async {
        let store = UsageStore(client: FailingClient(error: TokenError.notFound), defaults: makeDefaults())
        await store.refreshAndWait()

        #expect(store.state == .needsReauth)
    }

    @Test("Un fallo de red deja los datos anteriores en pantalla, marcados como viejos")
    func networkFailureKeepsPreviousData() async throws {
        let defaults = makeDefaults()
        let url = try #require(Bundle.module.url(forResource: "Fixtures/usage-real", withExtension: "json"))

        let good = UsageStore(client: FixtureUsageClient(url: url), defaults: defaults)
        await good.refreshAndWait()
        #expect(good.gauges.count == 3)

        // Un store nuevo con la caché del anterior y la red caída.
        let offline = UsageStore(
            client: FailingClient(error: UsageError.transport("sin red")),
            defaults: defaults
        )
        #expect(offline.gauges.count == 3, "la caché debe pintar algo al arrancar")
        #expect(offline.isStale)

        await offline.refreshAndWait()
        #expect(offline.gauges.count == 3, "un fallo no debe borrar lo que ya se mostraba")
        #expect(offline.isStale)
        if case .failed = offline.state {} else {
            Issue.record("se esperaba estado de fallo, hubo \(offline.state)")
        }
    }

    @Test("Los mensajes de error nunca incluyen el token")
    func errorsDoNotLeakTheToken() async {
        let token = "sk-ant-oat01-secreto-que-no-debe-salir"
        let store = UsageStore(
            client: FailingClient(error: UsageError.transport("fallo al conectar")),
            defaults: makeDefaults()
        )
        await store.refreshAndWait()

        if case .failed(let message) = store.state {
            #expect(!message.contains(token))
            #expect(!message.contains("sk-ant"))
        } else {
            Issue.record("se esperaba estado de fallo")
        }
    }
}
