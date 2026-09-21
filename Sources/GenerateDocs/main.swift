import AppKit
import SwiftUI
import UsageCore

// Dibuja las láminas de estados que ilustran el README.
//
// Cada caso se define como la respuesta cruda del endpoint y se decodifica con el mismo código que usa
// la app, así que las láminas no pueden desviarse de lo que la app realmente muestra.
//
//     swift run GenerateDocs [directorio de salida]

// MARK: - Respuestas de utilería

private struct StubClient: UsageFetching {
    let json: String

    func fetch() async throws -> ProviderSnapshot {
        try UsageResponse.decode(Data(json.utf8)).snapshot
    }
}

/// La misma utilería para el otro proveedor: su respuesta cruda decodificada con el código de la app.
private struct CodexStubClient: UsageFetching {
    let json: String

    func fetch() async throws -> ProviderSnapshot {
        try CodexUsageResponse.decode(Data(json.utf8)).snapshot
    }
}

private struct ErrorClient: UsageFetching {
    let error: any Error

    func fetch() async throws -> ProviderSnapshot { throw error }
}

private struct Limit {
    let kind: String
    let group: String
    let percent: Double
    let severity: String
    let reset: Date
    var model: String?
}

private func iso(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.string(from: date)
}

private func usageJSON(_ limits: [Limit], spend: (used: Int, limit: Int)? = nil) -> String {
    let rows = limits.map { limit in
        let scope = limit.model.map { #"{"model":{"id":null,"display_name":"\#($0)"},"surface":null}"# } ?? "null"
        return """
            {"kind":"\(limit.kind)","group":"\(limit.group)","percent":\(limit.percent),
             "severity":"\(limit.severity)","resets_at":"\(iso(limit.reset))","scope":\(scope),"is_active":true}
            """
    }

    let spendJSON: String
    if let spend {
        let percent = Double(spend.used) / Double(spend.limit) * 100
        spendJSON = """
            {"used":{"amount_minor":\(spend.used),"currency":"USD","exponent":2},
             "limit":{"amount_minor":\(spend.limit),"currency":"USD","exponent":2},
             "percent":\(percent),"severity":"normal","enabled":true}
            """
    } else {
        spendJSON = #"{"used":{"amount_minor":0,"currency":"USD","exponent":2},"percent":0,"enabled":false}"#
    }

    return """
        {"limits":[\(rows.joined(separator: ","))],"spend":\(spendJSON)}
        """
}

// MARK: - Momentos de reinicio

private let now = Date()
private let sessionReset = now.addingTimeInterval(2 * 3600 + 28 * 60)
private let sessionResetSoon = now.addingTimeInterval(41 * 60)
private let sessionResetFresh = now.addingTimeInterval(4 * 3600 + 58 * 60)

/// El próximo domingo a las 5:59, para que el texto salga como «Se restablece dom, 5:59 a.m.».
private let weeklyReset: Date = {
    var components = DateComponents()
    components.weekday = 1
    components.hour = 5
    components.minute = 59
    return Calendar.current.nextDate(
        after: now.addingTimeInterval(24 * 3600),
        matching: components,
        matchingPolicy: .nextTime
    ) ?? now.addingTimeInterval(3 * 24 * 3600)
}()

private let monthlyReset = now.addingTimeInterval(8 * 24 * 3600)

// MARK: - Los casos

private func session(_ percent: Double, _ severity: String = "normal", reset: Date = sessionReset) -> Limit {
    Limit(kind: "session", group: "session", percent: percent, severity: severity, reset: reset, model: nil)
}

private func weeklyAll(_ percent: Double, _ severity: String = "normal") -> Limit {
    Limit(kind: "weekly_all", group: "weekly", percent: percent, severity: severity, reset: weeklyReset, model: nil)
}

private func weeklyModel(_ name: String, _ percent: Double, _ severity: String = "normal") -> Limit {
    Limit(kind: "weekly_scoped", group: "weekly", percent: percent, severity: severity, reset: weeklyReset, model: name)
}

@MainActor
private func store(_ json: String) async -> UsageStore {
    let store = UsageStore(provider: .claude, client: StubClient(json: json), defaults: freshDefaults())
    await store.refreshAndWait()
    return store
}

@MainActor
private func codexStore(_ json: String) async -> UsageStore {
    let store = UsageStore(
        provider: .codex,
        client: CodexStubClient(json: json),
        defaults: freshDefaults()
    )
    await store.refreshAndWait()
    return store
}

/// La respuesta de Codex para las láminas: dos ventanas y, si se pide, saldo de créditos.
private func codexJSON(
    primary: Double,
    secondary: Double,
    reset: Date,
    weekly: Date,
    limitReached: Bool = false,
    credits: Double? = nil
) -> String {
    let creditsJSON = credits.map {
        #"{"has_credits":true,"unlimited":false,"overage_limit_reached":false,"balance":"\#($0)"}"#
    } ?? #"{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0"}"#

    return """
        {"plan_type":"plus",
         "rate_limit":{"allowed":\(!limitReached),"limit_reached":\(limitReached),
          "primary_window":{"used_percent":\(primary),"limit_window_seconds":18000,
           "reset_at":\(reset.timeIntervalSince1970)},
          "secondary_window":{"used_percent":\(secondary),"limit_window_seconds":604800,
           "reset_at":\(weekly.timeIntervalSince1970)}},
         "credits":\(creditsJSON),
         "spend_control":{"reached":false,"individual_limit":null}}
        """
}

private var defaultsCounter = 0

/// Un dominio de preferencias limpio por caso: así ninguna lámina hereda la caché de otra.
@MainActor
private func freshDefaults() -> UserDefaults {
    defaultsCounter += 1
    let defaults = UserDefaults(suiteName: "cl.alisonvivanco.ai-usage-bar.docs.\(defaultsCounter)")!
    defaults.removePersistentDomain(forName: "cl.alisonvivanco.ai-usage-bar.docs.\(defaultsCounter)")
    return defaults
}

/// Un store que ya tiene datos en caché y ahora falla: es el camino real hacia «datos viejos».
@MainActor
private func degradedStore(json: String, failingWith error: any Error) async -> UsageStore {
    let defaults = freshDefaults()
    let warm = UsageStore(provider: .claude, client: StubClient(json: json), defaults: defaults)
    await warm.refreshAndWait()

    // Envejecer la fecha del caché: si no, la lámina diría «Actualizado justo ahora» al lado de un
    // aviso de sesión caducada, que se contradice. La clave es la que usa UsageStore internamente.
    defaults.set(Date().addingTimeInterval(-6 * 60), forKey: "cachedUsageDate.claude")

    let degraded = UsageStore(provider: .claude, client: ErrorClient(error: error), defaults: defaults)
    await degraded.refreshAndWait()
    return degraded
}

// MARK: - Dibujo

private let popoverWidth: CGFloat = 320
private let scale: CGFloat = 2
private let sheetBackground = NSColor(red: 0.086, green: 0.09, blue: 0.102, alpha: 1)
private let popoverBackground = Color(red: 0.137, green: 0.137, blue: 0.149)

@MainActor
private func renderPopover(_ store: UsageStore) -> NSImage {
    let renderer = ImageRenderer(
        content: UsagePopoverView(store: store, onQuit: {})
            .frame(width: popoverWidth)
            .environment(\.colorScheme, .dark)
            .background(popoverBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(6)
    )
    renderer.scale = scale
    return renderer.nsImage ?? NSImage(size: NSSize(width: popoverWidth, height: 100))
}

private func attributed(
    _ text: String,
    size: CGFloat,
    weight: NSFont.Weight,
    color: NSColor = .white
) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineSpacing = 2
    return NSAttributedString(
        string: text,
        attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
    )
}

private func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
    ceil(
        text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
    )
}

