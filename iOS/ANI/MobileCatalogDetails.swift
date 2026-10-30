import Foundation
import Observation
import SwiftSoup

struct MobileCatalogTag: Decodable, Hashable, Sendable {
    let name: String
    let count: Int
}

struct MobileRelatedWork: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let name_cn: String?
    let type: Int
    let relation: String
    let images: Anime.Images?
    var anime: Anime { Anime(id: id, name: name, name_cn: name_cn, images: images) }
}

struct MobileCatalogPerson: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
    let relation: String?
    let actors: [MobileCatalogActor]?
}

struct MobileCatalogActor: Decodable, Identifiable, Sendable {
    let id: Int
    let name: String
}

struct MobilePersonDetail: Decodable, Sendable {
    let id: Int
    let name: String
    let summary: String?
    let infobox: [Entry]?

    struct Entry: Decodable, Sendable {
        let key: String
        let value: Value
    }

    enum Value: Decodable, Sendable {
        case text(String)
        case list([Item])
        case other
        struct Item: Decodable, Sendable { let k: String?; let v: String? }
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) { self = .text(text) }
            else if let items = try? container.decode([Item].self) { self = .list(items) }
            else { self = .other }
        }
        var text: String {
            switch self {
            case .text(let text): return text
            case .list(let items): return items.compactMap { item in
                guard let value = item.v else { return nil }
                return item.k.flatMap { $0.isEmpty ? nil : $0 + ": " + value } ?? value
            }.joined(separator: "、")
            case .other: return ""
            }
        }
    }
}

enum MobilePersonKind: String, Sendable { case character = "characters", person = "persons" }

struct MobileCatalogComment: Identifiable, Equatable, Sendable {
    let id: String
    let author: String
    let text: String
    let dateText: String
    let rating: Int?
}

struct MobileCatalogCommentPage: Sendable {
    let data: [MobileCatalogComment]
    let page: Int
    let nextPage: Int?
}

/// Public, read-only requests. An ephemeral session never inherits account cookies or credentials.
struct MobileCatalogDetailClient: Sendable {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()

    func tags(_ subjectID: Int) async throws -> [MobileCatalogTag] {
        struct Subject: Decodable { let id: Int; let tags: [MobileCatalogTag]? }
        let subject: Subject = try await fetch("subjects/\(subjectID)")
        guard subject.id == subjectID else { throw URLError(.badServerResponse) }
        return subject.tags ?? []
    }

    func related(_ subjectID: Int) async throws -> [MobileRelatedWork] {
        let values: [MobileRelatedWork] = try await fetch("subjects/\(subjectID)/subjects")
        return values.filter { $0.id > 0 && $0.id != subjectID }
    }

    func people(_ subjectID: Int, kind: MobilePersonKind) async throws -> [MobileCatalogPerson] {
        let values: [MobileCatalogPerson] = try await fetch("subjects/\(subjectID)/\(kind.rawValue)")
        return values.filter { $0.id > 0 }
    }

    func person(_ id: Int, kind: MobilePersonKind) async throws -> MobilePersonDetail {
        let value: MobilePersonDetail = try await fetch("\(kind.rawValue)/\(id)")
        guard value.id == id else { throw URLError(.badServerResponse) }
        return value
    }

