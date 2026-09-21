import Foundation

/// Lee la sesión de Codex desde `~/.codex/auth.json`, el archivo que mantienen la app y el CLI.
///
/// A diferencia de Claude, Codex no guarda su sesión en el llavero sino en un archivo del directorio
/// del usuario. El archivo se relee en cada consulta y nunca se copia ni se escribe: Codex renueva
/// el token por su cuenta y releerlo es lo que mantiene el indicador al día. Renovarlo nosotros
/// rotaría el `refresh_token` y podría cerrarle la sesión a Codex.
public struct CodexAuthFileTokenSource: TokenProviding {
    /// Sobrescribe la lectura del archivo durante el desarrollo.
    public static let tokenEnvironmentKey = "AI_USAGE_BAR_TOKEN_CODEX"

    public static var defaultURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".codex/auth.json")
    }

    private let url: URL

    public init(url: URL = CodexAuthFileTokenSource.defaultURL) {
        self.url = url
    }

    public func currentCredentials() throws -> OAuthCredentials {
        if let override = ProcessInfo.processInfo.environment[Self.tokenEnvironmentKey],
           !override.isEmpty {
            return OAuthCredentials(accessToken: override, expiresAt: nil)
        }

        guard let data = try? Data(contentsOf: url) else { throw TokenError.notFound }
        return try Self.parse(payload: data)
    }

    public func hasSession() -> Bool {
        if let override = ProcessInfo.processInfo.environment[Self.tokenEnvironmentKey],
           !override.isEmpty {
            return true
        }
        // Basta con que el archivo exista y declare una sesión de ChatGPT: con una clave de API no
        // hay consumo de plan que mostrar.
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return false }
        return (root["auth_mode"] as? String) == "chatgpt"
    }

    /// Extrae el token de acceso y la cuenta.
    ///
    /// Ningún error de esta función incluye el contenido del archivo: los mensajes se muestran en la
    /// interfaz y no deben poder filtrar un token.
    static func parse(payload: Data) throws -> OAuthCredentials {
        guard let root = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw TokenError.malformed
        }

        // Con `apikey` el endpoint de uso no aplica: esos límites se facturan por consumo.
        if let mode = root["auth_mode"] as? String, mode != "chatgpt" {
            throw TokenError.unsupportedAuthMode
        }

        guard
            let tokens = root["tokens"] as? [String: Any],
            let token = tokens["access_token"] as? String,
            !token.isEmpty
        else {
            throw TokenError.malformed
        }

        return OAuthCredentials(
            accessToken: token,
            expiresAt: JWT.expiration(of: token),
            accountId: tokens["account_id"] as? String
        )
    }
}

/// Lo mínimo para saber cuándo caduca un token: su fecha de expiración.
///
/// El archivo de Codex no guarda un `expires_at` aparte, pero el token es un JWT y lo lleva dentro.
/// No se valida la firma —no nos corresponde ni serviría de nada aquí—: sólo se lee `exp` para no
/// gastar una llamada que ya sabemos que va a fallar. Si no se puede leer, se devuelve `nil` y que
/// hable el 401.
enum JWT {
    static func expiration(of token: String) -> Date? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }

        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)

        guard
            let data = Data(base64Encoded: base64),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = claims["exp"] as? Double
        else { return nil }

        return Date(timeIntervalSince1970: exp)
    }
}