private struct Cell {
    let title: String
    let note: String
    let image: NSImage
}

/// Compone las celdas en una grilla, con su rótulo sobre cada una.
@MainActor
private func sheet(cells: [Cell], columns: Int) -> NSImage {
    let cellWidth = popoverWidth * scale
    let gapX: CGFloat = 52
    let gapY: CGFloat = 64
    let padding: CGFloat = 48

    let rows = stride(from: 0, to: cells.count, by: columns).map { start in
        Array(cells[start..<min(start + columns, cells.count)])
    }

    func titleHeight(_ cell: Cell) -> CGFloat {
        height(of: attributed(cell.title, size: 26, weight: .semibold), width: cellWidth)
    }
    func noteHeight(_ cell: Cell) -> CGFloat {
        height(of: attributed(cell.note, size: 19, weight: .regular), width: cellWidth)
    }

    // Los rótulos de una fila tienen largos distintos: se reserva el más alto para todos, de modo que
    // los popovers de una misma fila arranquen a la misma altura.
    let captionHeights = rows.map { row in
        row.map { titleHeight($0) + 8 + noteHeight($0) }.max() ?? 0
    }
    let rowHeights = rows.enumerated().map { index, row in
        captionHeights[index] + 18 + (row.map(\.image.size.height).max() ?? 0)
    }

    let columnsInWidest = min(columns, cells.count)
    let width = padding * 2 + CGFloat(columnsInWidest) * cellWidth + CGFloat(columnsInWidest - 1) * gapX
    let totalHeight = padding * 2 + rowHeights.reduce(0, +) + gapY * CGFloat(max(rows.count - 1, 0))

    let canvas = NSImage(size: NSSize(width: width, height: totalHeight))
    canvas.lockFocus()
    sheetBackground.setFill()
    NSRect(origin: .zero, size: canvas.size).fill()

    var y = totalHeight - padding
    for (index, row) in rows.enumerated() {
        let rowHeight = rowHeights[index]
        for (column, cell) in row.enumerated() {
            let x = padding + CGFloat(column) * (cellWidth + gapX)

            let title = attributed(cell.title, size: 26, weight: .semibold, color: .white)
            let titleH = height(of: title, width: cellWidth)
            title.draw(in: NSRect(x: x, y: y - titleH, width: cellWidth, height: titleH))

            let note = attributed(
                cell.note, size: 19, weight: .regular,
                color: NSColor(white: 1, alpha: 0.55)
            )
            let noteH = height(of: note, width: cellWidth)
            note.draw(in: NSRect(x: x, y: y - titleH - 8 - noteH, width: cellWidth, height: noteH))

            let imageTop = y - captionHeights[index] - 18
            cell.image.draw(
                in: NSRect(
                    x: x, y: imageTop - cell.image.size.height,
                    width: cell.image.size.width, height: cell.image.size.height
                )
            )
        }
        y -= rowHeight + gapY
    }
    canvas.unlockFocus()
    return canvas
}

