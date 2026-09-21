import Foundation
import Observation

/// Estado de los datos de uso y su ciclo de refresco.
///
/// Vive en el hilo principal porque su única razón de existir es alimentar la barra de menú y el
/// popover.
@MainActor
@Observable
public final class UsageStore {
    public enum State: Equatable {
        case loading
        case ready
        case needsReauth
        case failed(String)
    }

    /// De quién es el consumo que muestra este store.
    public let provider: Provider

    public private(set) var state: State = .loading
    public private(set) var snapshot: ProviderSnapshot?
    public private(set) var gauges: [LimitGauge] = []
    public private(set) var lastUpdated: Date?

    /// Los datos vienen de la caché de un arranque anterior y todavía no se confirman contra la API.
    public private(set) var isStale = false

    /// Se llama tras cada cambio para que AppKit redibuje el ícono; `@Observable` sólo alcanza a SwiftUI.
    @ObservationIgnored public var onChange: (@MainActor () -> Void)?

    private let client: any UsageFetching
    private let defaults: UserDefaults
    private let baseInterval: TimeInterval
    private let maxInterval: TimeInterval

    private var timer: Timer?
    private var inFlight: Task<Void, Never>?
    private var currentInterval: TimeInterval

    /// La caché lleva el nombre del proveedor: con dos stores sobre los mismos `UserDefaults`, una
    /// clave compartida haría que cada uno pisara lo que guardó el otro.
    private var cacheKey: String { "cachedUsage.\(provider.id)" }
    private var cacheDateKey: String { "cachedUsageDate.\(provider.id)" }

    public init(
        provider: Provider = .claude,
        client: (any UsageFetching)? = nil,
        defaults: UserDefaults = .standard,
        baseInterval: TimeInterval = 60,
        maxInterval: TimeInterval = 300
    ) {
        self.provider = provider
        self.client = client ?? provider.makeUsageClient()
        self.defaults = defaults
        self.baseInterval = baseInterval
        self.maxInterval = maxInterval
        self.currentInterval = baseInterval
        loadCachedSnapshot()
    }

    // MARK: Ciclo de vida

    /// Primer refresco y programación del siguiente.
    public func start() {
        refresh()
        scheduleTimer(after: currentInterval)
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        inFlight?.cancel()
        inFlight = nil
    }

    /// Refresca si los datos ya tienen cierta edad; se usa al abrir el popover para no gastar una
    /// llamada cuando acabamos de consultar.
    public func refreshIfOlderThan(_ age: TimeInterval) {
        guard let lastUpdated else {
            refresh()
            return
        }
        if Date().timeIntervalSince(lastUpdated) > age { refresh() }
    }

    public func refresh() {
        Task { await refreshAndWait() }
    }

    /// Igual que `refresh()`, pero se puede esperar. Si ya hay una consulta en curso se cuelga de esa
    /// en vez de lanzar otra.
    public func refreshAndWait() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let task = Task { [weak self] () -> Void in
            await self?.performFetch()
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    private func performFetch() async {
        do {
            let response = try await client.fetch()
            apply(response)
        } catch {
            handle(error)
        }
        notifyChange()
        scheduleTimer(after: currentInterval)
    }

    private func apply(_ response: ProviderSnapshot) {
        snapshot = response
        gauges = response.gauges
        lastUpdated = Date()
        isStale = false
        state = .ready
        currentInterval = baseInterval
        cache(response)
    }

    private func handle(_ error: Error) {
        // Los datos previos siguen en pantalla: un fallo puntual no debe dejar la barra en blanco.
        if snapshot != nil { isStale = true }

        switch error {
        case UsageError.unauthorized, TokenError.notFound, TokenError.keychainDenied,
            TokenError.unsupportedAuthMode:
            state = .needsReauth
            currentInterval = maxInterval
        case UsageError.rateLimited(let retryAfter):
            currentInterval = min(max(retryAfter ?? currentInterval * 2, baseInterval), maxInterval)
            state = .failed(UsageError.rateLimited(retryAfter: retryAfter).localizedDescription)
        default:
            currentInterval = min(currentInterval * 2, maxInterval)
            let message = (error as? LocalizedError)?.errorDescription ?? "No se pudo consultar el uso."
            state = .failed(message)
        }
    }

    // MARK: Temporizador

    private func scheduleTimer(after interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Holgura generosa: el sistema agrupa despertares y esto es un indicador, no un cronómetro.
        timer.tolerance = min(10, interval / 4)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func notifyChange() {
        onChange?()
    }

    // MARK: Caché

    /// Guardar la última respuesta permite pintar cifras al arrancar en vez de un ícono vacío. Sólo
    /// contiene porcentajes y fechas: ningún dato sensible.
    private func cache(_ response: ProviderSnapshot) {
        guard let data = try? JSONEncoder().encode(response) else { return }
        defaults.set(data, forKey: cacheKey)
        defaults.set(Date(), forKey: cacheDateKey)
    }

    private func loadCachedSnapshot() {
        guard
            let data = defaults.data(forKey: cacheKey),
            let response = try? JSONDecoder().decode(ProviderSnapshot.self, from: data)
        else { return }
        snapshot = response
        gauges = response.gauges
        lastUpdated = defaults.object(forKey: cacheDateKey) as? Date
        isStale = true
    }

    // MARK: Derivados para la interfaz

    public var criticalGauge: LimitGauge? {
        gauges.max { $0.percent < $1.percent }
    }

    public var sessionGauge: LimitGauge? {
        gauges.first { $0.group == .session }
    }

    public var weeklyGauges: [LimitGauge] {
        gauges.filter { $0.group == .weekly || $0.group == .other }
    }

    /// Resumen de una línea para el tooltip de la barra de menú.
    public var tooltip: String {
        switch state {
        case .loading where snapshot == nil:
            return "Consultando el uso de \(provider.displayName)…"
        case .needsReauth:
            return "Uso de \(provider.displayName) — sesión caducada"
        default:
            let parts = gauges.map { "\($0.title) \(UsageFormat.percent($0.percent))" }
            let header = "Uso de \(provider.displayName)"
            return parts.isEmpty ? header : "\(header) — " + parts.joined(separator: " · ")
        }
    }
}
