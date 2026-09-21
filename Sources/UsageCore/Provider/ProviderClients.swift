import Foundation

/// El único lugar donde se decide qué implementación corresponde a cada proveedor.
///
/// Tenerlo junto evita que la decisión se reparta por el store, la interfaz y el modo diagnóstico:
/// añadir un tercer proveedor es escribir su cliente y agregar un caso acá.
extension Provider {
    /// De dónde sale su sesión.
    public var tokenSource: any TokenProviding {
        switch id {
        case Provider.codex.id: return CodexAuthFileTokenSource()
        default: return KeychainTokenSource()
        }
    }

    /// El cliente contra la API real.
    public func makeLiveClient() -> any UsageFetching {
        switch id {
        case Provider.codex.id: return CodexUsageClient()
        default: return AnthropicUsageClient()
        }
    }

    /// Cómo se lee un archivo de prueba de este proveedor.
    func decodeFixture(_ data: Data) throws -> ProviderSnapshot {
        switch id {
        case Provider.codex.id: return try CodexUsageResponse.decode(data).snapshot
        default: return try UsageResponse.decode(data).snapshot
        }
    }

    /// El cliente que corresponde al entorno: el archivo de prueba si está declarado, la API si no.
    public func makeUsageClient(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any UsageFetching {
        FixtureUsageClient(provider: self, environment: environment) ?? makeLiveClient()
    }

    /// Si hay una sesión iniciada de este proveedor en esta máquina.
    ///
    /// Es lo que decide si aparece en la barra de menú: sin sesión no hay nada que mostrar, y un
    /// ítem permanentemente en error sería peor que no tenerlo.
    public func hasSession(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if FixtureUsageClient(provider: self, environment: environment) != nil { return true }
        return tokenSource.hasSession()
    }

    /// Los proveedores con sesión iniciada, en el orden en que se muestran.
    public static func available(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [Provider] {
        all.filter { $0.hasSession(environment: environment) }
    }
}
