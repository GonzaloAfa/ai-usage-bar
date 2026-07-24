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
            return "La sesión caducó. Abre Claude Code para renovarla."
        case .rateLimited:
            return "Demasiadas consultas. Reintentando en un momento."
        case .http(let status):
            return "El servidor respondió \(status)."
        case .transport:
            return "Sin conexión con la API de Claude."
        case .decoding:
            return "La respuesta de uso no se pudo interpretar."
        }
    }
}

public protocol UsageFetching: Sendable {
    func fetch() async throws -> UsageResponse
}

/// Cliente del endpoint que alimenta `/usage` en Claude Code y la pantalla de Uso de claude.ai.
public struct APIUsageClient: UsageFetching {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let tokenSource: any TokenProviding
    private let session: URLSession

    public init(
        tokenSource: any TokenProviding = KeychainTokenSource(),
        session: URLSession = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 10
            configuration.waitsForConnectivity = false
            return URLSession(configuration: configuration)
        }()
    ) {
        self.tokenSource = tokenSource
        self.session = session
    }

    public func fetch() async throws -> UsageResponse {
        let credentials = try tokenSource.currentCredentials()

        // Si el token ya venció, no gastamos una llamada: Claude Code lo renovará en el llavero y la
        // próxima lectura tomará el nuevo. Renovarlo nosotros podría invalidar su sesión.
        if credentials.isExpired() { throw UsageError.unauthorized }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            // El mensaje del sistema puede incluir la URL, nunca el encabezado con el token.
            throw UsageError.transport((error as NSError).localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("Respuesta inesperada del servidor.")
        }

        switch http.statusCode {
        case 200:
            do {
                return try UsageResponse.decode(data)
            } catch {
                throw UsageError.decoding(String(describing: error))
            }
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.http(http.statusCode)
        }
    }
}

/// Lee la respuesta de un archivo en vez de la red, para iterar la interfaz sin tocar el llavero.
/// Se activa con `CLAUDE_USAGE_BAR_FIXTURE=/ruta/al.json`.
public struct FixtureUsageClient: UsageFetching {
    public static let environmentKey = "CLAUDE_USAGE_BAR_FIXTURE"

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment[Self.environmentKey], !path.isEmpty else { return nil }
        self.url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    public func fetch() async throws -> UsageResponse {
        do {
            return try UsageResponse.decode(try Data(contentsOf: url))
        } catch let error as UsageError {
            throw error
        } catch {
            throw UsageError.decoding(String(describing: error))
        }
    }
}

/// El cliente que corresponde al entorno: el archivo de prueba si está declarado, la API si no.
public func makeDefaultUsageClient() -> any UsageFetching {
    FixtureUsageClient() ?? APIUsageClient()
}
