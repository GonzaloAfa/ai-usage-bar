import Foundation

/// El token OAuth de Claude Code, tal como lo guarda el propio CLI.
public struct OAuthCredentials: Sendable {
    public let accessToken: String
    public let expiresAt: Date?

    public init(accessToken: String, expiresAt: Date?) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }
}

public enum TokenError: LocalizedError, Equatable {
    case notFound
    case keychainDenied
    case malformed

    public var errorDescription: String? {
        switch self {
        case .notFound:
            return "No se encontró la sesión de Claude Code. Inicia sesión con `claude` una vez."
        case .keychainDenied:
            return "macOS no autorizó la lectura del llavero. Vuelve a intentarlo y elige «Permitir siempre»."
        case .malformed:
            return "Las credenciales del llavero no tienen el formato esperado."
        }
    }
}

public protocol TokenProviding: Sendable {
    func currentCredentials() throws -> OAuthCredentials
}

/// Lee las credenciales del item `Claude Code-credentials` del llavero de inicio de sesión.
///
/// Delega en `/usr/bin/security` en vez de usar `SecItemCopyMatching` directamente: el item lo creó
/// otra aplicación, y el acceso vía la herramienta del sistema es lo que permite al usuario
/// autorizarlo una sola vez con «Permitir siempre».
///
/// El token se lee en cada consulta y nunca se guarda en disco ni en memoria más allá de la llamada:
/// Claude Code lo renueva por su cuenta en el llavero, así que releerlo es lo que mantiene la app al día.
public struct KeychainTokenSource: TokenProviding {
    /// Sobrescribe la lectura del llavero durante el desarrollo.
    public static let tokenEnvironmentKey = "CLAUDE_USAGE_BAR_TOKEN"

    private let service: String
    private let securityPath: String

    public init(
        service: String = "Claude Code-credentials",
        securityPath: String = "/usr/bin/security"
    ) {
        self.service = service
        self.securityPath = securityPath
    }

    public func currentCredentials() throws -> OAuthCredentials {
        if let override = ProcessInfo.processInfo.environment[Self.tokenEnvironmentKey],
           !override.isEmpty {
            return OAuthCredentials(accessToken: override, expiresAt: nil)
        }
        return try Self.parse(payload: try readKeychainPayload())
    }

    private func readKeychainPayload() throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = ["find-generic-password", "-s", service, "-w"]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()  // descartado: puede citar el contenido del item

        do {
            try process.run()
        } catch {
            throw TokenError.notFound
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            // 44 = item inexistente; 51 = usuario rechazó el diálogo de autorización.
            throw process.terminationStatus == 51 ? TokenError.keychainDenied : TokenError.notFound
        }
        guard !data.isEmpty else { throw TokenError.notFound }
        return data
    }

    /// Extrae sólo `claudeAiOauth`; el item guarda además tokens de servidores MCP que no nos
    /// corresponde tocar.
    ///
    /// Ningún error de esta función incluye el contenido del llavero: los mensajes se muestran en la
    /// interfaz y no deben poder filtrar un token.
    static func parse(payload: Data) throws -> OAuthCredentials {
        guard
            let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String,
            !token.isEmpty
        else {
            throw TokenError.malformed
        }

        // `expiresAt` viene en milisegundos desde epoch.
        let expiresAt = (oauth["expiresAt"] as? Double).map {
            Date(timeIntervalSince1970: $0 / 1000)
        }
        return OAuthCredentials(accessToken: token, expiresAt: expiresAt)
    }
}
