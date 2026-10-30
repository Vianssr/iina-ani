import Foundation

@main
struct CatalogBrowseRegression {
    static func main() async throws {
        try requestContract()
        try weekdayContract()
        try await transportContract()
        print("PASS: seasonal heat request, year rollover, all-time pagination, weekday preservation/deduplication, catalog transport/error handling")
    }

    static func requestContract() throws {
        let instant = ISO8601DateFormatter().date(from: "2026-12-31T15:30:00Z")!
        let request = try CatalogClient.trendingRequest(scope: .season, offset: 24, now: instant)
        precondition(request.httpMethod == "POST")
        precondition(request.url?.host == "api.bgm.tv" && request.url?.path == "/v0/search/subjects")
        let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        precondition(query.contains(URLQueryItem(name: "offset", value: "24")))
        precondition(query.contains(URLQueryItem(name: "limit", value: "24")))
        let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
        precondition(body["sort"] as? String == "heat" && body["keyword"] as? String == "")
        let filter = body["filter"] as! [String: Any]
        precondition(filter["type"] as? [Int] == [2])
        precondition(filter["nsfw"] as? Bool == false)
        // Japanese broadcast date has already crossed into January, despite UTC still being December.
        precondition(filter["air_date"] as? [String] == [">=2027-01-01", "<2027-04-01"])
        let autumn = ISO8601DateFormatter().date(from: "2026-10-29T08:00:00Z")!
        let autumnRequest = try CatalogClient.trendingRequest(scope: .season, offset: 0, now: autumn)
        let autumnBody = try JSONSerialization.jsonObject(with: autumnRequest.httpBody!) as! [String: Any]
        precondition((autumnBody["filter"] as! [String: Any])["air_date"] as? [String] == [">=2026-10-01", "<2027-01-01"])
        let allTime = try CatalogClient.trendingRequest(scope: .allTime, offset: 48, now: instant)
        let allBody = try JSONSerialization.jsonObject(with: allTime.httpBody!) as! [String: Any]
        precondition((allBody["filter"] as! [String: Any])["air_date"] == nil)
        do {
            _ = try CatalogClient.trendingRequest(scope: .season, offset: -1, now: instant)
            preconditionFailure("Negative pagination accepted")
        } catch {}
    }

    static func weekdayContract() throws {
        let data = Data(#"[{"weekday":{"id":2},"items":[{"id":2,"name":"Tuesday"}]},{"weekday":{"id":1},"items":[{"id":1,"name":"Monday"},{"id":1,"name":"Duplicate"}]},{"weekday":{"id":1},"items":[{"id":3,"name":"Monday two"}]},{"weekday":{"id":8},"items":[{"id":4,"name":"Invalid day"}]}]"#.utf8)
        let days = CalendarDay.normalized(try JSONDecoder().decode([CalendarDay].self, from: data))
        precondition(days.map(\.id) == [1, 2, 3, 4, 5, 6, 7])
        precondition(days[0].items.map(\.id) == [1, 3])
        precondition(days[1].items.map(\.id) == [2])
        precondition(days[2...6].allSatisfy { $0.items.isEmpty })
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let monday = ISO8601DateFormatter().date(from: "2026-10-26T08:00:00Z")!
        precondition(CalendarDay.today(at: monday, calendar: calendar) == 1)
        let sunday = calendar.date(byAdding: .day, value: 6, to: monday)!
        precondition(CalendarDay.today(at: sunday, calendar: calendar) == 7)
    }

    static func transportContract() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CatalogProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CatalogClient(session: session)
        let page = try await client.trending(scope: .allTime)
        precondition(page.total == 2 && page.data.map(\.id) == [11, 12])
        let days = try await client.calendarDays()
        precondition(days.count == 7 && days[1].items.map(\.id) == [12])
        do {
            _ = try await client.detail(999)
            preconditionFailure("HTTP failure accepted")
        } catch let error as URLError { precondition(error.code == .badServerResponse) }
    }
}

private final class CatalogProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let body: String
        let status: Int
        if url.path == "/calendar" {
            status = 200
            body = #"[{"weekday":{"id":2},"items":[{"id":12,"name":"Tuesday"}]}]"#
        } else if url.path == "/v0/search/subjects" {
            status = 200
            body = #"{"total":2,"data":[{"id":11,"name":"Popular"},{"id":12,"name":"Next"}]}"#
        } else {
            status = 503
            body = #"{"error":"unavailable"}"#
        }
        precondition(request.value(forHTTPHeaderField: "User-Agent")?.contains("IINA-ANI") == true)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
