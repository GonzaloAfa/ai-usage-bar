import Foundation

public enum UsageError: LocalizedError, Equatable {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int)
    case transport(String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            // Qué hacer para renovarla lo dice el popover, que sí sabe de qué proveedor se trata.
            return "La sesión caducó."
        case .rateLimited:
            return "Demasiadas consultas. Reintentando en un momento."
        case .http(let status):
            return "El servidor respondió \(status)."
        case .transport:
            return "Sin conexión con la API."
        case .decoding:
            return "La respuesta de uso no se pudo interpretar."
        }
    }
}

/// Consultar el consumo de un proveedor y devolverlo ya traducido.
///
/// Devuelve `ProviderSnapshot` y no la respuesta cruda a propósito: es lo único que la interfaz
/// entiende y lo que permite que Claude y Codex, con endpoints que no se parecen en nada, pasen por
/// el mismo store y las mismas vistas.
public protocol UsageFetching: Sendable {
    func fetch() async throws -> ProviderSnapshot
}

/// Lee la respuesta de un archivo en vez de la red, para iterar la interfaz sin tocar credenciales.
/// Se activa con `AI_USAGE_BAR_FIXTURE_CLAUDE=/ruta.json` o `AI_USAGE_BAR_FIXTURE_CODEX=/ruta.json`.
public struct FixtureUsageClient: UsageFetching {
    public static func environmentKey(for provider: Provider) -> String {
        "AI_USAGE_BAR_FIXTURE_\(provider.id.uppercased())"
    }

    private let url: URL
    private let provider: Provider

    public init(url: URL, provider: Provider = .claude) {
        self.url = url
        self.provider = provider
    }

    public init?(
        provider: Provider,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let path = environment[Self.environmentKey(for: provider)], !path.isEmpty else {
            return nil
        }
        self.url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        self.provider = provider
    }

    public func fetch() async throws -> ProviderSnapshot {
        do {
            return try provider.decodeFixture(try Data(contentsOf: url))
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.decoding(String(describing: error))
        }
    }
}

/// La sesión que usan todos los clientes: efímera, sin caché en disco y con un plazo corto. Es un
/// indicador de barra de menú; si la red no responde en diez segundos, mejor reintentar luego.
public func makeUsageURLSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 10
    configuration.waitsForConnectivity = false
    return URLSession(configuration: configuration)
}

/// Traduce el estado HTTP a un error del dominio.
///
/// Es común a los dos proveedores y no mira el cuerpo de la respuesta a propósito: cuando
/// `chatgpt.com` rechaza una consulta devuelve una página HTML, no JSON.
func usageError(forStatus status: Int, headers: HTTPURLResponse) -> UsageError? {
    switch status {
    case 200:
        return nil
    case 401, 403:
        return .unauthorized
    case 429:
        let retryAfter = headers.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
        return .rateLimited(retryAfter: retryAfter)
    default:
        return .http(status)
    }
}
