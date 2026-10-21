import Foundation
import Alamofire
@testable import IINA_ANI

@main
enum BangumiServiceRegression {
    static func main() async throws {
        try await paginationCacheCalendarAndOfflineIdentity()
        try await legacyCalendarStatistics()
        try await episodeNumberCacheBackfill()
        try await cancellationAndSchemaFailure()
        try trendingParser()
        try await trendingCacheRefreshFailureAndCancellation()
        try await trendingPaginationContracts()
        try await subjectIntroductionCovers()
        try await mediaClassification()
        try await subjectExtrasAndLegacyCache()
        try await commentsPaginationCacheAndRejection()
        try await extrasAndCommentsInFlightCancellation()
        try await collectionStatusRequests()
        try await collectionHTTPEmptyResponses()
        try await onlineCollectionPagination()
        print("Bangumi service regressions passed")
    }

    private static func onlineCollectionPagination() async throws {
        let suite = "iina-online-collection-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let account = SiteAccount(id: UUID(), sourceID: "bangumi", displayName: "Own account", enabled: true, status: .valid)
        defaults.set(try JSONEncoder().encode([account]), forKey: "site-account-metadata-v1")
        preferences.setDefaultAccountID(account.id, for: "bangumi")
        let accounts = SiteAccounts(preferences: preferences, keychainService: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubTransport()
        let service = BangumiService(cache: makeCache(root), accounts: accounts, transport: { try await stub.send($0) })
        await stub.configure { request in
            try require(request.httpMethod == "GET", "online import must never write remotely")
            if request.url!.path == "/v0/me" { return (Data(#"{"id":7}"#.utf8), 200) }
            try require(request.url!.path == "/v0/users/7/collections", "import must use the authenticated user's ID")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            try require(query.first { $0.name == "subject_type" }?.value == "2" &&
                        query.first { $0.name == "limit" }?.value == "50" &&
                        !query.contains { $0.name == "type" }, "request all five anime categories with the official maximum page size")
            let offset = Int(query.first { $0.name == "offset" }!.value!)!
            let ids: [Int]
            switch offset {
            case 0: ids = [1, 2]
            case 2: ids = [2, 3]
            case 4: ids = [4, 5]
            default: throw Failure.assertion("unexpected pagination offset")
            }
            return (try onlinePage(ids: ids, offset: offset, total: 6), 200)
        }
        let imported = try await service.onlineCollections(accountID: account.id)
        try require(imported.map(\.subjectID) == [1, 2, 3, 4, 5] &&
                    Set(imported.map(\.status)) == Set(BangumiCollectionStatus.allCases),
                    "all pages and five statuses must survive overlapping-page deduplication")
        try require(imported[0].subject.coverURL == "https://example.invalid/1.jpg" &&
                    imported[0].subject.date == "2020-01-01", "SlimSubject must retain cover and release year evidence")

        let malformedPages = [
            #"{"data":[],"total":1,"limit":2,"offset":0}"#,
            #"{"data":[],"total":0,"limit":0,"offset":0}"#,
            #"{"data":[],"total":0,"limit":2,"offset":1}"#,
            #"{"data":[],"total":-1,"limit":2,"offset":0}"#,
            #"{"results":[],"total":0,"limit":2,"offset":0}"#,
            #"{"data":[{"subject_id":1,"subject_type":2,"type":99,"subject":{"id":1,"name":"A","type":2}}],"total":1,"limit":2,"offset":0}"#,
            #"{"data":[{"subject_id":1,"subject_type":2,"type":1,"subject":{"id":2,"name":"A","type":2}}],"total":1,"limit":2,"offset":0}"#,
            #"{"data":[{"subject_id":1,"subject_type":6,"type":1,"subject":{"id":1,"name":"A","type":6}}],"total":1,"limit":2,"offset":0}"#
        ]
        for json in malformedPages {
            await stub.configure { request in
                (Data((request.url!.path == "/v0/me" ? #"{"id":7}"# : json).utf8), 200)
            }
            do {
                _ = try await service.onlineCollections(accountID: account.id)
                throw Failure.assertion("malformed collection page was accepted")
            } catch BangumiError.invalidResponse { } catch BangumiError.decoding { }
        }
        for changedTotal in [false, true] {
            await stub.configure { request in
                if request.url!.path == "/v0/me" { return (Data(#"{"id":7}"#.utf8), 200) }
                let offset = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                    .first { $0.name == "offset" }!.value!)!
                return (try onlinePage(ids: [1, 2], offset: offset, total: changedTotal && offset > 0 ? 6 : 4), 200)
            }
            do {
                _ = try await service.onlineCollections(accountID: account.id)
                throw Failure.assertion("repeated page or changing total was silently accepted")
            } catch BangumiError.invalidResponse { }
        }
        await stub.configure { request in
            if request.url!.path == "/v0/me" { return (Data(#"{"id":7}"#.utf8), 200) }
            let offset = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
                .first { $0.name == "offset" }!.value!
            return offset == "0" ? (try onlinePage(ids: [1, 2], offset: 0, total: 4), 200) : (Data(), 503)
        }
        do {
            _ = try await service.onlineCollections(accountID: account.id)
            throw Failure.assertion("failed later page returned a partial collection")
        } catch BangumiError.httpStatus(503) { }
        let changed = BangumiService(cache: makeCache(root), accounts: accounts, transport: { request in
            if request.url!.path == "/v0/me" {
                return (Data(#"{"id":7}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            try await accounts.setDefault(accountID: nil, sourceID: "bangumi")
            return (try onlinePage(ids: [1, 2], offset: 0, total: 4),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await changed.onlineCollections(accountID: account.id)
            throw Failure.assertion("account change during import was accepted")
        } catch BangumiError.account { }
        try await accounts.setDefault(accountID: account.id, sourceID: "bangumi")
        await stub.configure { _ in throw CancellationError() }
        do {
            _ = try await service.onlineCollections(accountID: account.id)
            throw Failure.assertion("cancelled online collection request succeeded")
        } catch is CancellationError { }
        await stub.configure { _ in (Data(), 401) }
        do {
            _ = try await service.onlineCollections(accountID: account.id)
            throw Failure.assertion("unauthorized online collection request succeeded")
        } catch BangumiError.httpStatus(401) { }
        let expired = try await accounts.account(accountID: account.id)
        try require(expired.status == .expired, "unauthorized online import must expire the bound account")
    }

    private static func onlinePage(ids: [Int], offset: Int, total: Int) throws -> Data {
        let records: [[String: Any]] = ids.map { id in
            ["subject_id": id, "subject_type": 2, "type": id, "private": true,
             "subject": ["id": id, "type": 2, "name": "Subject \(id)", "name_cn": "作品 \(id)",
                         "date": "2020-01-01", "short_summary": "Slim introduction",
                         "images": ["large": "https://example.invalid/\(id).jpg"]]]
        }
        return try JSONSerialization.data(withJSONObject: ["data": records, "total": total, "limit": 2, "offset": offset])
    }

    private static func collectionHTTPEmptyResponses() async throws {
        let suite = "iina-collection-http-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let account = SiteAccount(id: UUID(), sourceID: "bangumi", displayName: "Fixture", enabled: true, status: .valid)
        defaults.set(try JSONEncoder().encode([account]), forKey: "site-account-metadata-v1")
        preferences.setDefaultAccountID(account.id, for: "bangumi")
        let accounts = SiteAccounts(preferences: preferences, keychainService: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CollectionHTTPProtocol.self]
        let session = Session(configuration: configuration)
        let context = AccountHTTP.Context(accountID: account.id, sourceID: "bangumi", session: session,
                                          cookieStorage: .shared, bearerToken: nil)
        // No BangumiService transport closure: exercise AccountHTTP and Alamofire serialization.
        let service = BangumiService(cache: makeCache(root), accounts: accounts)
        try await AccountHTTP.$context.withValue(context) {
            let absent = try await service.collectionStatus(subjectID: 42, accountID: account.id)
            try require(absent == nil, "empty HTTP 404 must mean no collection, not serialization failure")
            try await service.setCollectionStatus(subjectID: 42, status: .doing, accountID: account.id)
            try await service.setCollectionStatus(subjectID: 202, status: .doing, accountID: account.id)
            for code in [403, 500, 401] {
                do {
                    try await service.setCollectionStatus(subjectID: code, status: .wish, accountID: account.id)
                    throw Failure.assertion("empty HTTP \(code) was accepted")
                } catch BangumiError.httpStatus(let actual) {
                    try require(actual == code, "empty error response lost its HTTP status")
                }
            }
        }
        let expired = try await accounts.account(accountID: account.id)
        try require(expired.status == .expired, "empty HTTP 401 must expire authorization")
        print("PASS: actual Alamofire empty 404 read, 202/204 writes, 403/500 errors and 401 expiry")
    }

    private static func collectionStatusRequests() async throws {
        try require(BangumiCollectionStatus.displayOrder.map(\.rawValue) == [1, 3, 2, 4, 5] &&
                    BangumiCollectionStatus.displayOrder.map(\.title) == ["想看", "在看", "已看", "擱置", "丟棄"],
                    "display order must not accidentally use API numeric order")
        let suite = "iina-bangumi-collection-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        let account = SiteAccount(id: UUID(), sourceID: "bangumi", displayName: "Fixture", enabled: true, status: .valid)
        defaults.set(try JSONEncoder().encode([account]), forKey: "site-account-metadata-v1")
        preferences.setDefaultAccountID(account.id, for: "bangumi")
        let accounts = SiteAccounts(preferences: preferences, keychainService: suite)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: root) }
        let stub = StubTransport()
        let service = BangumiService(cache: makeCache(root), accounts: accounts, transport: { try await stub.send($0) })
        await stub.configure { request in
            try require(request.httpMethod == "POST" && request.url!.path == "/v0/users/-/collections/42",
                        "collection write must use official upsert endpoint")
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Int]
            try require(body == ["type": 3] && request.value(forHTTPHeaderField: "Content-Type") == "application/json",
                        "type-only body must preserve remote tags, rating, comment, privacy and episode progress")
            return (Data(), 204)
        }
        try await service.setCollectionStatus(subjectID: 42, status: .doing, accountID: account.id)
        await stub.configure { _ in (Data(), 202) }
        try await service.setCollectionStatus(subjectID: 42, status: .doing, accountID: account.id)
        let record = #"{"subject_id":42,"subject_type":2,"type":2,"rate":9,"tags":["keep"],"comment":"keep","private":true,"ep_status":5,"vol_status":0,"updated_at":"2026-10-15T00:00:00Z"}"#
        await stub.configure { request in
            try require(request.httpMethod == "GET", "reading collection must not modify it")
            switch request.url!.path {
            case "/v0/me": return (Data(#"{"id":7}"#.utf8), 200)
            case "/v0/users/7/collections/42": return (Data(record.utf8), 200)
            default: throw Failure.assertion("unexpected collection read endpoint")
            }
        }
        let remote = try await service.collectionStatus(subjectID: 42, accountID: account.id)
        try require(remote == .collected, "read authenticated user's exact subject record")
        await stub.configure { request in
            request.url!.path == "/v0/me" ? (Data(#"{"id":7}"#.utf8), 200) : (Data(), 404)
        }
        let absent = try await service.collectionStatus(subjectID: 42, accountID: account.id)
        try require(absent == nil, "missing remote record is unclassified, not a fabricated status")
        for json in [#"{"subject_id":43,"type":1}"#, #"{"subject_id":42,"type":99}"#, #"{"subject_id":42}"#] {
            await stub.configure { request in
                request.url!.path == "/v0/me" ? (Data(#"{"id":7}"#.utf8), 200) : (Data(json.utf8), 200)
            }
            do {
                _ = try await service.collectionStatus(subjectID: 42, accountID: account.id)
                throw Failure.assertion("malformed or wrong-subject collection was accepted")
            } catch BangumiError.invalidResponse { } catch BangumiError.decoding { }
        }
        for code in [200, 201, 203, 206, 400, 403, 404, 500] {
            await stub.configure { _ in (Data(), code) }
            do {
                try await service.setCollectionStatus(subjectID: 42, status: .wish, accountID: account.id)
                throw Failure.assertion("unsupported collection write response was reported successful")
            } catch BangumiError.httpStatus(let actual) {
                try require(actual == code, "write must preserve HTTP failure code")
            } catch BangumiError.invalidResponse {
                try require((200..<300).contains(code), "only unexpected 2xx should be response-shape failure")
            }
        }
        await stub.failRequests()
        do {
            try await service.setCollectionStatus(subjectID: 42, status: .wish, accountID: account.id)
            throw Failure.assertion("offline write succeeded")
        } catch BangumiError.network { }
        await stub.configure { _ in throw CancellationError() }
        do {
            try await service.setCollectionStatus(subjectID: 42, status: .wish, accountID: account.id)
            throw Failure.assertion("cancelled write succeeded")
        } catch is CancellationError { }
        let changed = BangumiService(cache: makeCache(root), accounts: accounts, transport: { request in
            try await accounts.setDefault(accountID: nil, sourceID: "bangumi")
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!)
        })
        do {
            try await changed.setCollectionStatus(subjectID: 42, status: .wish, accountID: account.id)
            throw Failure.assertion("account-changed response was accepted")
        } catch BangumiError.account { }
        try await accounts.setDefault(accountID: account.id, sourceID: "bangumi")
        await stub.configure { _ in (Data(), 401) }
        do {
            try await service.setCollectionStatus(subjectID: 42, status: .wish, accountID: account.id)
            throw Failure.assertion("unauthorized write succeeded")
        } catch BangumiError.httpStatus(401) { }
        let expired = try await accounts.account(accountID: account.id)
        try require(expired.status == .expired, "HTTP 401 must invalidate authenticated account state")
        do {
            _ = try await service.collectionAccountID()
            throw Failure.assertion("expired account may not authorize collection operations")
        } catch BangumiError.account { }
    }

    private static func legacyCalendarStatistics() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-calendar-stats-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let stub = StubTransport()
        let service = BangumiService(cache: makeCache(root), accounts: accounts, transport: { try await stub.send($0) })
        // /calendar omits rating.rank and exposes only collection.doing, unlike /v0/subjects.
        let json = #"[{"weekday":{"id":2},"items":[{"id":505550,"type":2,"name":"Dark Machine The Animation","air_date":"2026-10-13","rating":{"score":7.8,"total":4,"count":{"8":1}},"collection":{"doing":350}}]}]"#
        await stub.configure { _ in (Data(json.utf8), 200) }
        let result = try await service.calendar()
        let day = result.value[0]
        let subject = day.items[0]
        try require(day.weekday == 2 && day.items.map(\.id) == [505550] && subject.date == "2026-10-13", "legacy calendar schedules remain available with partial statistics")
        try require(subject.rating?.rank == nil && subject.rating?.score == 7.8 && subject.rating?.total == 4 && subject.rating?.count["8"] == 1, "unranked calendar subjects retain their published rating without inventing a rank")
        try require(subject.collection?.doing == 350 && subject.collection?.wish == nil && subject.collection?.collect == nil && subject.collection?.onHold == nil && subject.collection?.dropped == nil, "omitted collection statistics stay unknown, not zero")
        await stub.failRequests()
        let cached = try await service.calendar()
        try require(cached.origin == .cache && cached.value == result.value, "persisted calendar cache retains partial statistics and the schedule offline")
    }

    private static func subjectExtrasAndLegacyCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-extras-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = makeCache(root), stub = StubTransport()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = BangumiService(cache: cache, accounts: accounts, transport: { try await stub.send($0) }, now: { clock.value })
        let subjectJSON = #"{"id":42,"type":2,"name":"Original","summary":"Subject synopsis","infobox":[{"key":"导演","value":"Director"},{"key":"别名","value":[{"k":"英文名","v":"Alternate"}]}],"tags":[{"name":"科幻","count":15}],"meta_tags":["TV"],"rating":{"score":8.4,"rank":12,"total":123,"count":{"8":23}},"collection":{"wish":1,"collect":2,"doing":3,"on_hold":4,"dropped":5}}"#
        let listJSON = #"[{"id":7,"name":"Character","summary":"Short introduction","relation":"主角","actors":[{"id":90,"name":"Voice actor","images":{"medium":"https://lain.bgm.tv/actor.jpg"}}]},{"id":8,"name":"Supporting","summary":"Available short summary","relation":"配角","actors":[]}]"#
        let detailJSON = #"{"id":7,"name":"Character","summary":"Full character biography, not merely a name.","infobox":[{"key":"简体中文名","value":"角色中文名"},{"key":"性别","value":"女"}],"images":{"large":"https://lain.bgm.tv/character.jpg"}}"#
        let relationsJSON = #"[{"id":43,"type":2,"name":"Sequel","name_cn":"续作","relation":"续集","images":{"large":"https://lain.bgm.tv/sequel.jpg"}}]"#
        await stub.configure { request in
            switch request.url!.path {
            case "/v0/subjects/42": return (Data(subjectJSON.utf8), 200)
            case "/v0/subjects/42/characters": return (Data(listJSON.utf8), 200)
            case "/v0/characters/7": return (Data(detailJSON.utf8), 200)
            case "/v0/characters/8": return (Data(), 503)
            case "/v0/subjects/42/subjects": return (Data(relationsJSON.utf8), 200)
            default: throw Failure.assertion("Unexpected extras endpoint")
            }
        }
        let extras = try await service.subjectExtras(subjectID: 42)
        let subject = extras.subject.value!
        try require(subject.summary == "Subject synopsis" && subject.infobox.first?.value.displayText == "Director", "full subject infobox and synopsis survive decoding")
        try require(subject.tags.first?.count == 15 && subject.metaTags == ["TV"] && subject.rating?.score == 8.4 && subject.rating?.count["8"] == 23 && subject.collection?.onHold == 4, "tags, rating distribution, and collection statistics are preserved")
        let encodedSubject = try JSONEncoder().encode(subject)
        let roundTrip = try JSONDecoder().decode(BangumiSubject.self, from: encodedSubject)
        try require(roundTrip == subject, "extended subject survives persistent payload round trip")
        let characters = extras.characters.value!
        try require(characters.count == 2 && characters[0].title == "角色中文名" && characters[0].summary.hasPrefix("Full character biography") && characters[0].relation == "主角" && characters[0].actors.first?.name == "Voice actor", "full character details merge with relation and voice actors")
        try require(characters[0].infobox.count == 2 && characters[0].coverURL?.hasSuffix("character.jpg") == true, "character biography includes infobox and portrait")
        try require(characters[1].summary == "Available short summary" && characters[1].introductionFailure != nil && extras.characters.failure != nil && extras.subject.failure == nil && extras.relations.failure == nil, "one character failure preserves other details and section independence")
        try require(extras.relations.value?.first?.title == "续作" && extras.relations.value?.first?.relation == "续集", "subject relation semantics and localized title are retained")
        await stub.failRequests()
        let cached = try await service.subjectExtras(subjectID: 42)
        try require(cached.subject.origin == .cache && cached.relations.origin == .cache && cached.characters.value?.first?.summary == characters[0].summary, "successful sections and biographies are independently cached")
        clock.advance(by: BangumiService.cacheLifetime + 1)
        let stale = try await service.subjectExtras(subjectID: 42)
        try require(stale.subject.origin == .staleCache && stale.subject.failure != nil && stale.characters.origin == .staleCache && stale.characters.value?.first?.summary == characters[0].summary, "offline expired sections retain cached details with independent failure")
        let isolated = try await service.subjectExtras(subjectID: 42, accountID: UUID())
        try require(isolated.subject.value == nil && isolated.subject.failure != nil && isolated.characters.value == nil, "extras caches remain account-isolated")
        await stub.configure { request in
            if request.url!.path == "/v0/subjects/44" { return (Data(subjectJSON.replacingOccurrences(of: "42", with: "44").utf8), 200) }
            return (Data(), 503)
        }
        let partial = try await service.subjectExtras(subjectID: 44)
        try require(partial.subject.value?.id == 44 && partial.subject.failure == nil && partial.characters.value == nil && partial.characters.failure != nil && partial.relations.failure != nil, "whole character/relation endpoint failures cannot hide subject metadata")

        // An actual pre-expansion disk payload omits all newly introduced fields.
        let legacy = #"{"value":{"subject":{"id":45,"name":"Legacy","name_cn":"旧缓存","type":2,"aliases":["Old alias"],"summary":"Saved synopsis"},"episodes":[],"fetchedAt":"2027-01-15T08:00:00Z"},"fetchedAt":"2027-01-15T08:00:00Z"}"#
        let directory = cache.metadataRoot.appendingPathComponent("bangumi-v1/guest")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("subject-45.json"))
        await stub.failRequests()
        let old = try await service.metadata(subjectID: 45, forceRefresh: true)
        try require(old.origin == .staleCache && old.value.subject.title == "旧缓存" && old.value.subject.aliases == ["Old alias"] && old.value.subject.infobox.isEmpty && old.value.subject.tags.isEmpty && old.value.subject.rating == nil, "pre-expansion metadata disk cache stays readable and offline-usable")
    }

    private static func episodeNumberCacheBackfill() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-episode-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = makeCache(root), stub = StubTransport()
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = BangumiService(cache: cache, accounts: accounts, transport: { try await stub.send($0) }, now: { clock.value })
        let oldEpisodesJSON = #"[{"id":900,"type":0,"sort":25,"name":"First"},{"id":901,"type":0,"sort":26,"ep":null,"name":"Second"},{"id":902,"type":1,"sort":0.5,"name":"Special"}]"#
        let oldEpisodes = try JSONDecoder().decode([BangumiEpisode].self, from: Data(oldEpisodesJSON.utf8))
        let legacy = BangumiMetadata(subject: BangumiSubject(id: 42, name: "Saved season", type: 2),
                                     episodes: oldEpisodes, fetchedAt: clock.value.addingTimeInterval(-60))
        try require(legacy.needsEpisodeNumberRefresh && legacy.episodes.allSatisfy { $0.ep == nil }, "absent and null ep remain unknown rather than inheriting sort or array position")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyData = try encoder.encode(legacy)
        let decodedLegacy = try decoder.decode(BangumiMetadata.self, from: legacyData)
        try require(decodedLegacy.needsEpisodeNumberRefresh && decodedLegacy.episodes.allSatisfy { $0.ep == nil }, "legacy metadata round trip must still trigger numbering backfill")
        let object = try JSONSerialization.jsonObject(with: legacyData) as! [String: Any]
        let encodedEpisodes = object["episodes"] as! [[String: Any]]
        try require(encodedEpisodes.allSatisfy { $0["ep"] == nil }, "encoding old episodes omits unknown ep rather than inventing a value")
        let directory = cache.metadataRoot.appendingPathComponent("bangumi-v1/guest")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let record = MetadataCacheFixture(value: decodedLegacy, fetchedAt: decodedLegacy.fetchedAt)
        try encoder.encode(record).write(to: directory.appendingPathComponent("subject-42.json"))
        await stub.failRequests()
        let offline = try await service.metadata(subjectID: 42)
        try require(offline.origin == .staleCache && offline.failure != nil && offline.value == decodedLegacy && offline.fetchedAt == decodedLegacy.fetchedAt,
                    "a fresh legacy disk cache must attempt backfill and stay usable offline without pretending it has ep")
        let episodesJSON = #"{"data":[{"id":901,"type":0,"sort":26,"ep":2.5,"name":"Second"},{"id":900,"type":0,"sort":25,"ep":1,"name":"First"},{"id":902,"type":1,"sort":0.5,"name":"Special"}],"total":3,"limit":100,"offset":0}"#
        await stub.configure { request in
            switch request.url!.path {
            case "/v0/subjects/42": return (Data(#"{"id":42,"type":2,"name":"Official season"}"#.utf8), 200)
            case "/v0/episodes": return (Data(episodesJSON.utf8), 200)
            default: throw Failure.assertion("Unexpected episode backfill endpoint")
            }
        }
        let backfilled = try await service.metadata(subjectID: 42)
        let first = backfilled.value.episodes.first { $0.id == 900 }
        let second = backfilled.value.episodes.first { $0.id == 901 }
        try require(backfilled.origin == .network && backfilled.failure == nil && !backfilled.value.needsEpisodeNumberRefresh,
                    "fresh pre-ep metadata must be replaced from the official API without forceRefresh")
        try require(first?.sort == 25 && first?.ep == 1 && second?.sort == 26 && second?.ep == 2.5,
                    "official global sort and integer or fractional within-subject ep are independent, not derived from list order")
        try require(backfilled.value.episodes.first { $0.type == 1 }?.ep == nil, "specials without ep do not demand repeated main-episode backfill")
        let roundTrip = try decoder.decode(BangumiMetadata.self, from: encoder.encode(backfilled.value))
        try require(roundTrip == backfilled.value && !roundTrip.needsEpisodeNumberRefresh, "numbered JSON round trip stays eligible for fresh-cache consumers")
        await stub.failRequests()
        let reopened = BangumiService(cache: cache, accounts: accounts, transport: { try await stub.send($0) }, now: { clock.value })
        let cached = try await reopened.metadata(subjectID: 42)
        try require(cached.origin == .cache && cached.failure == nil && cached.value == roundTrip,
                    "a new service must read encoded official ep from disk and reuse the complete fresh cache offline")
        let specialsOnly = BangumiMetadata(subject: legacy.subject, episodes: [oldEpisodes[2]], fetchedAt: legacy.fetchedAt)
        let empty = BangumiMetadata(subject: legacy.subject, episodes: [], fetchedAt: legacy.fetchedAt)
        try require(!specialsOnly.needsEpisodeNumberRefresh && !empty.needsEpisodeNumberRefresh, "only main episodes lacking ep require a numbering refresh")
    }

    private struct MetadataCacheFixture: Encodable {
        let value: BangumiMetadata
        let fetchedAt: Date
    }


    private static func commentHTML(page: Int, user: String, hasNext: Bool) -> String {
        let pager = hasNext ? "<a class=p href='?page=\(page + 1)'>&rsaquo;&rsaquo;</a>" : ""
        return """
        <div id=comment_box><div class=item data-item-user='\(user)'><div class=text>
        <a class=l href='/user/\(user)'>Reader &amp; friend</a><span class='starlight stars8'></span>
        <small class=grey>看过</small><small class=grey>@ 2026-10-12 10:00</small>
        <p class=comment>A &amp; B<br>Second line</p><div class=likes_grid id='likes_grid_\(user)'></div>
        </div></div></div><div class=page_inner><strong class=p_cur>\(page)</strong>\(pager)
        <a class=p href='https://evil.example/subject/42/comments?page=\(page + 1)'>Unrelated</a></div>
        """
    }

    private static func commentsPaginationCacheAndRejection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-comments-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let stub = StubTransport(), clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = BangumiService(cache: makeCache(root), accounts: accounts, transport: { try await stub.send($0) }, now: { clock.value })
        await stub.configure { request in
            try require(request.url?.host == "bangumi.tv" && request.url?.path == "/subject/42/comments" && AccountHTTP.context == nil && request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil, "comments use public no-cookie HTML rather than a guessed API")
            let page = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }!.value!)!
            return (Data(commentHTML(page: page, user: "reader\(page)", hasNext: page == 1).utf8), 200)
        }
        let first = try await service.comments(subjectID: 42)
        try require(first.value.page == 1 && first.value.nextPage == 2 && first.value.data.count == 1, "public navigation yields the next page")
        try require(first.value.data[0].author == "Reader & friend" && first.value.data[0].text.contains("A & B") && first.value.data[0].dateText == "2026-10-12 10:00" && first.value.data[0].rating == 8 && first.value.data[0].userURL == "https://bangumi.tv/user/reader1", "comment body, author, time and rating are decoded without HTML")
        let second = try await service.comments(subjectID: 42, page: first.value.nextPage!)
        try require(second.value.page == 2 && second.value.nextPage == nil && second.value.data[0].id != first.value.data[0].id, "last page terminates and ignores off-site pager links")
        let empty = try BangumiService.parseComments("<div id=comment_box></div>", subjectID: 42, page: 1)
        try require(empty.data.isEmpty && empty.nextPage == nil, "a structurally valid empty comment page remains an empty success")
        for html in ["<html>Login or challenge</html>", "<div id=challenge-form></div>" + commentHTML(page: 1, user: "reader", hasNext: true), commentHTML(page: 2, user: "reader", hasNext: false), "<div id=comment_box><div class=item><p class=comment>Broken author</p></div></div>"] {
            do { _ = try BangumiService.parseComments(html, subjectID: 42, page: 1); throw Failure.assertion("invalid or wrong-page comment response accepted") }
            catch BangumiError.invalidResponse {}
        }
        await stub.failRequests()
        let cached = try await service.comments(subjectID: 42, page: 2)
        try require(cached.origin == .cache && cached.value == second.value && cached.fetchedAt == second.fetchedAt, "comment cache is per-page with original obtained time")
        let stale = try await service.comments(subjectID: 42, forceRefresh: true)
        try require(stale.origin == .staleCache && stale.failure != nil && stale.value == first.value, "failed forced refresh preserves prior public comments")
        await stub.configure { _ in (Data("<div id=challenge-form></div>".utf8), 200) }
        let rejected = try await service.comments(subjectID: 42, forceRefresh: true)
        try require(rejected.origin == .staleCache && rejected.failure != nil && rejected.value == first.value, "verification page cannot replace comments cache")
        do { _ = try await service.comments(subjectID: 43); throw Failure.assertion("comment cache leaked to another subject") }
        catch BangumiError.invalidResponse {}
        await stub.configure { _ in throw CancellationError() }
        do { _ = try await service.comments(subjectID: 42, forceRefresh: true); throw Failure.assertion("comments swallowed cancellation") }
        catch is CancellationError {}
        clock.advance(by: BangumiService.cacheLifetime + 1)
        await stub.configure { _ in (Data(commentHTML(page: 1, user: "refreshed", hasNext: false).utf8), 200) }
        let refreshed = try await service.comments(subjectID: 42)
        try require(refreshed.origin == .network && refreshed.value.data.first?.userURL.hasSuffix("refreshed") == true, "expired public comments are refreshed")
    }

    private static func extrasAndCommentsInFlightCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-extras-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        for isComments in [false, true] {
            let probe = CancellationProbe()
            let service = BangumiService(cache: makeCache(root), accounts: accounts, transport: { _ in
                await probe.started()
                try await Task.sleep(for: .seconds(60))
                throw Failure.assertion("cancelled detail transport must not finish")
            })
            let task = Task {
                if isComments { _ = try await service.comments(subjectID: 42) }
                else { _ = try await service.subjectExtras(subjectID: 42) }
            }
            await probe.waitUntilStarted()
            task.cancel()
            do { _ = try await task.value; throw Failure.assertion("in-flight detail cancellation became a section or stale failure") }
            catch is CancellationError {}
        }
    }


    private static func mediaClassification() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("classification-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let stub = StubTransport()
        let service = BangumiService(cache: makeCache(root), accounts: accounts, transport: { try await stub.send($0) })
        let empty = try await service.classifyMedia(title: " \n\t")
        try require(empty.kind == .unknown && empty.provenance == "bangumi.title.empty", "empty title requires no network")
        let matching = BangumiSubject(id: 42, name: "Unrelated", nameCN: "另一名稱", aliases: ["ＣＡＦÉ Show"], type: 2)
        let fuzzy = BangumiSubject(id: 7, name: "Cafe Show sequel", type: 2)
        await stub.configure { request in
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            try require((body["filter"] as? [String: [Int]])?["type"] == [2], "classification search filters animation")
            let offset = Int(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "offset" }!.value!)!
            let subjects = offset == 0 ? [fuzzy] : [matching, matching]
            return (try JSONEncoder().encode(BangumiPage(data: subjects, total: 3, limit: 100, offset: offset)), 200)
        }
        let unique = try await service.classifyMedia(title: " cafe\nshow ")
        try require(unique.kind == .anime && unique.provenance.hasSuffix("unique"), "normalized alias on later page and repeated ID are unique")
        for subject in [BangumiSubject(id: 1, name: "Exact", type: 2), BangumiSubject(id: 1, name: "Other", nameCN: "Exact", type: 2)] {
            await stub.configure { _ in (try JSONEncoder().encode(BangumiPage(data: [subject], total: 1, limit: 100, offset: 0)), 200) }
            let result = try await service.classifyMedia(title: "Exact")
            try require(result.kind == .anime, "native and Chinese titles match exactly")
        }
        await stub.configure { _ in
            let subjects = [BangumiSubject(id: 1, name: "Exact", type: 2), BangumiSubject(id: 2, name: "Exact", type: 2)]
            return (try JSONEncoder().encode(BangumiPage(data: subjects, total: 2, limit: 100, offset: 0)), 200)
        }
        let ambiguous = try await service.classifyMedia(title: "Exact")
        try require(ambiguous.kind == .unknown && ambiguous.provenance.hasSuffix("ambiguous"), "different matching IDs are ambiguous")
        await stub.configure { _ in
            let subjects = [fuzzy, BangumiSubject(id: 8, name: "Cafe Show", type: 6)]
            return (try JSONEncoder().encode(BangumiPage(data: subjects, total: 2, limit: 100, offset: 0)), 200)
        }
        let absent = try await service.classifyMedia(title: "Cafe Show")
        try require(absent.kind == .video && absent.provenance.hasSuffix("no-match"), "fuzzy and live-action hits do not prove animation")
        await stub.configure { request in
            if request.url!.query!.contains("offset=0") {
                return (try JSONEncoder().encode(BangumiPage(data: [matching], total: 2, limit: 100, offset: 0)), 200)
            }
            throw URLError(.notConnectedToInternet)
        }
        let failed = try await service.classifyMedia(title: "Cafe Show")
        try require(failed.kind == .unknown && failed.provenance.hasSuffix("failed"), "later-page failure cannot confirm a first-page match")
        await stub.configure { _ in throw CancellationError() }
        do { _ = try await service.classifyMedia(title: "Exact"); throw Failure.assertion("classification swallowed cancellation") }
        catch is CancellationError {}
        await stub.configure { _ in throw URLError(.cancelled) }
        do { _ = try await service.classifyMedia(title: "Exact"); throw Failure.assertion("classification swallowed transport cancellation") }
        catch is CancellationError {}
        for id in ["didahd", "kanba", "youknow", "rebo"] {
            try require(MediaClassification.requiresBangumiLookup(for: SourceItemRef(sourceID: id, pageURL: "https://example.invalid/video", kind: .video)), "mixed source uses secondary classification")
        }
        for (id, url, expected) in [("bilibili", "https://www.bilibili.com/bangumi/play/ep1", true),
                                     ("bilibili", "https://www.bilibili.com/video/BV1", false),
                                     ("bilibili", "https://evil.example/bangumi/play/ep1", false),
                                     ("jibi", "https://jibi.cc/video/1", false)] {
            try require(MediaClassification.requiresBangumiLookup(for: SourceItemRef(sourceID: id, pageURL: url, kind: .video)) == expected, "secondary lookup respects source and native route")
        }
    }

    private static func subjectIntroductionCovers() async throws {
        let html = """
        <img class="cover" src="https://lain.bgm.tv/pic/cover/l/unrelated.jpg">
        <div id="bangumiInfo"><div class="infobox"><a class="thickbox cover" href="//lain.bgm.tv/pic/cover/l/original.jpg">
        <img class="cover" src="//lain.bgm.tv/r/400/pic/cover/l/small.jpg"></a></div></div>
        """
        let parsed = try BangumiService.parseSubjectCover(html)
        try require(parsed == "https://lain.bgm.tv/pic/cover/l/original.jpg", "subject introduction selects original cover rather than thumbnail or unrelated image")
        let imageOnly = "<div id=bangumiInfo><div class=infobox><img class=cover src='http://lain.bgm.tv/r/400/pic/cover/l/small.jpg'></div></div>"
        let parsedImageOnly = try BangumiService.parseSubjectCover(imageOnly)
        try require(parsedImageOnly == "https://lain.bgm.tv/r/400/pic/cover/l/small.jpg", "cover image remains usable when no original link is provided, with HTTPS normalization")
        for page in ["<html>Challenge</html>", "<img class=cover src='//lain.bgm.tv/pic/cover/l/avatar.jpg'>",
                     html.replacingOccurrences(of: "lain.bgm.tv", with: "evil.example"),
                     "<div id=challenge-form></div>" + html] {
            do { _ = try BangumiService.parseSubjectCover(page); throw Failure.assertion("invalid cover page accepted") }
            catch BangumiError.invalidResponse {}
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subject-cover-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let stub = StubTransport(), clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let service = BangumiService(cache: makeCache(root), accounts: accounts, transport: { try await stub.send($0) }, now: { clock.value })
        await stub.configure { request in
            try require(request.url?.absoluteString == "https://bangumi.tv/subject/42" && AccountHTTP.context == nil, "cover is fetched from the public subject introduction")
            return (Data(html.utf8), 200)
        }
        let original = try await service.subjectCover(subjectID: 42)
        await stub.failRequests()
        let fresh = try await service.subjectCover(subjectID: 42)
        try require(fresh.origin == .cache && fresh.value == original.value, "fresh original-cover cache avoids unavailable network")
        let stale = try await service.subjectCover(subjectID: 42, forceRefresh: true)
        try require(stale.origin == .staleCache && stale.failure != nil && stale.value == original.value, "failed forced refresh preserves prior subject cover with error")
        do { _ = try await service.subjectCover(subjectID: 43); throw Failure.assertion("cover cache leaked across subjects") }
        catch BangumiError.network {}
        clock.advance(by: BangumiService.cacheLifetime + 1)
        await stub.configure { _ in (Data(html.replacingOccurrences(of: "original.jpg", with: "updated.jpg").utf8), 200) }
        let updated = try await service.subjectCover(subjectID: 42)
        try require(updated.origin == .network && updated.value.hasSuffix("updated.jpg"), "expired subject cover refreshes")
        await stub.configure { _ in (Data("<html>Challenge</html>".utf8), 200) }
        let invalid = try await service.subjectCover(subjectID: 42, forceRefresh: true)
        try require(invalid.failure != nil && invalid.value == updated.value, "challenge page cannot overwrite cached cover")
        await stub.configure { _ in throw CancellationError() }
        do { _ = try await service.subjectCover(subjectID: 42, forceRefresh: true); throw Failure.assertion("cancellation became stale success") }
        catch is CancellationError {}
    }

    private static func paginationCacheCalendarAndOfflineIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iina-bangumi-regression-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root)
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let stub = StubTransport()
        let service = BangumiService(cache: cache, accounts: accounts, transport: { request in try await stub.send(request) }, now: { clock.value })
        let accountID = UUID()
        let subjectData = try JSONSerialization.data(withJSONObject: [
            "id": 42, "type": 2, "name": "Original", "name_cn": "中文名", "date": "1997-02-28",
            "eps": 13, "total_episodes": 24, "summary": "Synopsis", "images": ["large": "https://lain.bgm.tv/cover.jpg"],
            "infobox": [["key": "别名", "value": [["v": "Alias"], ["k": "英文名", "v": "Alternate"]]], ["key": "platform", "value": "TV"]]
        ])
        var episodeObjects: [[String: Any]] = []
        episodeObjects.reserveCapacity(101)
        for index in 0..<101 {
            let episodeID = index + 1
            let episodeType: Int = index == 100 ? 1 : 0
            let episodeSort: Double = index == 100 ? 0.5 : Double(episodeID)
            let episodeName = "Episode \(episodeID)"
            let localizedName = "集数 \(episodeID)"
            let episode: [String: Any] = [
                "id": episodeID, "type": episodeType, "sort": episodeSort, "ep": episodeSort,
                "name": episodeName, "name_cn": localizedName, "airdate": "2026-04-01", "duration": "24m"
            ]
            episodeObjects.append(episode)
        }
        let episodePages = try [0, 100].reduce(into: [Int: Data]()) { pages, offset in
            let page = Array(episodeObjects.dropFirst(offset).prefix(100))
            pages[offset] = try JSONSerialization.data(withJSONObject: ["data": page, "total": 101, "limit": 100, "offset": offset])
        }
        let searchData = try JSONSerialization.data(withJSONObject: ["data": [["id": 42, "type": 2, "name": "Original", "name_cn": "中文名"]], "total": 51, "limit": 10, "offset": 20])
        let emptySearchData = try JSONSerialization.data(withJSONObject: ["data": [], "total": 0, "limit": 20, "offset": 0])
        let calendarData = try JSONSerialization.data(withJSONObject: [[
            "weekday": ["id": 1, "en": "Mon", "cn": "星期一", "ja": "月曜日"],
            "items": [["id": 42, "type": 2, "name": "Original", "name_cn": "中文名", "date": "1997-02-28", "total_episodes": 24]]
        ]])
        await stub.configure { request in
            let url = request.url!
            if url.absoluteString == "https://api.bgm.tv/calendar" { return (calendarData, 200) }
            if url.path.hasSuffix("/search/subjects") {
                let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
                let keyword = body?["keyword"] as? String
                if keyword == "No results" { return (emptySearchData, 200) }
                if keyword == "Server failure" { return (Data(), 503) }
                return (searchData, 200)
            }
            if url.path.hasSuffix("/subjects/42") { return (subjectData, 200) }
            if url.path.hasSuffix("/episodes") {
                let offset = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first(where: { $0.name == "offset" })!.value!)!
                return (episodePages[offset] ?? Data(), 200)
            }
            return (Data(), 404)
        }

        let page = try await service.search(keyword: "Original", limit: 10, offset: 20, accountID: accountID)
        try require(page.total == 51 && page.offset == 20 && page.data.first?.title == "中文名", "search must retain result page boundaries and localized title")
        let empty = try await service.search(keyword: "No results", accountID: accountID)
        try require(empty.data.isEmpty && empty.total == 0, "valid empty search response must remain distinct from API failure")
        do {
            _ = try await service.search(keyword: "Server failure", accountID: accountID)
            throw Failure.assertion("non-success HTTP response must not be returned as empty search")
        } catch BangumiError.httpStatus(503) { }
        do {
            _ = try await service.search(keyword: "Original", limit: 101, accountID: accountID)
            throw Failure.assertion("out-of-range page size must be rejected")
        } catch BangumiError.invalidResponse { }

        let fetched = try await service.metadata(subjectID: 42, accountID: accountID)
        try require(fetched.origin == .network && fetched.failure == nil, "initial fetch must report network origin")
        try require(fetched.value.episodes.count == 101 && fetched.value.episodes.last?.type == 1, "episodes must paginate every episode type")
        try require(fetched.value.subject.aliases == ["Alias", "Alternate"] && fetched.value.subject.platform == "TV", "known infobox aliases and platform must be retained")
        try require(fetched.value.subject.episodeCount == 13 && fetched.value.subject.totalEpisodes == 24 && fetched.value.subject.date == "1997-02-28", "current API date and episode-count fields must be preserved")
        try require(fetched.value.sourceURL == "https://api.bgm.tv/v0/subjects/42", "metadata provenance must identify the official API")
        let cached = try await service.metadata(subjectID: 42, accountID: accountID)
        try require(cached.origin == .cache && cached.value.fetchedAt == fetched.value.fetchedAt, "fresh cache must persist original obtained time")
        try require(cached.value.episodes.first?.ep == 1 && !cached.value.needsEpisodeNumberRefresh, "fresh-cache fixtures retain the official within-subject number")
        let changedSubject = try JSONSerialization.data(withJSONObject: [
            "id": 42, "type": 2, "name": "Refreshed", "name_cn": "更新名", "date": "1997-02-28", "eps": 13, "total_episodes": 24
        ])
        await stub.replaceSubjectResponse(changedSubject)
        let refreshed = try await service.metadata(subjectID: 42, forceRefresh: true, accountID: accountID)
        try require(refreshed.origin == .network && refreshed.value.subject.name == "Refreshed", "forced refresh must return changed server metadata rather than cached content")

        let calendar = try await service.calendar(accountID: accountID)
        try require(calendar.origin == .network && calendar.value.first?.weekday == 1 && calendar.value.first?.items.first?.id == 42, "calendar must decode the official weekday/item structure from /calendar")
        try require(calendar.fetchedAt != nil, "calendar result must expose its original obtained time")
        let calendarCache = try await service.calendar(accountID: accountID)
        try require(calendarCache.origin == .cache && calendarCache.fetchedAt == calendar.fetchedAt, "calendar cache must preserve obtained time")

        let zeroCount = try JSONDecoder().decode(BangumiSubject.self, from: Data("{\"id\":8,\"type\":2,\"name\":\"Unknown\",\"eps\":0,\"total_episodes\":0}".utf8))
        try require(zeroCount.episodeCount == nil && zeroCount.totalEpisodes == nil, "zero counts represent unknown episode totals")
        clock.advance(by: BangumiService.cacheLifetime + 1)
        await stub.failRequests()
        let stale = try await service.metadata(subjectID: 42, accountID: accountID)
        try require(stale.origin == .staleCache && stale.failure != nil, "offline fallback must expose stale origin and operational failure")
        try require(stale.value.fetchedAt == refreshed.value.fetchedAt && stale.fetchedAt == refreshed.value.fetchedAt, "stale fallback must retain original obtained time")
        do {
            _ = try await service.metadata(subjectID: 42)
            throw Failure.assertion("guest identity must not read the selected account's cached metadata")
        } catch BangumiError.network { }
    }

    private static func cancellationAndSchemaFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iina-bangumi-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root)
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let cancelled = BangumiService(cache: cache, accounts: accounts, transport: { _ in throw CancellationError() })
        do {
            _ = try await cancelled.metadata(subjectID: 9)
            throw Failure.assertion("cancellation must propagate instead of becoming empty metadata")
        } catch is CancellationError { }

        let malformed = BangumiService(cache: cache, accounts: accounts, transport: { request in
            let body = request.url!.path.hasSuffix("/subjects/9")
                ? Data("{\"id\":9,\"name\":\"Missing type\"}".utf8)
                : Data("{\"data\":[],\"total\":0,\"limit\":100,\"offset\":0}".utf8)
            return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
        })
        do {
            _ = try await malformed.metadata(subjectID: 9)
            throw Failure.assertion("schema failure must be explicit, not an empty metadata result")
        } catch BangumiError.decoding { }
    }

    private static let trendsHTML = """
    <!doctype html><html><body><ul id="browserItemList" class="browserFull browser-list">
      <li class="item"><a class="subjectCover" href="/subject/91"><img src="//lain.bgm.tv/cover.jpg?x=1&amp;y=2"></a>
        <div class="inner"><h3><a href="/subject/91">中文 &amp; 标题</a><small class="grey">Original &amp; Title</small></h3>
        <p class="info tip">24话 / 2026年10月1日 / Staff</p></div></li>
      <li class="item"><h3><a href="https://bangumi.tv/subject/7">Only &#39;Original&#39;</a></h3></li>
      <li class="item"><h3><a href="/subject/91">Duplicate must not replace the first title</a></h3></li>
      <li class="item"><a class="subjectCover"><img src="javascript:alert(1)"></a>
        <h3><a href="//bangumi.tv/subject/23">Third</a><small class="grey">第三原名</small></h3></li>
    </ul></body></html>
    """

    private static func trendingParser() throws {
        let subjects = try BangumiService.parseTrendingSubjects(trendsHTML)
        try require(subjects.map(\.id) == [91, 7, 23], "trends must preserve page order and keep the first occurrence of each subject ID")
        try require(subjects[0].name == "Original & Title" && subjects[0].nameCN == "中文 & 标题", "small.grey is the original name and the title link is localized; entities must decode")
        try require(subjects[1].name == "Only 'Original'" && subjects[1].nameCN.isEmpty, "without small.grey the link is the only known title")
        try require(subjects[0].coverURL == "https://lain.bgm.tv/cover.jpg?x=1&y=2" && subjects[1].coverURL == nil && subjects[2].coverURL == nil, "protocol-relative covers must normalize and unsafe or missing covers must stay absent")
        try require(subjects.allSatisfy { $0.type == 2 && $0.date == nil && $0.summary == nil && $0.platform == nil && $0.episodeCount == nil && $0.totalEpisodes == nil && $0.aliases.isEmpty }, "browse entries must not fabricate API metadata or dates")
        let invalidPages = [
            "<html><title>Just a moment...</title><body>Verify you are human</body></html>",
            "<ul id='browserItemList'></ul>",
            "<ul id='browserItemList'><li class='item'>Unexpected structure</li></ul>",
            "<ul id='browserItemList'><li class='item'><h3><a href='/subject/3'> </a></h3></li></ul>"
        ]
        for html in invalidPages {
            do {
                _ = try BangumiService.parseTrendingSubjects(html)
                throw Failure.assertion("invalid/challenge/empty pages must throw rather than yield an empty catalog")
            } catch BangumiError.invalidResponse { }
        }
        for href in ["https://evil.example/subject/3", "https://bangumi.tv.evil.example/subject/3", "javascript:/subject/3", "https://user@bangumi.tv/subject/3", "/subject/0", "/subject/-3", "/subject/3/extra", "/subject/3?redirect=1", "/subject/3#fragment", "http://bangumi.tv/subject/3"] {
            let html = "<ul id='browserItemList'><li class='item'><h3><a href='\(href)'>Unsafe</a></h3></li></ul>"
            do {
                _ = try BangumiService.parseTrendingSubjects(html)
                throw Failure.assertion("unsafe subject links must not enter the catalog")
            } catch BangumiError.invalidResponse { }
        }
    }

    private static func trendingCacheRefreshFailureAndCancellation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iina-bangumi-trends-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = makeCache(root)
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let stub = StubTransport()
        let accountID = UUID()
        let service = BangumiService(cache: cache, accounts: accounts, transport: { try await stub.send($0) }, now: { clock.value })
        await stub.configure { request in
            try require(request.url?.absoluteString == "https://bangumi.tv/anime/browser/?sort=trends", "trends must request exactly the first public trends page, not a seasonal/search API")
            try require(request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil && AccountHTTP.context == nil, "public trends must not inherit credentials or an account HTTP context")
            return (Data(trendsHTML.utf8), 200)
        }
        let network = try await accounts.withSource(sourceID: "bangumi", useDefaultAccount: false) {
            guard let guest = AccountHTTP.context else { throw Failure.assertion("guest context must be bound for the isolation test") }
            let authenticated = AccountHTTP.Context(accountID: accountID, sourceID: "bangumi", session: guest.session,
                                                    cookieStorage: guest.cookieStorage, bearerToken: "offline-regression-token")
            return try await AccountHTTP.$context.withValue(authenticated) {
                try await service.trendingSubjects(accountID: accountID)
            }
        }
        try require(network.origin == .network && network.failure == nil && network.value.map(\.id) == [91, 7, 23] && network.fetchedAt == clock.value, "network trends must expose parsed page order and obtained time")
        await stub.failRequests()
        let fresh = try await service.trendingSubjects(accountID: accountID)
        try require(fresh.origin == .cache && fresh.value == network.value && fresh.fetchedAt == network.fetchedAt, "fresh cache must avoid network and preserve its obtained time")
        let forcedFailure = try await service.trendingSubjects(forceRefresh: true, accountID: accountID)
        try require(forcedFailure.origin == .staleCache && forcedFailure.failure != nil && forcedFailure.value == network.value, "forced failure may use a fresh fallback but must report stale-cache failure")
        do {
            _ = try await service.trendingSubjects(accountID: UUID())
            throw Failure.assertion("another account must not reuse the first account's trends cache")
        } catch BangumiError.network { }
        do {
            _ = try await service.trendingSubjects()
            throw Failure.assertion("guest trends must not reuse an account's trends cache")
        } catch BangumiError.network { }
        clock.advance(by: BangumiService.cacheLifetime + 1)
        let stale = try await service.trendingSubjects(accountID: accountID)
        try require(stale.origin == .staleCache && stale.failure != nil && stale.fetchedAt == network.fetchedAt, "expired cache must retain failure and original obtained time")
        await stub.configure { _ in (Data(trendsHTML.replacingOccurrences(of: "中文 &amp; 标题", with: "Refreshed").utf8), 200) }
        let refreshed = try await service.trendingSubjects(forceRefresh: true, accountID: accountID)
        try require(refreshed.origin == .network && refreshed.value[0].title == "Refreshed" && refreshed.fetchedAt == clock.value, "force refresh must replace cache and obtained time")
        await stub.configure { _ in (Data("<html>Challenge</html>".utf8), 200) }
        let challenge = try await service.trendingSubjects(forceRefresh: true, accountID: accountID)
        guard case .invalidResponse? = challenge.failure else { throw Failure.assertion("challenge fallback must retain explicit invalid-response failure") }
        try require(challenge.origin == .staleCache && challenge.value == refreshed.value, "a challenge page must not poison the cache")
        do {
            _ = try await service.trendingSubjects(accountID: UUID())
            throw Failure.assertion("challenge without cache must throw")
        } catch BangumiError.invalidResponse { }
        await stub.configure { _ in (Data(trendsHTML.utf8), 503) }
        let status = try await service.trendingSubjects(forceRefresh: true, accountID: accountID)
        try require(status.failure == .httpStatus(503) && status.origin == .staleCache, "non-success HTTP must not be parsed as a network catalog")
        do {
            _ = try await service.trendingSubjects(accountID: UUID())
            throw Failure.assertion("HTTP failure without cache must throw")
        } catch BangumiError.httpStatus(503) { }
        await stub.configure { _ in throw CancellationError() }
        for identity in [accountID, UUID()] {
            do {
                _ = try await service.trendingSubjects(forceRefresh: true, accountID: identity)
                throw Failure.assertion("cancellation must propagate with and without cached trends")
            } catch is CancellationError { }
        }
        let probe = CancellationProbe()
        let suspended = BangumiService(cache: cache, accounts: accounts, transport: { _ in
            await probe.started()
            try await Task.sleep(for: .seconds(60))
            throw Failure.assertion("cancelled transport must not finish")
        }, now: { clock.value })
        let task = Task { try await suspended.trendingSubjects(forceRefresh: true, accountID: accountID) }
        await probe.waitUntilStarted()
        task.cancel()
        do {
            _ = try await task.value
            throw Failure.assertion("in-flight task cancellation must not become stale cache")
        } catch is CancellationError { }
        let intact = try await service.trendingSubjects(accountID: accountID)
        let cancelledFresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.trendingSubjects(accountID: accountID)
        }
        do {
            _ = try await cancelledFresh.value
            throw Failure.assertion("an already-cancelled task must not return fresh cache")
        } catch is CancellationError { }
        try require(intact.origin == .cache && intact.value == refreshed.value, "failed refresh and cancellation must leave the prior cache intact")
    }

    private actor CancellationProbe {
        private var isStarted = false
        private var waiter: CheckedContinuation<Void, Never>?
        func started() { isStarted = true; waiter?.resume(); waiter = nil }
        func waitUntilStarted() async {
            if isStarted { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    private static func trendingPaginationContracts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bangumi-trends-pages-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (accounts, defaults, suite) = makeAccounts()
        defer { defaults.removePersistentDomain(forName: suite) }
        let stub = StubTransport(), clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let accountID = UUID()
        let service = BangumiService(cache: makeCache(root), accounts: accounts, transport: { try await stub.send($0) }, now: { clock.value })
        await stub.configure { _ in (Data(trendsHTML.utf8), 200) }
        let legacy = try await service.trendingSubjects(accountID: accountID)
        await stub.configure { request in
            let url = request.url!
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "page" })?.value.flatMap(Int.init) ?? 1
            let expected = "https://bangumi.tv/anime/browser/?sort=trends" + (page == 1 ? "" : "&page=\(page)")
            try require(url.absoluteString == expected && request.value(forHTTPHeaderField: "Accept") == "text/html", "browse pagination must keep the exact first URL and append only page=N")
            try require(AccountHTTP.context == nil && request.value(forHTTPHeaderField: "Authorization") == nil && request.value(forHTTPHeaderField: "Cookie") == nil, "each public browse page must clear inherited account credentials and context")
            return (Data(trendingPageHTML(page: page, subjectID: page < 3 ? 100 + page : nil, next: page < 3).utf8), 200)
        }
        let first = try await service.trendingPage(page: 1, accountID: accountID)
        try require(first.origin == .network && first.value.subjects.map(\.id) == [101] && first.value.hasMore, "new first-page pagination must not reinterpret or reuse the legacy subject-list cache")
        let second = try await accounts.withSource(sourceID: "bangumi", useDefaultAccount: false) {
            guard let guest = AccountHTTP.context else { throw Failure.assertion("guest HTTP context must be bound") }
            let authenticated = AccountHTTP.Context(accountID: accountID, sourceID: "bangumi", session: guest.session,
                cookieStorage: guest.cookieStorage, bearerToken: "offline-regression-token")
            return try await AccountHTTP.$context.withValue(authenticated) {
                try await service.trendingPage(page: 2, accountID: accountID)
            }
        }
        try require(second.value.subjects.map(\.id) == [102] && second.value.hasMore, "a short page with next-page pager evidence must remain pageable")
        let end = try await service.trendingPage(page: 3, accountID: accountID)
        try require(end.value.subjects.isEmpty && !end.value.hasMore && end.origin == .network, "an empty catalog without next-page evidence is a valid terminal page")
        await stub.failRequests()
        let firstCached = try await service.trendingPage(page: 1, accountID: accountID)
        let secondCached = try await service.trendingPage(page: 2, accountID: accountID)
        let endCached = try await service.trendingPage(page: 3, accountID: accountID)
        let legacyCached = try await service.trendingSubjects(accountID: accountID)
        try require(firstCached.origin == .cache && firstCached.value == first.value && firstCached.fetchedAt == first.fetchedAt &&
            secondCached.value == second.value && endCached.value == end.value && legacyCached.value == legacy.value,
            "per-page and legacy caches must remain independent, including empty terminal pages and obtained times")
        for (page, identity) in [(4, accountID), (2, UUID()), (2, nil)] {
            do {
                _ = try await service.trendingPage(page: page, accountID: identity)
                throw Failure.assertion("uncached pages or identities must not reuse another cache")
            } catch BangumiError.network { }
        }
        let forced = try await service.trendingPage(page: 2, forceRefresh: true, accountID: accountID)
        try require(forced.origin == .staleCache && forced.failure != nil && forced.value == second.value && forced.fetchedAt == second.fetchedAt,
            "forced-refresh failure must retain only this page's payload, hasMore and obtained time")
        clock.advance(by: BangumiService.cacheLifetime + 1)
        let expired = try await service.trendingPage(page: 2, accountID: accountID)
        try require(expired.origin == .staleCache && expired.failure != nil && expired.fetchedAt == second.fetchedAt, "expired pagination cache must expose refresh failure")
        await stub.configure { _ in (Data(trendingPageHTML(page: 2, subjectID: 202, next: false).utf8), 200) }
        let refreshed = try await service.trendingPage(page: 2, forceRefresh: true, accountID: accountID)
        try require(refreshed.origin == .network && refreshed.value.subjects.map(\.id) == [202] && !refreshed.value.hasMore && refreshed.fetchedAt == clock.value,
            "a nonempty final page must refresh both data and hasMore")
        for html in ["<html>Challenge</html>", "<form id=challenge-form></form><ul id=browserItemList></ul>",
            trendingPageHTML(page: 1, subjectID: 999, next: true), trendingPageHTML(page: 2, subjectID: nil, next: true),
            "<ul id=browserItemList><li class=item>Broken</li></ul>"] {
            await stub.configure { _ in (Data(html.utf8), 200) }
            let fallback = try await service.trendingPage(page: 2, forceRefresh: true, accountID: accountID)
            guard case .invalidResponse? = fallback.failure else { throw Failure.assertion("invalid catalog, challenge and wrong-page evidence must remain explicit failures") }
            try require(fallback.origin == .staleCache && fallback.value == refreshed.value, "invalid refresh must not overwrite page cache")
            do {
                _ = try await service.trendingPage(page: 2, accountID: UUID())
                throw Failure.assertion("invalid HTML without this page's cache must throw")
            } catch BangumiError.invalidResponse { }
        }
        let noNextLinks = ["?sort=trends&page=1", "?sort=trends&page=4", "?sort=rank&page=3", "?page=3",
            "https://evil.example/anime/browser/?sort=trends&page=3", "/book/browser/?sort=trends&page=3",
            "?sort=trends&page=3&year=2026", "?sort=trends&page=3#fragment"]
        for href in noNextLinks {
            let html = trendingPageHTML(page: 2, subjectID: 102, next: false) + "<div class=page_inner><a class=p href='\(href)'>3</a></div>"
            await stub.configure { _ in (Data(html.utf8), 200) }
            let result = try await service.trendingPage(page: 2, forceRefresh: true, accountID: accountID)
            try require(!result.value.hasMore, "previous, skipped, unsafe or differently filtered pager links are not next-page evidence")
        }
        let outsidePager = trendingPageHTML(page: 2, subjectID: 102, next: false) + "<a class=p href='?sort=trends&page=3'>3</a>"
        await stub.configure { _ in (Data(outsidePager.utf8), 200) }
        let outside = try await service.trendingPage(page: 2, forceRefresh: true, accountID: accountID)
        try require(!outside.value.hasMore, "unrelated page links outside the pager must not extend pagination")
        await stub.configure { _ in (Data(trendingPageHTML(page: Int.max, subjectID: 102, next: false).utf8), 200) }
        let maximum = try await service.trendingPage(page: Int.max, accountID: accountID)
        try require(!maximum.value.hasMore, "maximum page must not overflow when looking for next-page evidence")
        await stub.configure { _ in (Data(), 503) }
        let status = try await service.trendingPage(page: 2, forceRefresh: true, accountID: accountID)
        try require(status.failure == .httpStatus(503) && status.origin == .staleCache, "HTTP failure must preserve per-page fallback contract")
        for page in [0, -1] {
            do {
                _ = try await service.trendingPage(page: page, accountID: accountID)
                throw Failure.assertion("nonpositive browse page must throw")
            } catch BangumiError.invalidResponse { }
        }
        await stub.configure { _ in throw CancellationError() }
        for identity in [accountID, UUID()] {
            do {
                _ = try await service.trendingPage(page: 2, forceRefresh: true, accountID: identity)
                throw Failure.assertion("pagination cancellation must never return stale cache")
            } catch is CancellationError { }
        }
        let cancelledFresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.trendingPage(page: 2, accountID: accountID)
        }
        do { _ = try await cancelledFresh.value; throw Failure.assertion("cancelled task must not return fresh page cache") }
        catch is CancellationError { }
        let probe = CancellationProbe()
        let suspended = BangumiService(cache: makeCache(root), accounts: accounts, transport: { _ in
            await probe.started()
            try await Task.sleep(for: .seconds(60))
            throw Failure.assertion("cancelled page transport must not finish")
        })
        let task = Task { try await suspended.trendingPage(page: 2, forceRefresh: true, accountID: accountID) }
        await probe.waitUntilStarted()
        task.cancel()
        do { _ = try await task.value; throw Failure.assertion("in-flight pagination cancellation must propagate") }
        catch is CancellationError { }
    }

    private static func trendingPageHTML(page: Int, subjectID: Int?, next: Bool) -> String {
        let item = subjectID.map { "<li class=item><h3><a href='/subject/\($0)'>Subject \($0)</a></h3></li>" } ?? ""
        let link = next ? "<a class=p href='?sort=trends&amp;page=\(page + 1)'>&rsaquo;&rsaquo;</a>" : ""
        return "<ul id=browserItemList>\(item)</ul><div class=page_inner><strong class=p_cur>\(page)</strong>\(link)</div>"
    }

    private static func makeCache(_ root: URL) -> ImageCacheService {
        ImageCacheService(coverAndEmoticonRoot: root.appendingPathComponent("covers"),
                          metadataRoot: root.appendingPathComponent("metadata"),
                          downloadTemporaryDirectory: root.appendingPathComponent("temporary"),
                          completedDownloadsDirectory: root.appendingPathComponent("completed"))
    }
    private static func makeAccounts() -> (SiteAccounts, UserDefaults, String) {
        let suite = "iina-bangumi-account-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (SiteAccounts(preferences: Preferences(defaults: defaults), keychainService: suite), defaults, suite)
    }
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure.assertion(message) }
    }
    private enum Failure: Error { case assertion(String) }

    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant: Date
        init(_ instant: Date) { self.instant = instant }
        var value: Date { lock.lock(); defer { lock.unlock() }; return instant }
        func advance(by interval: TimeInterval) { lock.lock(); instant = instant.addingTimeInterval(interval); lock.unlock() }
    }
    private actor StubTransport {
        typealias Handler = @Sendable (URLRequest) throws -> (Data, Int)
        private var handler: Handler?
        private var subjectResponse: Data?
        func configure(_ handler: @escaping Handler) { self.handler = handler }
        func replaceSubjectResponse(_ data: Data) { subjectResponse = data }
        func failRequests() { handler = { _ in throw URLError(.notConnectedToInternet) } }
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let url = request.url!
            let (data, status): (Data, Int)
            if url.path.hasSuffix("/subjects/42"), let subjectResponse { data = subjectResponse; status = 200 }
            else {
                guard let handler else { throw URLError(.badServerResponse) }
                (data, status) = try handler(request)
            }
            return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }
}

private final class CollectionHTTPProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let status: Int
        let data: Data
        if url.path == "/v0/me" {
            status = 200
            data = Data(#"{"id":7}"#.utf8)
        } else {
            let id = Int(url.lastPathComponent)!
            status = id == 42 ? (request.httpMethod == "POST" ? 204 : 404) : id
            data = Data()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Length": String(data.count)])!, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
