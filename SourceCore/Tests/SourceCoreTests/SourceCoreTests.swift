import Foundation
import SourceCore
import XCTest

// Use only the public module API, with no app target or platform compilation flags.
final class SourceCoreTests: XCTestCase {
    private func configuration() throws -> SourceConfiguration {
        try SourceConfiguration.load(data: Data(#"""
        {
          "id": "fixture", "name": "Fixture", "version": 1,
          "hosts": ["fixture.example"], "mediaHosts": ["media.example"],
          "capabilities": ["information", "resolve", "episodes", "lines", "iina", "mpv", "download"],
          "route": {
            "pattern": "^/(?:detail|play)/([0-9]+)(?:-([0-9]+)-([0-9]+))?\\.html$",
            "idGroup": 1, "lineGroup": 2, "episodeGroup": 3,
            "detailTemplate": "https://fixture.example/detail/{id}.html"
          },
          "catalog": {
            "url": "https://fixture.example/catalog/{id}", "format": "json",
            "jsonTitlePath": "title", "jsonEntriesPath": "episodes",
            "jsonEpisodeTitlePath": "title", "jsonEpisodeURLPath": "url"
          },
          "player": {
            "format": "html", "payloadPattern": "player=(.+)",
            "idKey": "id", "lineKey": "sid", "episodeKey": "nid",
            "paidKey": "points", "previewKey": "trysee", "encodingKey": "encrypt", "urlKey": "url",
            "allowedExtensions": ["mp4"]
          }
        }
        """#.utf8))
    }

    func testConfigurationRoundTripPreservesRevisionAndPlatformCapabilities() throws {
        let source = try configuration()
        let reloaded = try SourceConfiguration.load(data: source.encodedData())
        XCTAssertEqual(reloaded.configurationRevision, source.configurationRevision)
        XCTAssertEqual(try reloaded.parts("https://fixture.example/play/42-2-7.html").episode, 7)
        XCTAssertEqual(source.descriptor(on: .iOS).capabilities, [.information, .resolve, .episodes, .lines, .mpv])
        XCTAssertTrue(source.descriptor(on: .macOS).capabilities.contains(.download))
        XCTAssertFalse(source.matches("https://fixture.example.evil.test/play/42-2-7.html"))
    }

    func testExistingSelectionJSONStillDecodesWithoutClassification() throws {
        let legacy = Data(#"{"item":{"sourceID":"fixture","pageURL":"https://fixture.example/detail/42.html","kind":"work"},"episode":{"sourceID":"fixture","pageURL":"https://fixture.example/play/42-2-7.html","kind":"episode"},"lineID":"2","qualityID":"HD"}"#.utf8)
        let selection = try JSONDecoder().decode(PlayableSelection.self, from: legacy)
        XCTAssertEqual(selection.classification, .unknown)
        XCTAssertEqual(selection.lineID, "2")
        XCTAssertEqual(try JSONDecoder().decode(PlayableSelection.self, from: JSONEncoder().encode(selection)), selection)
        XCTAssertEqual(PlaybackWorkIdentity.bangumi(42).localID, "bangumi-work:v1:2:42")
        XCTAssertEqual(PlaybackEpisodeIdentity.bangumi(7, type: nil, sort: nil).localID, "bangumi-episode:v1:1:7")
    }

    func testMediaValidationReturnsAPlatformIndependentError() throws {
        let source = try configuration()
        let payload: [String: Any] = ["id": 42, "sid": 2, "nid": 7, "points": 0, "trysee": 0,
                                      "encrypt": 0, "url": "https://media.example/episode.mp4"]
        XCTAssertEqual(try source.validatedPlayerMediaURL(payload, id: "42", line: 2, episode: 7),
                       "https://media.example/episode.mp4")
        XCTAssertThrowsError(try source.validatedPlayerMediaURL(payload, id: "42", line: 2, episode: 8)) {
            XCTAssertEqual($0 as? SourceConfiguration.ConfigurationError, .invalidMedia)
        }
    }

    func testPublicPlayerProtocolAndRequestPolicyAreAvailableToBothClients() throws {
        XCTAssertEqual(try PublicPlayerProtocol.decrypt("Wwqvystuk5bRzV6wBvFy17geHWdaKyhe9C8q9d9ZA5M=", timestamp: "1700000000"),
                       "https://media.example/video.mp4")
        let policy = PublicPlayerProtocol.Policy(host: "www.didahd.xyz")
        var request = URLRequest(url: PublicPlayerProtocol.smartAPI)
        request.httpMethod = "POST"
        XCTAssertTrue(PublicPlayerProtocol.permits(request, configuration: policy))
        request.url = URL(string: "https://unreviewed.example/player")!
        XCTAssertFalse(PublicPlayerProtocol.permits(request, configuration: policy))
    }

    func testSlowEpisodeAPIHasABoundedWaitWithoutExtendingOtherRequests() {
        var request = URLRequest(url: PublicPlayerProtocol.smartAPI)
        request.httpMethod = "POST"
        XCTAssertEqual(PublicPlayerProtocol.requestTimeout(for: request), 45)
        request.httpMethod = "GET"
        XCTAssertEqual(PublicPlayerProtocol.requestTimeout(for: request), 20)
        request.httpMethod = "POST"
        request.url = URL(string: "https://hd.ticktockwow.com/smartplay-cache/other.php")!
        XCTAssertEqual(PublicPlayerProtocol.requestTimeout(for: request), 20)
        request.url = URL(string: "https://www.didahd.xyz/static/player/art.js")!
        XCTAssertEqual(PublicPlayerProtocol.requestTimeout(for: request), 20)
    }
}
