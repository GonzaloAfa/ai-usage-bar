import Foundation

/// Cliente del endpoint que alimenta `/usage` en Claude Code y la pantalla de Uso de claude.ai.
public struct AnthropicUsageClient: UsageFetching {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private let tokenSource: any TokenProviding
    private let session: URLSession

    public init(
        tokenSource: any TokenProviding = KeychainTokenSource(),
        session: URLSession = makeUsageURLSession()
    ) {
        self.tokenSource = tokenSource
        self.session = session
    }

    public func fetch() async throws -> ProviderSnapshot {
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
        if let error = usageError(forStatus: http.statusCode, headers: http) { throw error }

        do {
            return try UsageResponse.decode(data).snapshot
        } catch {
            throw UsageError.decoding(String(describing: error))
        }
    }
}
