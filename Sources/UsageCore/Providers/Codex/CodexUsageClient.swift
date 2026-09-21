import Foundation

/// Cliente del endpoint que alimenta `/status` en Codex.
///
/// Autentica con la sesión de ChatGPT que Codex deja en `~/.codex/auth.json`; la cuenta va en su
/// propio encabezado porque un mismo usuario puede pertenecer a varias.
public struct CodexUsageClient: UsageFetching {
    public static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let tokenSource: any TokenProviding
    private let session: URLSession

    public init(
        tokenSource: any TokenProviding = CodexAuthFileTokenSource(),
        session: URLSession = makeUsageURLSession()
    ) {
        self.tokenSource = tokenSource
        self.session = session
    }

    public func fetch() async throws -> ProviderSnapshot {
        let credentials = try tokenSource.currentCredentials()

        // Si el token ya venció no gastamos una llamada: Codex lo renueva por su cuenta en el
        // archivo y la próxima lectura tomará el nuevo.
        if credentials.isExpired() { throw UsageError.unauthorized }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = credentials.accountId {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }
        // El backend distingue a sus clientes; identificarse evita que la consulta se lea como
        // tráfico anónimo del navegador.
        request.setValue("codex_cli_rs", forHTTPHeaderField: "originator")

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
        // Se decide por el código y no por el cuerpo: cuando `chatgpt.com` rechaza una consulta
        // devuelve una página HTML, no JSON.
        if let error = usageError(forStatus: http.statusCode, headers: http) { throw error }

        do {
            return try CodexUsageResponse.decode(data).snapshot
        } catch {
            throw UsageError.decoding(String(describing: error))
        }
    }
}
