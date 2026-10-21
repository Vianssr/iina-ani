import Foundation
import Alamofire
import SwiftSoup

struct BangumiTrendingPage: Codable, Equatable, Sendable {
    let subjects: [BangumiSubject]
    let hasMore: Bool
}

actor BangumiService {
    static let shared = BangumiService()
    static let cacheLifetime: TimeInterval = 86_400
    // Status validation belongs to requestData, including errors with no response body.
    private static let rawResponseCodes = Set(100...599)
    // The deployed POST handler returns 202 after updateOrCreate succeeds; OpenAPI documents 204.
    private static let collectionWriteStatuses: Set<Int> = [202, 204]
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct CacheRecord<T: Codable & Sendable>: Codable, Sendable {
        let value: T
        let fetchedAt: Date
    }
    private struct APIPage<T: Decodable & Sendable>: Decodable, Sendable {
        let data: [T]
        let total: Int
        let limit: Int
        let offset: Int
    }
    private struct CalendarResponse: Decodable, Sendable {
        let weekday: Weekday
        let items: [BangumiSubject]
        struct Weekday: Decodable, Sendable { let id: Int }
    }

    private let cache: ImageCacheService
    private let accounts: SiteAccounts
    private let transport: Transport?
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private let baseURL = URL(string: "https://api.bgm.tv/v0")!
    private let calendarURL = URL(string: "https://api.bgm.tv/calendar")!
    private let trendsURL = URL(string: "https://bangumi.tv/anime/browser/?sort=trends")!

    init(cache: ImageCacheService = .shared, accounts: SiteAccounts = .shared,
         transport: Transport? = nil, fileManager: FileManager = .default,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.cache = cache
        self.accounts = accounts
        self.transport = transport
        self.fileManager = fileManager
        self.now = now
    }

    /// Collection records are account-owned state, never replaceable metadata cache.
    func collectionAccountID() async throws -> UUID {
        do {
            guard let account = try await accounts.currentAccount(sourceID: "bangumi"),
                  account.enabled, account.status == .valid else {
                throw BangumiError.account(String(localized: "請先登入 Bangumi；本機分類仍會保留。"))
            }
            return account.id
        } catch { throw classify(error) }
    }

    func checkCollectionAccount(_ accountID: UUID) async throws {
        guard try await collectionAccountID() == accountID else {
            throw BangumiError.account(String(localized: "Bangumi 帳號已變更；本機分類仍會保留，請重新同步。"))
        }
    }

    func collectionStatus(subjectID: Int, accountID: UUID) async throws -> BangumiCollectionStatus? {
        guard subjectID > 0 else { throw BangumiError.invalidResponse(String(localized: "Subject ID must be positive.")) }
        return try await withCollectionAccount(accountID) {
            struct User: Decodable, Sendable { let id: Int }
            struct Record: Decodable, Sendable {
                let subject_id: Int
                let type: BangumiCollectionStatus
            }
            let user = try await self.decode(User.self, request: URLRequest(url: self.baseURL.appendingPathComponent("me")))
            guard user.id > 0 else { throw BangumiError.invalidResponse(String(localized: "Invalid Bangumi user ID.")) }
            do {
                let record = try await self.decode(Record.self, request: URLRequest(
                    url: self.baseURL.appendingPathComponent("users/\(user.id)/collections/\(subjectID)")))
                guard record.subject_id == subjectID else {
                    throw BangumiError.invalidResponse(String(localized: "Collection subject ID does not match."))
                }
                return record.type
            } catch BangumiError.httpStatus(404) {
                // /me succeeded in this same authenticated scope: this subject is not collected.
                return nil
            }
        }
    }

    /// Read the authenticated user's entire anime library, including private entries and all statuses.
    /// No cache or local mutations: a failed page cannot expose a partial import.
    func onlineCollections(accountID: UUID) async throws -> [BangumiOnlineCollection] {
        try await withCollectionAccount(accountID) {
            struct User: Decodable, Sendable { let id: Int }
            let user = try await self.decode(User.self, request: URLRequest(url: self.baseURL.appendingPathComponent("me")))
            guard user.id > 0 else { throw BangumiError.invalidResponse(String(localized: "Invalid Bangumi user ID.")) }
            var result: [BangumiOnlineCollection] = []
            var seen = Set<Int>()
            var offset = 0
            var expectedTotal: Int?
            while true {
                try Task.checkCancellation()
                try await self.checkCollectionAccount(accountID)
                var components = URLComponents(url: self.baseURL.appendingPathComponent("users/\(user.id)/collections"),
                                               resolvingAgainstBaseURL: false)!
                // Omitting type requests all five collection categories. The official maximum limit is 50.
                components.queryItems = [URLQueryItem(name: "subject_type", value: "2"),
                    URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "offset", value: String(offset))]
                let page = try await self.decode(APIPage<BangumiOnlineCollection>.self, request: URLRequest(url: components.url!))
                try Task.checkCancellation()
                try await self.checkCollectionAccount(accountID)
                guard page.offset == offset, page.total >= offset, (1...50).contains(page.limit),
                      page.data.count <= page.limit, page.data.count <= page.total - offset,
                      expectedTotal == nil || expectedTotal == page.total else {
                    throw BangumiError.invalidResponse(String(localized: "Invalid collection pagination; please load again."))
                }
                expectedTotal = page.total
                let previousCount = result.count
                for record in page.data {
                    guard record.subjectID > 0, record.subjectType == 2,
                          record.subject.id == record.subjectID, record.subject.type == 2 else {
                        throw BangumiError.invalidResponse(String(localized: "Collection contains an invalid anime subject."))
                    }
                    if seen.insert(record.subjectID).inserted { result.append(record) }
                }
                guard page.data.isEmpty || result.count > previousCount else {
                    throw BangumiError.invalidResponse(String(localized: "Collection pagination repeated a page without advancing."))
                }
                offset += page.data.count
                if offset == page.total { return result }
                guard !page.data.isEmpty else {
                    throw BangumiError.invalidResponse(String(localized: "Collection pagination ended before the reported total."))
                }
            }
        }
    }

    func setCollectionStatus(subjectID: Int, status: BangumiCollectionStatus, accountID: UUID) async throws {
        guard subjectID > 0 else { throw BangumiError.invalidResponse(String(localized: "Subject ID must be positive.")) }
        try await withCollectionAccount(accountID) {
            // POST is an upsert. Every omitted field remains unchanged according to the official schema.
            // Do not send defaults for tags, rating, comment, privacy, or episode progress.
            var request = URLRequest(url: self.baseURL.appendingPathComponent("users/-/collections/\(subjectID)"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["type": status.rawValue])
            _ = try await self.requestData(request, expectedStatuses: Self.collectionWriteStatuses)
        }
    }

    private func withCollectionAccount<T: Sendable>(_ accountID: UUID,
        operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        try await checkCollectionAccount(accountID)
        do {
            let value = try await withAccount(accountID: accountID, operation: operation)
            try Task.checkCancellation()
            try await checkCollectionAccount(accountID)
            return value
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = classify(error)
            if failure == .httpStatus(401) { try? await accounts.markExpired(accountID: accountID) }
            throw failure
        }
    }

    func search(keyword: String, limit: Int = 20, offset: Int = 0, accountID: UUID? = nil, types: [Int] = []) async throws -> BangumiPage<BangumiSubject> {
        try Task.checkCancellation()
        guard !keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BangumiError.invalidResponse(String(localized: "Search keyword is empty."))
        }
        guard (1...100).contains(limit), offset >= 0 else {
            throw BangumiError.invalidResponse(String(localized: "Search limit must be 1–100 and offset must not be negative."))
        }
        let selectedID = await selectedAccountID(accountID)
        var components = URLComponents(url: baseURL.appendingPathComponent("search/subjects"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "offset", value: String(offset))]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        let filter: [String: Any] = types.isEmpty ? [:] : ["type": types]
        request.httpBody = try JSONSerialization.data(withJSONObject: ["keyword": keyword, "filter": filter])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let finalizedRequest = request
        let page: APIPage<BangumiSubject> = try await withAccount(accountID: selectedID) {
            try await self.decode(APIPage<BangumiSubject>.self, request: finalizedRequest)
        }
        return BangumiPage(data: page.data, total: page.total, limit: page.limit, offset: page.offset)
    }

    /// Title evidence only; never creates a subject association.
    func classifyMedia(title: String) async throws -> MediaClassification {
        try Task.checkCancellation()
        let normalized = Self.normalizedClassificationTitle(title)
        guard !normalized.isEmpty else {
            return MediaClassification(kind: .unknown, provenance: "bangumi.title.empty")
        }
        do {
            var offset = 0
            var matchingIDs = Set<Int>()
            while true {
                let pageOffset = offset
                let page = try await AccountHTTP.$context.withValue(nil) {
                    try await self.accounts.withSource(sourceID: "bangumi", useDefaultAccount: false) {
                        try await self.search(keyword: title, limit: 100, offset: pageOffset, types: [2])
                    }
                }
                try Task.checkCancellation()
                guard page.offset == offset, page.total >= 0, page.limit > 0, page.data.count <= page.limit else {
                    throw BangumiError.invalidResponse(String(localized: "Invalid classification search pagination."))
                }
                for subject in page.data where subject.type == 2 {
                    if Self.normalizedClassificationTitle(subject.name) == normalized ||
                       Self.normalizedClassificationTitle(subject.nameCN) == normalized ||
                       subject.aliases.contains(where: { Self.normalizedClassificationTitle($0) == normalized }) {
                        matchingIDs.insert(subject.id)
                    }
                }
                if matchingIDs.count > 1 {
                    return MediaClassification(kind: .unknown, provenance: "bangumi.title.exact.type=2.ambiguous")
                }
                if offset + page.data.count >= page.total { break }
                guard !page.data.isEmpty else {
                    throw BangumiError.invalidResponse(String(localized: "Incomplete classification search pagination."))
                }
                offset += page.data.count
            }
            return MediaClassification(kind: matchingIDs.isEmpty ? .video : .anime,
                provenance: matchingIDs.isEmpty ? "bangumi.title.exact.type=2.no-match" : "bangumi.title.exact.type=2.unique")
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return MediaClassification(kind: .unknown, provenance: "bangumi.title.search.failed")
        }
    }

    private nonisolated static func normalizedClassificationTitle(_ title: String) -> String {
        let folded = title.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                   locale: Locale(identifier: "en_US_POSIX"))
        var result = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where !CharacterSet.whitespacesAndNewlines.contains(scalar) {
            result.append(scalar)
        }
        return String(result)
    }
    func metadata(subjectID: Int, forceRefresh: Bool = false, accountID: UUID? = nil) async throws -> BangumiResult<BangumiMetadata> {
        try Task.checkCancellation()
        guard subjectID > 0 else { throw BangumiError.invalidResponse(String(localized: "Subject ID must be positive.")) }
        let selectedID = await selectedAccountID(accountID)
        let cacheURL = identityDirectory(selectedID).appendingPathComponent("subject-\(subjectID).json")
        let cached: BangumiMetadata? = try readCache(BangumiMetadata.self, from: cacheURL)
        let cacheAge = cached.map { now().timeIntervalSince($0.fetchedAt) } ?? .infinity
        if !forceRefresh, let cached, cacheAge >= 0, cacheAge < Self.cacheLifetime, !cached.needsEpisodeNumberRefresh {
            try Task.checkCancellation()
            return BangumiResult(value: cached, origin: .cache, failure: nil, fetchedAt: cached.fetchedAt)
        }
        do {
            let result = try await withAccount(accountID: selectedID) {
                let subjectRequest = URLRequest(url: self.baseURL.appendingPathComponent("subjects/\(subjectID)"))
                let subject: BangumiSubject = try await self.decode(BangumiSubject.self, request: subjectRequest)
                let episodes = try await self.allEpisodes(subjectID: subjectID)
                return BangumiMetadata(subject: subject, episodes: episodes, fetchedAt: self.now())
            }
            try writeCache(result, to: cacheURL)
            return BangumiResult(value: result, origin: .network, failure: nil, fetchedAt: result.fetchedAt)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = classify(error)
            if let cached { return BangumiResult(value: cached, origin: .staleCache, failure: failure, fetchedAt: cached.fetchedAt) }
            throw failure
        }
    }

    /// Independent sections: an unavailable relation or character endpoint never hides subject information.
    func subjectExtras(subjectID: Int, forceRefresh: Bool = false, accountID: UUID? = nil) async throws -> BangumiSubjectExtras {
        try Task.checkCancellation()
        guard subjectID > 0 else { throw BangumiError.invalidResponse(String(localized: "Subject ID must be positive.")) }
        let selectedID = await selectedAccountID(accountID)
        async let subject = detailSection {
            try await self.cachedAPIValue(BangumiSubject.self, path: "subjects/\(subjectID)",
                cacheName: "subject-info-\(subjectID)", accountID: selectedID, forceRefresh: forceRefresh)
        }
        async let characters = detailSection {
            try await self.subjectCharacters(subjectID: subjectID, accountID: selectedID, forceRefresh: forceRefresh)
        }
        async let relations = detailSection {
            try await self.cachedAPIValue([BangumiSubjectRelation].self, path: "subjects/\(subjectID)/subjects",
                cacheName: "subject-relations-\(subjectID)", accountID: selectedID, forceRefresh: forceRefresh)
        }
        let extras = try await BangumiSubjectExtras(subject: subject, characters: characters, relations: relations)
        try Task.checkCancellation()
        return extras
    }

    private func detailSection<T: Sendable>(_ operation: @Sendable () async throws -> BangumiResult<T>) async throws -> BangumiDetailSection<T> {
        do {
            let result = try await operation()
            return BangumiDetailSection(value: result.value, failure: result.failure, origin: result.origin, fetchedAt: result.fetchedAt)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            return BangumiDetailSection(value: nil, failure: classify(error), origin: nil, fetchedAt: nil)
        }
    }

    private func cachedAPIValue<T: Codable & Sendable>(_ type: T.Type, path: String, cacheName: String,
        accountID: UUID?, forceRefresh: Bool) async throws -> BangumiResult<T> {
        try Task.checkCancellation()
        let cacheURL = identityDirectory(accountID).appendingPathComponent(cacheName + ".json")
        let cached = try readCacheRecord(type, from: cacheURL)
        let age = cached.map { now().timeIntervalSince($0.fetchedAt) } ?? .infinity
        if !forceRefresh, let cached, age >= 0, age < Self.cacheLifetime {
            try Task.checkCancellation()
            return BangumiResult(value: cached.value, origin: .cache, failure: nil, fetchedAt: cached.fetchedAt)
        }
        do {
            let value = try await withAccount(accountID: accountID) {
                try await self.decode(type, request: URLRequest(url: self.baseURL.appendingPathComponent(path)))
            }
            try Task.checkCancellation()
            let record = CacheRecord(value: value, fetchedAt: now())
            try writeCacheRecord(record, to: cacheURL)
            return BangumiResult(value: value, origin: .network, failure: nil, fetchedAt: record.fetchedAt)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = classify(error)
            if let cached { return BangumiResult(value: cached.value, origin: .staleCache, failure: failure, fetchedAt: cached.fetchedAt) }
            throw failure
        }
    }

    private func subjectCharacters(subjectID: Int, accountID: UUID?, forceRefresh: Bool) async throws -> BangumiResult<[BangumiCharacter]> {
        let list = try await cachedAPIValue([BangumiCharacter].self, path: "subjects/\(subjectID)/characters",
            cacheName: "subject-characters-\(subjectID)", accountID: accountID, forceRefresh: forceRefresh)
        var characters: [BangumiCharacter] = []
        characters.reserveCapacity(list.value.count)
        var failure = list.failure
        var origin = list.origin
        var fetchedAt = list.fetchedAt
        for var character in list.value {
            try Task.checkCancellation()
            do {
                let detail = try await cachedAPIValue(BangumiCharacter.self, path: "characters/\(character.id)",
                    cacheName: "character-\(character.id)", accountID: accountID, forceRefresh: forceRefresh)
                guard detail.value.id == character.id else { throw BangumiError.invalidResponse(String(localized: "Character detail ID does not match.")) }
                var full = detail.value
                full.relation = character.relation
                full.actors = character.actors
                full.introductionFailure = detail.failure?.localizedDescription
                character = full
                if let detailFailure = detail.failure { failure = failure ?? detailFailure; origin = .staleCache }
                else if detail.origin == .network && origin != .staleCache { origin = .network }
                if let detailDate = detail.fetchedAt { fetchedAt = fetchedAt.map { min($0, detailDate) } ?? detailDate }
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let detailFailure = classify(error)
                character.introductionFailure = detailFailure.localizedDescription
                failure = failure ?? detailFailure
            }
            characters.append(character)
        }
        return BangumiResult(value: characters, origin: origin, failure: failure, fetchedAt: fetchedAt)
    }

    /// Public short comments. No account cookie or bearer token is sent to the HTML endpoint.
    func comments(subjectID: Int, page: Int = 1, forceRefresh: Bool = false) async throws -> BangumiResult<BangumiCommentsPage> {
        try Task.checkCancellation()
        guard subjectID > 0, page > 0 else { throw BangumiError.invalidResponse(String(localized: "Subject ID and comment page must be positive.")) }
        let cacheURL = identityDirectory(nil).appendingPathComponent("subject-comments-\(subjectID)-\(page).json")
        let cached = try readCacheRecord(BangumiCommentsPage.self, from: cacheURL)
        let age = cached.map { now().timeIntervalSince($0.fetchedAt) } ?? .infinity
        if !forceRefresh, let cached, age >= 0, age < Self.cacheLifetime {
            try Task.checkCancellation()
            return BangumiResult(value: cached.value, origin: .cache, failure: nil, fetchedAt: cached.fetchedAt)
        }
        do {
            var components = URLComponents(string: "https://bangumi.tv/subject/\(subjectID)/comments")!
            components.queryItems = [URLQueryItem(name: "page", value: String(page))]
            var request = URLRequest(url: components.url!)
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let publicRequest = request
            let data = try await AccountHTTP.$context.withValue(nil) { try await self.requestData(publicRequest) }
            guard let html = String(data: data, encoding: .utf8) else {
                throw BangumiError.decoding(String(localized: "Subject comments are not UTF-8 HTML."))
            }
            let value = try Self.parseComments(html, subjectID: subjectID, page: page)
            try Task.checkCancellation()
            let record = CacheRecord(value: value, fetchedAt: now())
            try writeCacheRecord(record, to: cacheURL)
            return BangumiResult(value: value, origin: .network, failure: nil, fetchedAt: record.fetchedAt)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = classify(error)
            if let cached { return BangumiResult(value: cached.value, origin: .staleCache, failure: failure, fetchedAt: cached.fetchedAt) }
            throw failure
        }
    }

    nonisolated static func parseComments(_ html: String, subjectID: Int, page: Int) throws -> BangumiCommentsPage {
        do {
            let document = try SwiftSoup.parse(html)
            guard try document.select("#challenge-form, #cf-challenge-running, .cf-browser-verification").isEmpty(),
                  let box = try document.select("#comment_box").first() else {
                throw BangumiError.invalidResponse(String(localized: "Missing Bangumi public comment list."))
            }
            if let current = try document.select(".page_inner .p_cur").first(),
               Int(try current.text()) != page {
                throw BangumiError.invalidResponse(String(localized: "Comment pagination returned a different page."))
            }
            var comments: [BangumiComment] = []
            var seen = Set<String>()
            for item in try box.select("#comment_box > .item") {
                guard let authorLink = try item.select(".text a.l").first(),
                      let paragraph = try item.select("p.comment").first() else {
                    throw BangumiError.invalidResponse(String(localized: "Incomplete Bangumi comment item."))
                }
                let href = try authorLink.attr("href")
                guard href.hasPrefix("/user/"), !href.dropFirst(6).isEmpty,
                      !href.contains("?"), !href.contains("#") else {
                    throw BangumiError.invalidResponse(String(localized: "Invalid Bangumi comment author."))
                }
                let author = try authorLink.text()
                let text = try paragraph.text()
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
                let id = reactionID.isEmpty ? "\(subjectID):\(href):\(dateText)" : "\(subjectID):\(reactionID)"
                guard seen.insert(id).inserted else { continue }
                comments.append(BangumiComment(id: id, author: author, userURL: "https://bangumi.tv" + href,
                    text: text, dateText: dateText, rating: rating))
            }
            let base = URL(string: "https://bangumi.tv/subject/\(subjectID)/comments")!
            var nextPage: Int?
            for link in try document.select(".page_inner a.p[href]") {
                guard let url = URL(string: try link.attr("href"), relativeTo: base)?.absoluteURL,
                      url.host == base.host, url.path == base.path,
                      let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                      !items.contains(where: { $0.name == "interest_type" }),
                      let next = items.first(where: { $0.name == "page" })?.value.flatMap(Int.init), next == page + 1 else { continue }
                nextPage = next
            }
            return BangumiCommentsPage(data: comments, page: page, nextPage: nextPage)
        } catch let error as BangumiError { throw error }
        catch { throw BangumiError.decoding(error.localizedDescription) }
    }


    func calendar(forceRefresh: Bool = false, accountID: UUID? = nil) async throws -> BangumiResult<[BangumiCalendarDay]> {
        try Task.checkCancellation()
        let selectedID = await selectedAccountID(accountID)
        let cacheURL = identityDirectory(selectedID).appendingPathComponent("calendar.json")
        let cached: CacheRecord<[BangumiCalendarDay]>? = try readCacheRecord([BangumiCalendarDay].self, from: cacheURL)
        let cacheAge = cached.map { now().timeIntervalSince($0.fetchedAt) } ?? .infinity
        if !forceRefresh, let cached, cacheAge >= 0, cacheAge < Self.cacheLifetime {
            try Task.checkCancellation()
            return BangumiResult(value: cached.value, origin: .cache, failure: nil, fetchedAt: cached.fetchedAt)
        }
        do {
            let response = try await withAccount(accountID: selectedID) {
                try await self.decode([CalendarResponse].self, request: URLRequest(url: self.calendarURL))
            }
            let days = response.map { BangumiCalendarDay(weekday: $0.weekday.id, items: $0.items) }
            let record = CacheRecord(value: days, fetchedAt: now())
            try writeCacheRecord(record, to: cacheURL)
            return BangumiResult(value: days, origin: .network, failure: nil, fetchedAt: record.fetchedAt)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = classify(error)
            if let cached { return BangumiResult(value: cached.value, origin: .staleCache, failure: failure, fetchedAt: cached.fetchedAt) }
            throw failure
        }
    }

    /// Main cover from the subject introduction, not the calendar API thumbnail.
    func subjectCover(subjectID: Int, forceRefresh: Bool = false) async throws -> BangumiResult<String> {
        try Task.checkCancellation()
        guard subjectID > 0 else { throw BangumiError.invalidResponse(String(localized: "Subject ID must be positive.")) }
        let cacheURL = identityDirectory(nil).appendingPathComponent("subject-cover-\(subjectID).json")
        let cached = try readCacheRecord(String.self, from: cacheURL)
        let age = cached.map { now().timeIntervalSince($0.fetchedAt) } ?? .infinity
        if !forceRefresh, let cached, age >= 0, age < Self.cacheLifetime {
            try Task.checkCancellation()
            return BangumiResult(value: cached.value, origin: .cache, failure: nil, fetchedAt: cached.fetchedAt)
        }
        do {
            var request = URLRequest(url: URL(string: "https://bangumi.tv/subject/\(subjectID)")!)
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let publicRequest = request
            let data = try await AccountHTTP.$context.withValue(nil) {
                try await self.requestData(publicRequest)
            }
            guard let html = String(data: data, encoding: .utf8) else {
                throw BangumiError.decoding(String(localized: "Subject introduction is not UTF-8 HTML."))
            }
            let cover = try Self.parseSubjectCover(html)
            try Task.checkCancellation()
            let record = CacheRecord(value: cover, fetchedAt: now())
            try writeCacheRecord(record, to: cacheURL)
            return BangumiResult(value: cover, origin: .network, failure: nil, fetchedAt: record.fetchedAt)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = classify(error)
            if let cached { return BangumiResult(value: cached.value, origin: .staleCache, failure: failure, fetchedAt: cached.fetchedAt) }
            throw failure
        }
    }

    nonisolated static func parseSubjectCover(_ html: String) throws -> String {
        let document = try SwiftSoup.parse(html)
        guard try document.select("#challenge-form, #cf-challenge-running, .cf-browser-verification").isEmpty(),
              let info = try document.select("#bangumiInfo .infobox").first() else {
            throw BangumiError.invalidResponse(String(localized: "Missing Bangumi subject introduction."))
        }
        let original = try info.select("a.thickbox.cover").first()?.attr("href")
        let thumbnail = try info.select("img.cover").first()?.attr("src")
        for candidate in [original, thumbnail] {
            guard let candidate, let normalized = trendingCoverURL(candidate),
                  var components = URLComponents(string: normalized),
                  components.host?.lowercased() == "lain.bgm.tv",
                  components.port == nil || components.port == 443,
                  components.path.contains("/pic/cover/") else { continue }
            components.scheme = "https"
            if let url = components.url { return url.absoluteString }
        }
        throw BangumiError.invalidResponse(String(localized: "Missing Bangumi subject cover."))
    }

    /// The public anime browser's first page, in Bangumi's own trending order.
    func trendingSubjects(forceRefresh: Bool = false, accountID: UUID? = nil) async throws -> BangumiResult<[BangumiSubject]> {
        try Task.checkCancellation()
        let selectedID = await selectedAccountID(accountID)
        let cacheURL = identityDirectory(selectedID).appendingPathComponent("trends.json")
        let cached = try readCacheRecord([BangumiSubject].self, from: cacheURL)
        let age = cached.map { now().timeIntervalSince($0.fetchedAt) } ?? .infinity
        if !forceRefresh, let cached, age >= 0, age < Self.cacheLifetime {
            try Task.checkCancellation()
            return BangumiResult(value: cached.value, origin: .cache, failure: nil, fetchedAt: cached.fetchedAt)
        }
        do {
            var request = URLRequest(url: trendsURL)
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let publicRequest = request
            // Public browse must not inherit an OAuth token, cookie jar or account lease.
            let data = try await AccountHTTP.$context.withValue(nil) {
                try await self.requestData(publicRequest)
            }
            guard let html = String(data: data, encoding: .utf8) else {
                throw BangumiError.decoding(String(localized: "Trending catalog is not UTF-8 HTML."))
            }
            let subjects = try Self.parseTrendingSubjects(html)
            try Task.checkCancellation()
            let record = CacheRecord(value: subjects, fetchedAt: now())
            try writeCacheRecord(record, to: cacheURL)
            return BangumiResult(value: subjects, origin: .network, failure: nil, fetchedAt: record.fetchedAt)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = classify(error)
            if let cached { return BangumiResult(value: cached.value, origin: .staleCache, failure: failure, fetchedAt: cached.fetchedAt) }
            throw failure
        }
    }

    /// Public browse pages keep separate caches from the existing first-page subject list.
    func trendingPage(page: Int, forceRefresh: Bool = false, accountID: UUID? = nil) async throws -> BangumiResult<BangumiTrendingPage> {
        try Task.checkCancellation()
        guard page > 0 else { throw BangumiError.invalidResponse(String(localized: "Trending page must be positive.")) }
        let selectedID = await selectedAccountID(accountID)
        let cacheURL = identityDirectory(selectedID).appendingPathComponent("trends-page-\(page).json")
        let cached = try readCacheRecord(BangumiTrendingPage.self, from: cacheURL)
        let age = cached.map { now().timeIntervalSince($0.fetchedAt) } ?? .infinity
        if !forceRefresh, let cached, age >= 0, age < Self.cacheLifetime {
            try Task.checkCancellation()
            return BangumiResult(value: cached.value, origin: .cache, failure: nil, fetchedAt: cached.fetchedAt)
        }
        do {
            var components = URLComponents(url: trendsURL, resolvingAgainstBaseURL: false)!
            if page > 1 { components.queryItems?.append(URLQueryItem(name: "page", value: String(page))) }
            var request = URLRequest(url: components.url!)
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            let publicRequest = request
            let data = try await AccountHTTP.$context.withValue(nil) {
                try await self.requestData(publicRequest)
            }
            guard let html = String(data: data, encoding: .utf8) else {
                throw BangumiError.decoding(String(localized: "Trending catalog is not UTF-8 HTML."))
            }
            let value = try Self.parseTrendingCatalog(html, page: page)
            try Task.checkCancellation()
            let record = CacheRecord(value: value, fetchedAt: now())
            try writeCacheRecord(record, to: cacheURL)
            return BangumiResult(value: value, origin: .network, failure: nil, fetchedAt: record.fetchedAt)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            let failure = classify(error)
            if let cached { return BangumiResult(value: cached.value, origin: .staleCache, failure: failure, fetchedAt: cached.fetchedAt) }
            throw failure
        }
    }

    nonisolated static func parseTrendingSubjects(_ html: String) throws -> [BangumiSubject] {
        try parseTrendingCatalog(html, page: nil).subjects
    }

    private nonisolated static func parseTrendingCatalog(_ html: String, page: Int?) throws -> BangumiTrendingPage {
        do {
            let document = try SwiftSoup.parse(html)
            guard try document.select("#challenge-form, #cf-challenge-running, .cf-browser-verification").isEmpty(),
                  let catalog = try document.select("ul#browserItemList").first() else {
                throw BangumiError.invalidResponse(String(localized: "Missing Bangumi trending catalog; the site may have returned a challenge page."))
            }
            if let page, let current = try document.select(".page_inner .p_cur").first(),
               Int(try current.text()) != page {
                throw BangumiError.invalidResponse(String(localized: "Trending pagination returned a different page."))
            }
            var subjects: [BangumiSubject] = []
            var seen = Set<Int>()
            for item in try catalog.select("li.item") {
                guard let titleLink = try item.select("h3 > a").first(),
                      let id = trendingSubjectID(try titleLink.attr("href")) else {
                    throw BangumiError.invalidResponse(String(localized: "Unexpected subject entry in the trending catalog."))
                }
                let title = try titleLink.text().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else {
                    throw BangumiError.invalidResponse(String(localized: "Missing subject title in the trending catalog."))
                }
                guard seen.insert(id).inserted else { continue }
                let original = try item.select("h3 > small.grey").first()?.text().trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let rawCover = try item.select("a.subjectCover img").first()?.attr("src")
                let cover = rawCover.flatMap(trendingCoverURL)
                subjects.append(BangumiSubject(id: id, name: original.isEmpty ? title : original,
                                               nameCN: original.isEmpty ? "" : title, coverURL: cover, type: 2))
            }
            var hasMore = false
            if let page, page < Int.max {
                let base = URL(string: "https://bangumi.tv/anime/browser/?sort=trends")!
                for link in try document.select(".page_inner a.p[href]") {
                    guard let url = URL(string: try link.attr("href"), relativeTo: base)?.absoluteURL,
                          url.scheme == base.scheme, url.host == base.host, url.path == base.path,
                          url.port == nil || url.port == 443, url.user == nil, url.password == nil, url.fragment == nil,
                          let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                          items.count == 2, items.first(where: { $0.name == "sort" })?.value == "trends",
                          items.first(where: { $0.name == "page" })?.value.flatMap(Int.init) == page + 1 else { continue }
                    hasMore = true
                    break
                }
            }
            guard !subjects.isEmpty || (page != nil && !hasMore) else {
                throw BangumiError.invalidResponse(String(localized: "Bangumi trending catalog contains no subjects."))
            }
            return BangumiTrendingPage(subjects: subjects, hasMore: hasMore)
        } catch let error as BangumiError {
            throw error
        } catch {
            throw BangumiError.decoding(String(localized: "Could not parse the trending catalog HTML."))
        }
    }

    private nonisolated static func trendingSubjectID(_ href: String) -> Int? {
        guard let url = URL(string: href, relativeTo: URL(string: "https://bangumi.tv")!)?.absoluteURL,
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "bangumi.tv",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "subject",
              !parts[2].isEmpty, parts[2].utf8.allSatisfy({ (48...57).contains($0) }),
              let id = Int(parts[2]), id > 0 else { return nil }
        return id
    }

    private nonisolated static func trendingCoverURL(_ source: String) -> String? {
        let normalized = source.hasPrefix("//") ? "https:" + source : source
        guard let url = URL(string: normalized), let host = url.host, !host.isEmpty,
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return nil }
        return url.absoluteString
    }

    private func allEpisodes(subjectID: Int) async throws -> [BangumiEpisode] {
        var result: [BangumiEpisode] = []
        var offset = 0
        var expectedTotal = 1
        let pageLimit = 100
        repeat {
            try Task.checkCancellation()
            var components = URLComponents(url: baseURL.appendingPathComponent("episodes"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "subject_id", value: String(subjectID)),
                                    URLQueryItem(name: "limit", value: String(pageLimit)),
                                    URLQueryItem(name: "offset", value: String(offset))]
            let page: APIPage<BangumiEpisode> = try await decode(APIPage<BangumiEpisode>.self, request: URLRequest(url: components.url!))
            expectedTotal = page.total
            guard page.offset == offset else {
                throw BangumiError.invalidResponse(String(localized: "Episodes pagination returned offset \(page.offset), expected \(offset)."))
            }
            guard !page.data.isEmpty || offset >= page.total else {
                throw BangumiError.invalidResponse(String(localized: "Episodes pagination ended before the reported total."))
            }
            result.append(contentsOf: page.data)
            offset += page.data.count
        } while offset < expectedTotal
        return result
    }

    private func selectedAccountID(_ requested: UUID?) async -> UUID? {
        if let requested { return requested }
        return await accounts.currentAccountID(sourceID: "bangumi")
    }

    private func withAccount<T: Sendable>(accountID: UUID?, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        if transport != nil { return try await operation() }
        return try await accounts.withSource(sourceID: "bangumi", accountID: accountID, useDefaultAccount: false, operation: operation)
    }

    private func decode<T: Decodable & Sendable>(_ type: T.Type, request: URLRequest) async throws -> T {
        var jsonRequest = request
        jsonRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await requestData(jsonRequest)
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw BangumiError.decoding(error.localizedDescription) }
    }

    private func requestData(_ request: URLRequest, expectedStatuses: Set<Int>? = nil) async throws -> Data {
        try Task.checkCancellation()
        var userAgentRequest = request
        userAgentRequest.setValue("IINA-ANI", forHTTPHeaderField: "User-Agent")
        let (data, response): (Data, URLResponse)
        do {
            if let transport { (data, response) = try await transport(userAgentRequest) }
            else {
                let dataRequest = AccountHTTP.request(userAgentRequest)
                let result = await withTaskCancellationHandler {
                    await dataRequest.serializingData(emptyResponseCodes: Self.rawResponseCodes).response
                } onCancel: {
                    dataRequest.cancel()
                }
                data = try result.result.get()
                guard let http = result.response else { throw BangumiError.invalidResponse(String(localized: "Missing HTTP response.")) }
                response = http
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw BangumiError.network(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw BangumiError.invalidResponse(String(localized: "Non-HTTP response.")) }
        guard (200..<300).contains(http.statusCode) else { throw BangumiError.httpStatus(http.statusCode) }
        if let expectedStatuses, !expectedStatuses.contains(http.statusCode) {
            let expected = expectedStatuses.sorted().map(String.init).joined(separator: String(localized: " or "))
            throw BangumiError.invalidResponse(String(localized: "Expected HTTP \(expected), received \(http.statusCode)."))
        }
        return data
    }

    private func classify(_ error: Error) -> BangumiError {
        if let error = error as? BangumiError { return error }
        if let error = error as? SiteAccountError { return .account(error.localizedDescription) }
        return .network(error.localizedDescription)
    }

    private func identityDirectory(_ accountID: UUID?) -> URL {
        cache.metadataRoot.appendingPathComponent("bangumi-v1", isDirectory: true)
            .appendingPathComponent(accountID?.uuidString.lowercased() ?? "guest", isDirectory: true)
    }

    private func readCache<T: Codable & Sendable>(_ type: T.Type, from url: URL) throws -> T? {
        try readCacheRecord(type, from: url)?.value
    }
    private func readCacheRecord<T: Codable & Sendable>(_ type: T.Type, from url: URL) throws -> CacheRecord<T>? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(CacheRecord<T>.self, from: Data(contentsOf: url))
        } catch { throw BangumiError.cache(error.localizedDescription) }
    }
    private func writeCache<T: Codable & Sendable>(_ value: T, to url: URL) throws {
        try writeCacheRecord(CacheRecord(value: value, fetchedAt: now()), to: url)
    }
    private func writeCacheRecord<T: Codable & Sendable>(_ record: CacheRecord<T>, to url: URL) throws {
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(record).write(to: url, options: .atomic)
            _ = try cache.evictRebuildableCacheToLimit()
        } catch { throw BangumiError.cache(error.localizedDescription) }
    }
}