/// La tira con los estados del ítem de la barra de menú, sobre barra clara y oscura.
@MainActor
private func menuBarSheet() -> NSImage {
    let states: [(String, StatusItemState, String)] = [
        ("Con margen", .level(percent: 39, severity: .normal), "bajo el 70 %"),
        ("Aviso", .level(percent: 78, severity: .warning), "desde el 70 %"),
        ("Crítico", .level(percent: 95, severity: .critical), "desde el 90 %"),
        ("Al tope", .level(percent: 100, severity: .critical), "sin margen"),
        ("Consultando", .loading, "antes de la primera respuesta"),
        ("Error", .error, "sesión caducada o sin conexión"),
    ]

    let factor: CGFloat = 2
    let rowHeight: CGFloat = 42 * factor
    let labelWidth: CGFloat = 132 * factor
    let stripWidth: CGFloat = 116 * factor
    let padding: CGFloat = 20 * factor
    let headerHeight: CGFloat = 18 * factor
    let width = padding * 2 + labelWidth + stripWidth * 2 + 12 * factor
    let height = padding * 2 + headerHeight + rowHeight * CGFloat(states.count)

    let canvas = NSImage(size: NSSize(width: width, height: height))
    canvas.lockFocus()
    sheetBackground.setFill()
    NSRect(origin: .zero, size: canvas.size).fill()

    // Encabezados: sin ellos no se entiende por qué cada estado aparece dos veces.
    for (column, name) in ["Barra clara", "Barra oscura"].enumerated() {
        let x = padding + labelWidth + CGFloat(column) * (stripWidth + 12 * factor)
        attributed(name, size: 7 * factor, weight: .medium, color: NSColor(white: 1, alpha: 0.4))
            .draw(at: NSPoint(x: x, y: height - padding - 10 * factor))
    }

    for (index, entry) in states.enumerated() {
        let (label, state, note) = entry
        let top = height - padding - headerHeight - CGFloat(index) * rowHeight

        let title = attributed(label, size: 8 * factor, weight: .semibold, color: .white)
        title.draw(at: NSPoint(x: padding, y: top - 11 * factor))
        let subtitle = attributed(note, size: 7 * factor, weight: .regular, color: NSColor(white: 1, alpha: 0.45))
        subtitle.draw(at: NSPoint(x: padding, y: top - 21 * factor))

        for (column, isDark) in [(0, false), (1, true)].map({ ($0.0, $0.1) }) {
            let x = padding + labelWidth + CGFloat(column) * (stripWidth + 12 * factor)
            let stripRect = NSRect(
                x: x, y: top - 32 * factor,
                width: stripWidth, height: 26 * factor
            )
            let barColor = isDark
                ? NSColor(white: 0.17, alpha: 1)
                : NSColor(white: 0.925, alpha: 1)
            barColor.setFill()
            NSBezierPath(roundedRect: stripRect, xRadius: 5 * factor, yRadius: 5 * factor).fill()

            let ink: NSColor = isDark ? .white : .black
            let image = StatusItemRenderer.image(for: state)
            let drawable = image.isTemplate ? image.tinted(with: ink) : image
            let side = 13 * factor
            drawable.draw(
                in: NSRect(
                    x: stripRect.minX + 12 * factor,
                    y: stripRect.midY - side / 2,
                    width: side, height: side
                )
            )

            let title = NSMutableAttributedString(attributedString: StatusItemRenderer.title(for: state))
            let color: NSColor = state.severity == .normal ? ink : state.severity.menuBarTint
            title.addAttributes(
                [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9 * factor, weight: .regular),
                    .foregroundColor: color,
                ],
                range: NSRange(location: 0, length: title.length)
            )
            title.draw(at: NSPoint(x: stripRect.minX + 30 * factor, y: stripRect.midY - 6.5 * factor))
        }
    }

    canvas.unlockFocus()
    return canvas
}