    private func fetch<T: Decodable>(_ path: String) async throws -> T {
        let request = URLRequest(url: URL(string: "https://api.bgm.tv/v0/" + path)!)
        let data = try await data(request, accept: "application/json")
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func data(_ input: URLRequest, accept: String) async throws -> Data {
        var request = input
        request.timeoutInterval = 25
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("IINA-ANI-iOS/0.1 (https://github.com/Vianssr/iina-ani)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await Self.session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return data
    }

    /// Bangumi's public API has no short-comment listing; use the same public HTML endpoint as desktop.
    func comments(_ subjectID: Int, page: Int) async throws -> MobileCatalogCommentPage {
        guard subjectID > 0, page > 0 else { throw URLError(.badURL) }
        let url = URL(string: "https://bangumi.tv/subject/\(subjectID)/comments?page=\(page)")!
        let bytes = try await data(URLRequest(url: url), accept: "text/html")
        guard let html = String(data: bytes, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return try Self.parseComments(html, subjectID: subjectID, page: page)
    }

    static func parseComments(_ html: String, subjectID: Int, page: Int) throws -> MobileCatalogCommentPage {
        let document = try SwiftSoup.parse(html)
        guard try document.select("#challenge-form, #cf-challenge-running, .cf-browser-verification").isEmpty(),
              let box = try document.select("#comment_box").first() else { throw URLError(.cannotParseResponse) }
        // Also reject an unrelated subject's page instead of displaying it under the current work.
        guard let subjectLink = try document.select("#headerSubject h1 a[href]").first(),
              try subjectLink.attr("href") == "/subject/\(subjectID)" else { throw URLError(.badServerResponse) }
        if let current = try document.select(".page_inner .p_cur").first() {
            guard Int(try current.text()) == page else { throw URLError(.badServerResponse) }
        } else if page != 1 {
            throw URLError(.badServerResponse)
        }
        var comments: [MobileCatalogComment] = []
        var seen = Set<String>()
        for item in try box.select("#comment_box > .item") {
            guard let authorLink = try item.select(".text a.l").first(),
                  let paragraph = try item.select("p.comment").first() else { throw URLError(.cannotParseResponse) }
            let href = try authorLink.attr("href")
            guard href.hasPrefix("/user/"), !href.dropFirst(6).isEmpty,
                  !href.contains("?"), !href.contains("#") else { throw URLError(.cannotParseResponse) }
            var dateText = ""
            for date in try item.select("small.grey") {
                let value = try date.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if value.hasPrefix("@") { dateText = String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            var rating: Int?
            if let stars = try item.select(".starlight").first() {
                for token in try stars.attr("class").split(separator: " ") where token.hasPrefix("stars") {
                    if let value = Int(token.dropFirst(5)), (1...10).contains(value) { rating = value }
                }
            }
            let reactionID = try item.select(".likes_grid").first()?.attr("id") ?? ""
            // One collection comment per author/subject; use that stable identity if reaction ID is absent.
            let id = "\(subjectID):" + (reactionID.isEmpty ? href : reactionID)
            guard seen.insert(id).inserted else { continue }
            comments.append(MobileCatalogComment(id: id, author: try authorLink.text(), text: try paragraph.text(), dateText: dateText, rating: rating))
        }
        let base = URL(string: "https://bangumi.tv/subject/\(subjectID)/comments")!
        var nextPage: Int?
        for link in try document.select(".page_inner a.p[href]") {
            guard let url = URL(string: try link.attr("href"), relativeTo: base)?.absoluteURL,
                  url.scheme == "https", url.host == base.host, url.path == base.path,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  !items.contains(where: { $0.name == "interest_type" }),
                  let next = items.first(where: { $0.name == "page" })?.value.flatMap(Int.init), next == page + 1 else { continue }
            nextPage = next
        }
        return MobileCatalogCommentPage(data: comments, page: page, nextPage: comments.isEmpty ? nil : nextPage)
    }
}

/// A cancelled/replaced request cannot publish values or errors, even when a transport ignores cancellation.
@Observable @MainActor final class MobileDetailResource<Value: Sendable> {
    private(set) var value: Value?
    private(set) var loading = false
    private(set) var failed = false
    private(set) var cancelled = false
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    @discardableResult
    func load(_ operation: @escaping @Sendable () async throws -> Value) -> Task<Void, Never> {
        cancel()
        let request = UUID()
        generation = request
        loading = true
        failed = false
        cancelled = false
        let nextTask = Task {
            defer { if generation == request { loading = false; task = nil } }
            do {
                let result = try await operation()
                try Task.checkCancellation()
                guard generation == request else { return }
                value = result
            } catch {
                guard generation == request, !Task.isCancelled, !(error is CancellationError) else { return }
                failed = true
            }
        }
        task = nextTask
        return nextTask
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        if loading { cancelled = true }
        loading = false
    }

}

struct MobileCommentFeed: Sendable {
    let comments: [MobileCatalogComment]
    let nextPage: Int?

    static func appending(_ page: MobileCatalogCommentPage, to previous: MobileCommentFeed?, requestedPage: Int) throws -> MobileCommentFeed {
        guard page.page == requestedPage,
              requestedPage == (previous == nil ? 1 : previous?.nextPage),
              page.nextPage == nil || page.nextPage == requestedPage + 1 else { throw URLError(.badServerResponse) }
        var values = previous?.comments ?? []
        var seen = Set(values.map(\.id))
        values += page.data.filter { seen.insert($0.id).inserted }
        return MobileCommentFeed(comments: values, nextPage: page.data.isEmpty ? nil : page.nextPage)
    }
}
