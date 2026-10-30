import Foundation

/// Mobile projection of Bangumi's public subject contract. No account or desktop dependencies.
struct Anime: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let name_cn: String?
    let images: Images?
    let summary: String?
    let date: String?
    let rating: Rating?
    let platform: String?

    init(id: Int, name: String, name_cn: String? = nil, images: Images? = nil,
         summary: String? = nil, date: String? = nil, rating: Rating? = nil, platform: String? = nil) {
        self.id = id
        self.name = name
        self.name_cn = name_cn
        self.images = images
        self.summary = summary
        self.date = date
        self.rating = rating
        self.platform = platform
    }

    var title: String { name_cn.flatMap { $0.isEmpty ? nil : $0 } ?? name }
    var cover: URL? {
        guard let value = images?.large ?? images?.common,
              var components = URLComponents(string: value) else { return nil }
        // Legacy calendar responses still use HTTP for this HTTPS-capable CDN.
        if components.host == "lain.bgm.tv", components.scheme == "http" { components.scheme = "https" }
        guard components.scheme == "https" else { return nil }
        return components.url
    }
    struct Images: Codable, Hashable, Sendable { let large: String?; let common: String? }
    struct Rating: Codable, Hashable, Sendable { let score: Double? }
}

struct CalendarDay: Decodable, Identifiable, Sendable {
    let weekday: Weekday
    let items: [Anime]
    var id: Int { weekday.id }
    struct Weekday: Decodable, Sendable { let id: Int }

    /// Always expose Monday–Sunday, including empty days; never discard the weekday grouping.
    static func normalized(_ days: [CalendarDay]) -> [CalendarDay] {
        (1...7).map { day in
            var seen = Set<Int>()
            let items = days.filter { $0.id == day }.flatMap(\.items)
                .filter { $0.id > 0 && seen.insert($0.id).inserted }
            return CalendarDay(weekday: Weekday(id: day), items: items)
        }
    }

    static func today(at date: Date = .now, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: date) + 5) % 7 + 1
    }
}

enum TrendingScope: String, CaseIterable, Identifiable {
    case season, allTime
    var id: Self { self }
    var title: String { self == .season ? "This season" : "All time" }
}

struct CatalogPage: Decodable, Sendable {
    let data: [Anime]
    let total: Int
}

struct CatalogClient: Sendable {
    var session: URLSession = .shared

    func calendarDays() async throws -> [CalendarDay] {
        let days: [CalendarDay] = try await fetch(URLRequest(url: URL(string: "https://api.bgm.tv/calendar")!))
        return CalendarDay.normalized(days)
    }

    func calendar() async throws -> [Anime] {
        let days = try await calendarDays()
        let today = CalendarDay.today()
        let ordered = days.sorted { (($0.weekday.id - today + 7) % 7) < (($1.weekday.id - today + 7) % 7) }
        var seen = Set<Int>()
        return ordered.flatMap(\.items).filter { seen.insert($0.id).inserted }
    }

    func trending(scope: TrendingScope = .season, offset: Int = 0, now: Date = .now) async throws -> CatalogPage {
        try await fetch(Self.trendingRequest(scope: scope, offset: offset, now: now))
    }

    /// Bangumi documents `heat` as collection count, not a real-time viewing counter.
    /// https://github.com/bangumi/api/blob/master/open-api/v0.yaml
    static func trendingRequest(scope: TrendingScope, offset: Int, now: Date) throws -> URLRequest {
        guard offset >= 0 else { throw URLError(.badURL) }
        var filter: [String: Any] = ["type": [2], "nsfw": false]
        if scope == .season {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
            let parts = calendar.dateComponents([.year, .month], from: now)
            let month = ((parts.month! - 1) / 3) * 3 + 1
            let start = calendar.date(from: DateComponents(year: parts.year, month: month, day: 1))!
            let end = calendar.date(byAdding: .month, value: 3, to: start)!
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            filter["air_date"] = [">=" + formatter.string(from: start), "<" + formatter.string(from: end)]
        }
        var request = URLRequest(url: URL(string: "https://api.bgm.tv/v0/search/subjects?limit=24&offset=\(offset)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["keyword": "", "sort": "heat", "filter": filter])
        return request
    }

    func search(_ keyword: String, offset: Int = 0) async throws -> CatalogPage {
        var request = URLRequest(url: URL(string: "https://api.bgm.tv/v0/search/subjects?limit=24&offset=\(offset)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["keyword": keyword, "filter": ["type": [2]]])
        return try await fetch(request)
    }

    func detail(_ id: Int) async throws -> Anime {
        try await fetch(URLRequest(url: URL(string: "https://api.bgm.tv/v0/subjects/\(id)")!))
    }

    private func fetch<T: Decodable>(_ input: URLRequest) async throws -> T {
        #if DEBUG
        if let data = SourceFixtures.catalog(input.url) { return try JSONDecoder().decode(T.self, from: data) }
        #endif
        var request = input
        request.timeoutInterval = 25
        request.setValue("IINA-ANI-iOS/0.1 (https://github.com/Vianssr/iina-ani)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

/// Only network media URLs are accepted here; Files uses security-scoped URLs separately.
enum MediaAddress {
    static func parse(_ input: String) -> URL? {
        guard let url = URL(string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

struct CatalogEpisode: Codable, Identifiable, Hashable, Sendable {
    let id: Int
    let type: Int
    let sort: Double
    let ep: Double?
    let name: String
    let name_cn: String?
    let airdate: String?
    var title: String { name_cn.flatMap { $0.isEmpty ? nil : $0 } ?? name }
    var number: String { (ep ?? sort).formatted(.number.precision(.fractionLength(0...2))) }
    var group: String {
        switch type { case 0: "Main episodes"; case 1: "Specials"; case 2: "Opening"; case 3: "Ending"; case 4: "Promotional videos"; case 5: "MAD"; default: "Other episodes" }
    }
    func isUpcoming(now: Date = Date()) -> Bool {
        guard let airdate, airdate.count == 10 else { return false }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 9 * 3600)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let date = formatter.date(from: airdate) else { return false }
        return date > now
    }
}

extension CatalogClient {
    func episodes(_ subjectID: Int) async throws -> [CatalogEpisode] {
        struct Page: Decodable { let data: [CatalogEpisode]; let total: Int }
        var result: [CatalogEpisode] = []
        var offset = 0
        var seen = Set<Int>()
        while true {
            let url = URL(string: "https://api.bgm.tv/v0/episodes?subject_id=\(subjectID)&limit=100&offset=\(offset)")!
            let page: Page = try await fetch(URLRequest(url: url))
            try Task.checkCancellation()
            let new = page.data.filter { seen.insert($0.id).inserted }
            result += new
            offset += page.data.count
            if offset >= page.total || page.data.isEmpty { break }
            guard !new.isEmpty, offset < 10_000 else { throw URLError(.badServerResponse) }
        }
        return result.sorted { $0.type == $1.type ? ($0.sort == $1.sort ? $0.id < $1.id : $0.sort < $1.sort) : $0.type < $1.type }
    }
}