// MARK: - Escritura

/// Reescala sobre los píxeles reales del mapa de bits.
///
/// `NSImage.size` va en puntos y `lockFocus` crea el respaldo a la escala de la pantalla, así que en
/// una Retina el PNG mide el doble de lo que dice `size`: hay que mirar el `CGImage` para saber cuánto
/// pesa de verdad.
private func resized(_ cgImage: CGImage, toWidth width: Int) -> CGImage? {
    let height = Int((Double(width) / Double(cgImage.width) * Double(cgImage.height)).rounded())
    guard
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { return nil }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

/// Ancho máximo de las láminas: GitHub muestra el README en unos 880 pt, así que con esto sobra
/// densidad para pantallas Retina sin llevarse megabytes al repositorio.
private let maximumSheetWidth: CGFloat = 1800

private func write(_ image: NSImage, to directory: URL, named name: String) throws {
    guard var cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    if CGFloat(cgImage.width) > maximumSheetWidth,
       let smaller = resized(cgImage, toWidth: Int(maximumSheetWidth)) {
        cgImage = smaller
    }

    guard let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let url = directory.appending(path: name)
    try data.write(to: url)
    let kilobytes = Double(data.count) / 1024
    print(String(format: "  %@  %.0f KB", name, kilobytes))
}

// MARK: - Programa

let outputPath = CommandLine.arguments.dropFirst().first ?? "docs/img"
let outputDirectory = URL(fileURLWithPath: outputPath, isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

// La apariencia oscura es la que se ve en las láminas; también fija los colores del sistema.
NSApplication.shared.appearance = NSAppearance(named: .darkAqua)

let comfortable = usageJSON([session(39), weeklyAll(45), weeklyModel("Fable", 20)])
let warning = usageJSON([session(39), weeklyAll(76, "warning"), weeklyModel("Fable", 59)])

print("Láminas en \(outputDirectory.path):")

// 1 · La barra de menú
try write(menuBarSheet(), to: outputDirectory, named: "barra-de-menu.png")

// 2 · Cuánto queda
try write(
    sheet(
        cells: [
            Cell(
                title: "Con margen de sobra",
                note: "Todo bajo el 70 %: las barras van en azul y la cabecera no llama la atención.",
                image: renderPopover(await store(comfortable))
            ),
            Cell(
                title: "Aviso en el semanal",
                note: "Un límite pasó el 70 %. La cabecera toma su cifra y su color, aunque no sea la sesión.",
                image: renderPopover(await store(warning))
            ),
            Cell(
                title: "Sesión crítica",
                note: "Desde el 90 % se impone el rojo, incluso si la API reportó el límite como normal.",
                image: renderPopover(
                    await store(
                        usageJSON([
                            session(95), weeklyAll(71, "warning"), weeklyModel("Fable", 40),
                        ])
                    )
                )
            ),
            Cell(
                title: "Consumido por completo",
                note: "Al 100 % el plazo es lo único que queda por saber, y sigue a la vista.",
                image: renderPopover(
                    await store(
                        usageJSON([
                            session(100, "critical", reset: sessionResetSoon),
                            weeklyAll(100, "critical"),
                            weeklyModel("Fable", 88, "warning"),
                        ])
                    )
                )
            ),
            Cell(
                title: "Recién reiniciado",
                note: "Un 1 % conserva un trazo visible; un 0 % exacto no dibuja nada.",
                image: renderPopover(
                    await store(
                        usageJSON([
                            session(1, reset: sessionResetFresh),
                            weeklyAll(3),
                            weeklyModel("Fable", 0),
                        ])
                    )
                )
            ),
        ],
        columns: 3
    ),
    to: outputDirectory,
    named: "popover-consumo.png"
)

// 3 · Qué límites aparecen
try write(
    sheet(
        cells: [
            Cell(
                title: "Otros modelos, no sólo Fable",
                note: "Cada fila toma su nombre de scope.model.display_name, así que aparecen los modelos que tenga la cuenta.",
                image: renderPopover(
                    await store(
                        usageJSON([
                            session(52), weeklyAll(68),
                            weeklyModel("Opus", 82, "warning"), weeklyModel("Sonnet", 44),
                        ])
                    )
                )
            ),
            Cell(
                title: "Un límite que no conocemos",
                note: "Un tipo de límite nuevo se muestra legible en vez de descartarse: mejor un nombre feo que ocultarlo.",
                image: renderPopover(
                    await store(
                        usageJSON([
                            session(30), weeklyAll(40),
                            Limit(
                                kind: "monthly_experimental", group: "monthly", percent: 5,
                                severity: "una_gravedad_nueva", reset: monthlyReset, model: nil
                            ),
                        ])
                    )
                )
            ),
            Cell(
                title: "Con uso extra activo",
                note: "La sección de uso extra sólo existe si la cuenta la tiene habilitada.",
                image: renderPopover(
                    await store(
                        usageJSON(
                            [session(95), weeklyAll(71, "warning")],
                            spend: (used: 1234, limit: 5000)
                        )
                    )
                )
            ),
            Cell(
                title: "Sin desglose por modelo",
                note: "Si limits[] llegara vacío se recurre a five_hour y seven_day: quedan las dos ventanas, sin fila por modelo.",
                image: renderPopover(
                    await store(
                        """
                        {"five_hour":{"utilization":12,"resets_at":"\(iso(sessionReset))"},
                         "seven_day":{"utilization":44,"resets_at":"\(iso(weeklyReset))"},"limits":[]}
                        """
                    )
                )
            ),
        ],
        columns: 2
    ),
    to: outputDirectory,
    named: "popover-limites.png"
)

// 4 · Cuando algo falla
let loadingStore = UsageStore(
    provider: .claude,
    client: ErrorClient(error: UsageError.transport("sin red")),
    defaults: freshDefaults()
)

try write(
    sheet(
        cells: [
            Cell(
                title: "Sesión caducada",
                note: "El token venció. La app no lo renueva: avisa y sigue mostrando lo último que supo.",
                image: renderPopover(
                    await degradedStore(json: warning, failingWith: UsageError.unauthorized)
                )
            ),
            Cell(
                title: "Sin conexión, con datos previos",
                note: "Un fallo puntual no deja la barra en blanco: el aviso baja al pie, donde no tapa las cifras.",
                image: renderPopover(
                    await degradedStore(json: warning, failingWith: UsageError.transport("sin red"))
                )
            ),
            Cell(
                title: "Error en el primer arranque",
                note: "Sin caché de una sesión anterior no hay nada que mostrar, así que el aviso ocupa su lugar.",
                image: renderPopover(
                    await {
                        let store = UsageStore(
                            client: ErrorClient(error: UsageError.transport("sin red")),
                            defaults: freshDefaults()
                        )
                        await store.refreshAndWait()
                        return store
                    }()
                )
            ),
            Cell(
                title: "Consultando",
                note: "El primer instante tras abrir la app, antes de que llegue la respuesta.",
                image: renderPopover(loadingStore)
            ),
        ],
        columns: 2
    ),
    to: outputDirectory,
    named: "popover-degradados.png"
)

print("Listo.")

// 5 · Los dos proveedores en la barra

/// Una franja de barra de menú con los dos ítems, uno al lado del otro.
///
/// Es la lámina que explica por qué van separados: cada símbolo lleva su propio color, así que un
/// Codex al tope se ve rojo sin arrastrar al indicador de Claude, que puede estar holgado.
@MainActor
private func providerStripSheet() -> NSImage {
    let entries: [(Provider, StatusItemState)] = [
        (.claude, .level(percent: 39, severity: .normal)),
        (.codex, .level(percent: 100, severity: .critical)),
    ]

    let factor: CGFloat = 2
    let padding: CGFloat = 20 * factor
    let stripWidth: CGFloat = 200 * factor
    let stripHeight: CGFloat = 30 * factor
    let headerHeight: CGFloat = 16 * factor
    let width = padding * 2 + stripWidth
    // El gap sólo va entre las dos franjas, no debajo de la última.
    let height = padding * 2 + (headerHeight + stripHeight) * 2 + 14 * factor

    let canvas = NSImage(size: NSSize(width: width, height: height))
    canvas.lockFocus()
    sheetBackground.setFill()
    NSRect(origin: .zero, size: canvas.size).fill()

    for (row, isDark) in [(0, false), (1, true)] {
        let top = height - padding - CGFloat(row) * (headerHeight + stripHeight + 14 * factor)

        attributed(
            isDark ? "Barra oscura" : "Barra clara",
            size: 7 * factor, weight: .medium, color: NSColor(white: 1, alpha: 0.4)
        ).draw(at: NSPoint(x: padding, y: top - 10 * factor))

        let stripRect = NSRect(
            x: padding, y: top - headerHeight - stripHeight,
            width: stripWidth, height: stripHeight
        )
        (isDark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.925, alpha: 1)).setFill()
        NSBezierPath(roundedRect: stripRect, xRadius: 5 * factor, yRadius: 5 * factor).fill()

        let ink: NSColor = isDark ? .white : .black
        var x = stripRect.minX + 16 * factor
        for (provider, state) in entries {
            let image = StatusItemRenderer.image(for: state, provider: provider)
            let drawable = image.isTemplate ? image.tinted(with: ink) : image
            let side = 13 * factor
            drawable.draw(
                in: NSRect(x: x, y: stripRect.midY - side / 2, width: side, height: side)
            )
            x += side + 4 * factor

            let title = NSMutableAttributedString(attributedString: StatusItemRenderer.title(for: state))
            title.addAttributes(
                [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 9 * factor, weight: .regular),
                    .foregroundColor: state.severity == .normal ? ink : state.severity.menuBarTint,
                ],
                range: NSRange(location: 0, length: title.length)
            )
            title.draw(at: NSPoint(x: x, y: stripRect.midY - 7 * factor))
            x += title.size().width + 22 * factor
        }
    }
    canvas.unlockFocus()
    return canvas
}

try write(providerStripSheet(), to: outputDirectory, named: "barra-dos-proveedores.png")

// 6 · El popover de Codex
let codexReset = now.addingTimeInterval(1 * 3600 + 12 * 60)

try write(
    sheet(
        cells: [
            Cell(
                title: "Codex con margen",
                note: "Las mismas dos ventanas que muestra /status: la sesión de 5 h y el límite semanal.",
                image: renderPopover(
                    await codexStore(
                        codexJSON(primary: 32, secondary: 25, reset: codexReset, weekly: weeklyReset)
                    )
                )
            ),
            Cell(
                title: "Codex al tope",
                note: "Al quedarse sin mensajes la sesión se marca en rojo y aparece el saldo de créditos, que es lo que permite seguir.",
                image: renderPopover(
                    await codexStore(
                        codexJSON(
                            primary: 100,
                            secondary: 25,
                            reset: codexReset,
                            weekly: weeklyReset,
                            limitReached: true,
                            credits: 12.5
                        )
                    )
                )
            ),
        ],
        columns: 2
    ),
    to: outputDirectory,
    named: "popover-codex.png"
)
