import Foundation
import SourceCore
import CoreFoundation

protocol LiveInfo: Sendable {
    var title: String { get }; var name: String { get }; var avatar: String { get }
    var cover: String { get }; var isLiving: Bool { get }; var site: SupportSites { get }
}
protocol SupportSiteProtocol: Sendable {
    func liveInfo(_ url: String) async throws -> any LiveInfo
    func decodeUrl(_ url: String) async throws -> YouGetJSON
}

struct VideoTreeNode: Sendable {
    let title: String
    let isLeaf: Bool
    let children: [VideoTreeNode]
    let site: SupportSites
    let index: Int
    let id: String
    let url: String
    let isLiving: Bool
    let coverUrl: URL?
    let longTitle: String
    var selectionURL: String { url }
    init(site: SupportSites = .unsupported, index: Int = 0, title: String, id: String,
         url: String = "", isLiving: Bool = false, coverUrl: URL? = nil, longTitle: String = "") {
        self.title = title; isLeaf = true; children = []; self.site = site; self.index = index
        self.id = id; self.url = url; self.isLiving = isLiving; self.coverUrl = coverUrl; self.longTitle = longTitle
    }
    init(title: String, children: [VideoTreeNode]) {
        self.title = title; isLeaf = false; self.children = children; site = .unsupported
        index = 0; id = ""; url = ""; isLiving = false; coverUrl = nil; longTitle = ""
    }
}

struct Stream: Sendable {
    var quality = -1
    var qualityIndex = -1
    var rate = -1
    var url: String?
    var videoProfile: String?
    var size: Int64?
    var src: [String] = []
    init(url: String) { self.url = url }
}
struct YouGetJSON: Sendable {
    var rawUrl: String
    var title = ""
    var streams: [String: Stream] = [:]
    init(rawUrl: String) { self.rawUrl = rawUrl }
    var videos: [(key: String, value: Stream)] {
        streams.sorted {
            if $0.value.qualityIndex >= 0, $1.value.qualityIndex >= 0,
               $0.value.qualityIndex != $1.value.qualityIndex { return $0.value.qualityIndex < $1.value.qualityIndex }
            if $0.value.quality != $1.value.quality { return $0.value.quality > $1.value.quality }
            return $0.key < $1.key
        }
    }
}

/// Legacy decoder spellings map to the shared public failure vocabulary.
enum VideoGetError {
    static let invalidLink = PlaybackFailure.missingEpisode
    static let notFountData = PlaybackFailure.mediaNotFound
    static let notSupported = PlaybackFailure.unsupportedResponse
}

struct HTTPHeaders: Sendable, ExpressibleByDictionaryLiteral {
    private(set) var dictionary: [String: String]
    init(_ dictionary: [String: String]) { self.dictionary = dictionary }
    init(dictionaryLiteral elements: (String, String)...) { dictionary = Dictionary(elements, uniquingKeysWith: { _, last in last }) }
    mutating func add(name: String, value: String) { dictionary[name] = value }
}

/// Only the invocation-scoped fetch is inherited by decoder actors. There is no account singleton.
enum AccountHTTP {
    @TaskLocal static var currentFetch: SourceHTTPTransport.Fetch?
    static func request(_ raw: String, headers: HTTPHeaders? = nil) -> NativeRequest {
        NativeRequest(raw: raw, headers: headers)
    }
    static func request(_ url: URL, headers: HTTPHeaders? = nil) -> NativeRequest {
        NativeRequest(raw: url.absoluteString, headers: headers)
    }
    static func response(_ request: URLRequest, allowedHosts: Set<String>,
                         maximumResponseBytes: Int = 4 * 1024 * 1024,
                         successPrefixBytes: Int? = nil) async throws -> SourceHTTPResponse {
        try Task.checkCancellation()
        guard let url = request.url, SourceHTTPTransport.permits(url, allowedHosts: allowedHosts) else { throw PlaybackFailure.unsafeMediaAddress }
        let response: SourceHTTPResponse
        if let fetch = currentFetch {
            response = try await fetch(request)
        } else {
            let challenge = ["www.haixingdmx.com", "haixingdmx.com"].contains(url.host ?? "") &&
                (url.path == "/playinfo" || url.path.hasPrefix("/playinfo/"))
            let cookies: SourceHTTPTransport.CookiePolicy? = challenge ? .init(credentialHosts: [url.host!], request: request) : nil
            response = try await SourceHTTPTransport(cookiePolicy: cookies).response(for: request, allowedHosts: allowedHosts,
                maximumResponseBytes: maximumResponseBytes, successPrefixBytes: successPrefixBytes)
        }
        try Task.checkCancellation()
        guard SourceHTTPTransport.permits(response.url, allowedHosts: allowedHosts) else { throw PlaybackFailure.sourceRedirect }
        let limit = (200..<300).contains(response.statusCode) ? successPrefixBytes ?? maximumResponseBytes : maximumResponseBytes
        guard response.data.count <= limit else { throw PlaybackFailure.invalidResponseBody }
        return response
    }
}

struct NativeRequest: Sendable {
    let raw: String
    let headers: HTTPHeaders?
    func validate() -> Self { self }
    func serializingString() -> NativeStringRequest { NativeStringRequest(request: self) }
    func serializingData() -> NativeDataRequest { NativeDataRequest(request: self) }
    func response() async throws -> SourceHTTPResponse {
        guard let url = URL(string: raw), let host = url.host else { throw PlaybackFailure.missingEpisode }
        var request = URLRequest(url: url)
        for (name, value) in headers?.dictionary ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
        let hosts = Set(SupportSites.nativeSites.first(where: { $0.hosts.contains(host) })?.hosts ?? [host])
        let response = try await AccountHTTP.response(request, allowedHosts: hosts)
        if response.statusCode == 401 { throw PlaybackFailure.authenticationRequired }
        if response.statusCode == 403 { throw PlaybackFailure.httpForbidden }
        guard (200..<300).contains(response.statusCode) else { throw PlaybackFailure.playerServiceUnavailable }
        return response
    }
    func data() async throws -> Data { try await response().data }
}
struct NativeDataRequest: Sendable {
    let request: NativeRequest
    var value: Data { get async throws { try await request.data() } }
}
struct NativeStringRequest: Sendable {
    let request: NativeRequest
    var value: String {
        get async throws {
            let response = try await request.response()
            let contentType = response.headers.first(where: { $0.key.lowercased() == "content-type" })?.value ?? ""
            var encoding = String.Encoding.utf8
            if let marker = contentType.range(of: "charset=", options: .caseInsensitive) {
                let charset = contentType[marker.upperBound...].split(separator: ";", maxSplits: 1).first.map(String.init)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if let charset {
                    let converted = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
                    if converted != kCFStringEncodingInvalidId { encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(converted)) }
                }
            }
            guard let text = String(data: response.data, encoding: encoding) ?? String(data: response.data, encoding: .isoLatin1) else { throw PlaybackFailure.invalidResponseBody }
            return text
        }
    }
}
