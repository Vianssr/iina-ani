import Foundation

struct TraceMoeMatch: Sendable {
    let title: String
    let filename: String
    let episode: String?
    let from: Double
    let to: Double
    let similarity: Double
    let anilistID: Int?
    let videoURL: URL?
}

enum TraceMoeSearchError: Error, LocalizedError, Equatable {
    case invalidImage, imageTooLarge, rateLimited, quotaExceeded, invalidResponse, serviceFailed, networkFailed
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            return String(localized: "Choose a screenshot to search.")
        case .imageTooLarge:
            return String(localized: "The screenshot is too large. Choose an image smaller than 25 MB.")
        case .rateLimited:
            return String(localized: "trace.moe is receiving too many searches. Wait a moment and try again.")
        case .quotaExceeded:
            return String(localized: "The trace.moe search quota or concurrent search limit has been reached. Try again later.")
        case .invalidResponse:
            return String(localized: "trace.moe returned an invalid search response.")
        case .serviceFailed, .httpStatus:
            return String(localized: "trace.moe could not complete the search. Try again later.")
        case .networkFailed:
            return String(localized: "Could not connect to trace.moe. Check your connection and try again.")
        }
    }
}

struct TraceMoeSearchService: Sendable {
    private let protocolClasses: [URLProtocol.Type]

    init() { protocolClasses = [] }

    // Uses the same isolated session and redirect policy with an offline test transport.
    init(protocolClasses: [URLProtocol.Type]) { self.protocolClasses = protocolClasses }

    func search(jpeg: Data) async throws -> [TraceMoeMatch] {
        try Task.checkCancellation()
        guard !jpeg.isEmpty else { throw TraceMoeSearchError.invalidImage }
        guard jpeg.count <= 25_000_000 else { throw TraceMoeSearchError.imageTooLarge }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        if !protocolClasses.isEmpty { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: TraceMoeRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: URL(string: "https://api.trace.moe/search?anilistInfo&cutBorders=1")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.httpShouldHandleCookies = false
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = jpeg

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError {
                throw CancellationError()
            }
            // URLSession errors can include URLs or local paths; never present them verbatim.
            throw TraceMoeSearchError.networkFailed
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TraceMoeSearchError.invalidResponse }
        switch http.statusCode {
        case 200..<300: break
        case 402: throw TraceMoeSearchError.quotaExceeded
        case 413: throw TraceMoeSearchError.imageTooLarge
        case 429: throw TraceMoeSearchError.rateLimited
        default: throw TraceMoeSearchError.httpStatus(http.statusCode)
        }

        let payload: TraceMoeResponse
        do {
            payload = try JSONDecoder().decode(TraceMoeResponse.self, from: data)
        } catch {
            throw TraceMoeSearchError.invalidResponse
        }
        if !payload.error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if payload.error.localizedCaseInsensitiveContains("quota") {
                throw TraceMoeSearchError.quotaExceeded
            }
            if payload.error.localizedCaseInsensitiveContains("concurrency") {
                throw TraceMoeSearchError.rateLimited
            }
            throw TraceMoeSearchError.serviceFailed
        }
        guard let results = payload.result else { throw TraceMoeSearchError.invalidResponse }
        return try results.map { result in
            try Task.checkCancellation()
            guard result.similarity.isFinite, (0...1).contains(result.similarity),
                  result.from.isFinite, result.to.isFinite, result.from >= 0, result.to >= result.from,
                  !result.filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TraceMoeSearchError.invalidResponse
            }
            return TraceMoeMatch(title: result.anilist?.title ?? result.filename,
                                 filename: result.filename, episode: result.episode?.text,
                                 from: result.from, to: result.to, similarity: result.similarity,
                                 anilistID: result.anilist?.id, videoURL: Self.previewURL(result.video))
        }
    }

    private static func previewURL(_ value: String?) -> URL? {
        guard let value, let url = URL(string: value), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
}

// Never forward the uploaded screenshot to a redirect destination, including another trace.moe URL.
final class TraceMoeRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct TraceMoeResponse: Decodable {
    let error: String
    let result: [TraceMoeResult]?
}

private struct TraceMoeResult: Decodable {
    let anilist: TraceMoeAnilist?
    let filename: String
    let episode: TraceMoeEpisode?
    let from: Double
    let to: Double
    let similarity: Double
    let video: String?
}

private struct TraceMoeAnilist: Decodable {
    let id: Int?
    let title: String?

    private enum CodingKeys: String, CodingKey { case id, title }
    private struct Titles: Decodable {
        let native: String?
        let romaji: String?
        let english: String?
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let number = try? value.decode(Int.self) {
            id = number > 0 ? number : nil
            title = nil
            return
        }
        let object = try decoder.container(keyedBy: CodingKeys.self)
        let number = try object.decodeIfPresent(Int.self, forKey: .id)
        id = number.flatMap { $0 > 0 ? $0 : nil }
        let titles = try object.decodeIfPresent(Titles.self, forKey: .title)
        title = [titles?.native, titles?.romaji, titles?.english]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

private struct TraceMoeEpisode: Decodable {
    let text: String?

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { text = nil }
        else if let string = try? value.decode(String.self) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            text = trimmed.isEmpty ? nil : trimmed
        } else if let number = try? value.decode(Int.self) {
            text = String(number)
        } else if let number = try? value.decode(Double.self), number.isFinite {
            text = String(number)
        } else {
            var array = try decoder.unkeyedContainer()
            var parts: [String] = []
            while !array.isAtEnd {
                let episode = try array.decode(TraceMoeEpisode.self)
                if let part = episode.text { parts.append(part) }
            }
            text = parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
    }
}
