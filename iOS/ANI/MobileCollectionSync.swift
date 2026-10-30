import Foundation

struct MobileCollectionOperation: Codable, Equatable, Sendable {
    let subjectID: Int
    let status: BangumiCollectionStatus
    let revision: UUID
    let accountID: Int?
}

struct MobileRemoteCollection: Sendable {
    let anime: Anime
    let status: BangumiCollectionStatus
}

struct MobileBangumiUser: Codable, Equatable, Sendable {
    let id: Int
    let username: String
    let nickname: String
    var displayName: String { nickname.isEmpty ? username : nickname }
}

enum MobileBangumiFailure: Error {
    case invalidToken, authentication, unavailable, invalidResponse, secureStorage, localStorage
    var message: String {
        switch self {
        case .invalidToken: "Enter a personal access token without spaces."
        case .authentication: "Your Bangumi token expired or was rejected. Sign in again; pending changes are preserved."
        case .unavailable: "Bangumi is unavailable. Your local changes are saved; retry when online."
        case .invalidResponse: "Bangumi returned an unsupported response. No partial import was saved."
        case .secureStorage: "Secure credential storage is unavailable. Your account was not changed."
        case .localStorage: "Collection changes could not be saved. Existing library data is preserved."
        }
    }
}

protocol MobileBangumiTransport: Sendable {
    func user(token: String) async throws -> MobileBangumiUser
    func collections(userID: Int, token: String) async throws -> [MobileRemoteCollection]
    func setCollection(_ operation: MobileCollectionOperation, token: String) async throws
}

/// Private requests never share the public catalog's cookies, cache, or redirects.
struct MobileBangumiClient: MobileBangumiTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    /// Allows deterministic URLProtocol fixtures without reading real credentials.
    init(session: URLSession) { self.session = session }

    func user(token: String) async throws -> MobileBangumiUser {
        let data = try await request(path: "me", token: token)
        guard let user = try? JSONDecoder().decode(MobileBangumiUser.self, from: data),
              user.id > 0, !user.username.isEmpty else { throw MobileBangumiFailure.invalidResponse }
        return user
    }

    func collections(userID: Int, token: String) async throws -> [MobileRemoteCollection] {
        struct Page: Decodable {
            let data: [Record]
            let total: Int
            let limit: Int
            let offset: Int
        }
        struct Record: Decodable {
            let subject_id: Int
            let subject_type: Int
            let type: BangumiCollectionStatus
            let subject: Anime
        }
        var records: [MobileRemoteCollection] = []
        var seen = Set<Int>()
        var offset = 0
        var total: Int?
        while true {
            try Task.checkCancellation()
            let data = try await request(path: "users/\(userID)/collections", token: token,
                query: [URLQueryItem(name: "subject_type", value: "2"), URLQueryItem(name: "limit", value: "50"),
                        URLQueryItem(name: "offset", value: String(offset))])
            guard let page = try? JSONDecoder().decode(Page.self, from: data), page.offset == offset,
                  page.total >= offset, (1...50).contains(page.limit), page.data.count <= page.limit,
                  page.data.count <= page.total - offset, total == nil || total == page.total else {
                throw MobileBangumiFailure.invalidResponse
            }
            total = page.total
            let previousCount = records.count
            for record in page.data {
                guard record.subject_id > 0, record.subject_type == 2,
                      record.subject.id == record.subject_id else { throw MobileBangumiFailure.invalidResponse }
                if seen.insert(record.subject_id).inserted {
                    records.append(MobileRemoteCollection(anime: record.subject, status: record.type))
                }
            }
            offset += page.data.count
            if offset == page.total { return records }
            guard !page.data.isEmpty, records.count > previousCount else { throw MobileBangumiFailure.invalidResponse }
        }
    }

    func setCollection(_ operation: MobileCollectionOperation, token: String) async throws {
        // POST is an upsert. Omitted progress, rating, comments, tags and privacy stay unchanged.
        _ = try await request(path: "users/-/collections/\(operation.subjectID)", token: token,
                              body: try JSONSerialization.data(withJSONObject: ["type": operation.status.rawValue]))
    }

    private func request(path: String, token: String, query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        var components = URLComponents(url: URL(string: "https://api.bgm.tv/v0/")!.appendingPathComponent(path),
                                       resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 25
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("IINA-ANI-iOS/0.1 (https://github.com/Vianssr/iina-ani)", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw MobileBangumiFailure.invalidResponse }
            if response.statusCode == 401 || response.statusCode == 403 { throw MobileBangumiFailure.authentication }
            guard (200..<300).contains(response.statusCode) else { throw MobileBangumiFailure.unavailable }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as MobileBangumiFailure { throw error }
        catch { throw MobileBangumiFailure.unavailable }
    }

    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}
