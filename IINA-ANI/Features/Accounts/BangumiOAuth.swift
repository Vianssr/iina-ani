import Foundation
import Alamofire

struct BangumiOAuth: Sendable {
    static let shared = BangumiOAuth()
    static let clientID = Bundle.main.object(forInfoDictionaryKey: "BangumiClientID") as? String ?? ""
    static let redirectURI = "iina-ani://bangumi/oauth"
    private let configuredClientID: String
    private let clientSecret: String
    private let session: Session

    init(session: Session = Session(configuration: .ephemeral, redirectHandler: Redirector(behavior: .doNotFollow)),
         clientID: String = BangumiOAuth.clientID,
         clientSecret: String = Bundle.main.object(forInfoDictionaryKey: "BangumiClientSecret") as? String ?? "") {
        self.session = session
        self.configuredClientID = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.clientSecret = clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static let queryValueCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    private static let encodedRedirectURI = redirectURI.addingPercentEncoding(withAllowedCharacters: queryValueCharacters)!

    func requireConfiguration() throws {
        guard !configuredClientID.isEmpty, !clientSecret.isEmpty,
              !configuredClientID.hasPrefix("$("), !clientSecret.hasPrefix("$(") else {
            throw Failure.notConfigured
        }
    }

    struct Credentials: Codable, Sendable, Equatable {
        let accessToken: String
        let refreshToken: String
        let expiresAt: Date

    }

    struct Callback: Sendable, Equatable {
        let code: String

    }

    struct Attempt: Identifiable, Sendable {
        let id = UUID()
        var state: String { id.uuidString }
        var loginURL: URL {
            // Logged-out authorize redirects omit redirect_uri.
            // Both query levels must be fully escaped for Bangumi's login return handling.
            var authorization = URLComponents()
            authorization.path = "/oauth/authorize"
            authorization.percentEncodedQueryItems = [URLQueryItem(name: "client_id", value: BangumiOAuth.clientID),
                                                     URLQueryItem(name: "response_type", value: "code"),
                                                     URLQueryItem(name: "redirect_uri", value: BangumiOAuth.encodedRedirectURI),
                                                     URLQueryItem(name: "state", value: state)]
            var login = URLComponents(string: "https://bgm.tv/login")!
            login.percentEncodedQueryItems = [URLQueryItem(name: "chii_referer", value: authorization.string!.addingPercentEncoding(withAllowedCharacters: BangumiOAuth.queryValueCharacters)!)]
            return login.url!
        }

        func callback(from url: URL) throws -> Callback? {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "iina-ani",
                  components.host?.lowercased() == "bangumi", components.path == "/oauth" else { return nil }
            guard components.user == nil, components.password == nil, components.port == nil,
                  components.fragment == nil else { throw Failure.invalidCallback }
            var returnedState: String?
            var code: String?
            var denied = false
            for item in components.queryItems ?? [] {
                switch item.name {
                case "state":
                    guard returnedState == nil, let value = item.value else { throw Failure.invalidCallback }
                    returnedState = value
                case "code":
                    guard code == nil, let value = item.value, !value.isEmpty else { throw Failure.invalidCallback }
                    code = value
                case "error": denied = true
                case "error_description": break
                default: throw Failure.invalidCallback
                }
            }
            guard returnedState == state else { throw Failure.invalidCallback }
            if denied { throw Failure.denied }
            guard let code else { throw Failure.invalidCallback }
            return Callback(code: code)
        }
    }

    enum Failure: Error, LocalizedError {
        case invalidCallback, denied, exchangeFailed, invalidRefresh, notConfigured
        var errorDescription: String? {
            switch self {
            case .notConfigured: return NSLocalizedString("Bangumi sign-in is not configured in this build. Configure Config/Local.xcconfig and rebuild.", comment: "")
            case .invalidCallback: return NSLocalizedString("Bangumi returned an invalid authorization callback. Sign in again.", comment: "")
            case .denied: return NSLocalizedString("Bangumi authorization was denied.", comment: "")
            case .exchangeFailed: return NSLocalizedString("Bangumi could not complete authorization. Sign in again.", comment: "")
            case .invalidRefresh: return NSLocalizedString("The selected account has expired. Sign in again.", comment: "")
            }
        }
    }

    func exchange(_ callback: Callback) async throws -> Credentials {
        try await token(grantType: "authorization_code", credentialName: "code", credential: callback.code)
    }

    func refresh(_ credentials: Credentials) async throws -> Credentials {
        try await token(grantType: "refresh_token", credentialName: "refresh_token", credential: credentials.refreshToken)
    }

    private func token(grantType: String, credentialName: String, credential: String) async throws -> Credentials {
        try requireConfiguration()
        let parameters = ["grant_type": grantType, credentialName: credential,
                          "client_id": configuredClientID, "client_secret": clientSecret,
                          "redirect_uri": Self.redirectURI]
        let response = await session.request("https://bgm.tv/oauth/access_token", method: .post,
                                             parameters: parameters, encoding: URLEncoding.httpBody,
                                             headers: ["User-Agent": "IINA-ANI/1.0 (Bangumi account client)"])
            .serializingData().response
        try Task.checkCancellation()
        if let error = response.error { throw error }
        if grantType == "refresh_token", response.response?.statusCode == 400 || response.response?.statusCode == 401 {
            throw Failure.invalidRefresh
        }
        guard response.response?.statusCode == 200, let data = response.data,
              let payload = try? JSONDecoder().decode(TokenResponse.self, from: data),
              payload.token_type.lowercased() == "bearer", !payload.access_token.isEmpty,
              !payload.refresh_token.isEmpty, payload.expires_in > 0,
              !payload.access_token.contains(where: { $0.isWhitespace }) else { throw Failure.exchangeFailed }
        return Credentials(accessToken: payload.access_token, refreshToken: payload.refresh_token,
                           expiresAt: Date().addingTimeInterval(payload.expires_in))
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: TimeInterval
        let token_type: String
    }
}
