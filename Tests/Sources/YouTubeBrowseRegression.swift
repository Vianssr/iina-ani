import Foundation
@testable import IINA_ANI

@main
struct YouTubeBrowseRegression {
    static func main() throws {
        let firstID = "dQw4w9WgXcQ"
        let secondID = "abcdefgh_-1"
        let escapedTitle = "A {brace}, a \"quote\", a slash \\ and 雪"
        let legacy: [String: Any] = ["videoRenderer": [
            "videoId": firstID, "title": ["runs": [["text": escapedTitle]]],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/vi/\(firstID)/hqdefault.jpg"]]],
            "ownerText": ["runs": [["text": "Channel"]]],
            "lengthText": ["simpleText": "12:34"], "viewCountText": ["simpleText": "42 views"],
            // Neither sidebar cards nor recommendation tokens belong to the feed.
            "menu": ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": "unrelated"]]]]
        ]]
        let modern: [String: Any] = ["lockupViewModel": [
            "contentType": "LOCKUP_CONTENT_TYPE_VIDEO", "contentId": secondID,
            "contentImage": ["thumbnailViewModel": [
                "image": ["sources": [["url": "https://i.ytimg.com/vi/\(secondID)/hqdefault.jpg"]]],
                "overlays": [["thumbnailOverlayBadgeViewModel": ["thumbnailBadges": [
                    ["thumbnailBadgeViewModel": ["text": "HD"]], ["thumbnailBadgeViewModel": ["text": "1:02:03"]]
                ]]]]
            ]],
            "metadata": ["lockupMetadataViewModel": [
                "title": ["content": "Modern video"],
                "metadata": ["contentMetadataViewModel": ["metadataRows": [
                    ["metadataParts": [["text": ["content": "Modern channel"]]]],
                    ["metadataParts": [["text": ["content": "1K views"]], ["text": ["content": "1 day ago"]]]]
                ]]]
            ]]
        ]]
        let modernVideo = YouTubePageParser.video(modern)!
        precondition(modernVideo.id == secondID && modernVideo.title == "Modern video")
        precondition(modernVideo.channel == "Modern channel" && modernVideo.viewCountText == "1K views")
        precondition(modernVideo.durationText == "1:02:03")
        precondition(modernVideo.watchURL.absoluteString == "https://www.youtube.com/watch?v=\(secondID)")

        // Current desktop compact cards combine collaborators and statistics in
        // one metadata row rather than the older channel/statistics two-row shape.
        var compactRenderer = modern["lockupViewModel"] as! [String: Any]
        compactRenderer["metadata"] = ["lockupMetadataViewModel": [
            "title": ["content": "Compact video"],
            "metadata": ["contentMetadataViewModel": ["metadataRows": [
                ["metadataParts": [["text": ["content": "YouTube"]], ["text": ["content": "and Collaborator"]],
                                   ["text": ["content": "1.7M"]], ["text": ["content": "3d ago"]]]]
            ]]]
        ]]
        compactRenderer["contentImage"] = ["thumbnailViewModel": [
            "image": ["sources": [["url": "https://i.ytimg.com/compact.jpg"]]],
            "overlays": [["thumbnailBottomOverlayViewModel": ["badges": [["thumbnailBadgeViewModel": ["text": "8:20"]]]]]]
        ]]
        let compact = YouTubePageParser.video(["lockupViewModel": compactRenderer])!
        precondition(compact.channel == "YouTube" && compact.viewCountText == "1.7M" && compact.durationText == "8:20")

        let contextual: [String: Any] = ["videoWithContextRenderer": [
            "videoId": secondID, "headline": ["runs": [["text": "Context video"]]],
            "thumbnail": ["thumbnails": [["url": "https://i.ytimg.com/context.jpg"]]],
            "shortBylineText": ["simpleText": "Context channel"],
            "thumbnailOverlays": [["thumbnailOverlayTimeStatusRenderer": ["text": ["simpleText": "9:08"]]]]
        ]]
        precondition(YouTubePageParser.video(contextual)?.durationText == "9:08")
        precondition(YouTubePageParser.video(contextual)?.channel == "Context channel")
        let config: [String: Any] = [
            "INNERTUBE_API_KEY": "fixture-api-key", "INNERTUBE_CONTEXT_CLIENT_NAME": 1,
            "INNERTUBE_CONTEXT": ["client": ["clientName": "WEB", "clientVersion": "fixture-version", "visitorData": "fixture-visitor"]],
            "LOGGED_IN": false
        ]
        func cursor(_ token: String, request: String = "CONTINUATION_REQUEST_TYPE_SEARCH") -> [String: Any] {
            ["continuationItemRenderer": ["continuationEndpoint": ["continuationCommand": ["token": token, "request": request]]]]
        }
        func html(_ initial: [String: Any], configuration: [String: Any]? = nil, alternateAssignment: Bool = false) throws -> Data {
            let initialJSON = String(decoding: try JSONSerialization.data(withJSONObject: initial), as: UTF8.self)
            let configJSON = String(decoding: try JSONSerialization.data(withJSONObject: configuration ?? config), as: UTF8.self)
            let assignment = alternateAssignment ? "window[\"ytInitialData\"]=" : "var ytInitialData = "
            return Data("<html><script>ytcfg.set('EXPERIMENT', true);ytcfg.set(\(configJSON));</script><script>\(assignment)\(initialJSON);</script></html>".utf8)
        }
        func search(_ items: [[String: Any]]) -> [String: Any] {
            ["contents": ["twoColumnSearchResultsRenderer": [
                "primaryContents": ["sectionListRenderer": ["targetId": "search-feed", "contents": items]],
                "secondaryContents": ["sectionListRenderer": ["contents": [modern, cursor("sidebar")]]]
            ]]]
        }
        let result = try YouTubePageParser.initial(data: html(search([
            ["itemSectionRenderer": ["contents": [legacy, legacy, modern, ["shelfRenderer": ["content": legacy, "contents": [cursor("shelf")]]]]]],
            cursor("first-page")
        ])), isSearch: true)
        precondition(result.videos.map(\.id) == [firstID, secondID])
        precondition(result.videos[0].title == escapedTitle)
        precondition(result.videos[0].channel == "Channel" && result.videos[0].durationText == "12:34")
        precondition(result.videos[0].viewCountText == "42 views")
        precondition(result.message == nil && result.continuation != nil)
        let alternate = try YouTubePageParser.initial(data: html(search([legacy]), alternateAssignment: true), isSearch: true)
        precondition(alternate.videos.map(\.id) == [firstID])
        let runtimeConfig = String(decoding: try html(search([legacy])), as: UTF8.self)
            + "<script>ytcfg.set({\"CSI_SERVICE_NAME\": 'youtube', \"RUNTIME\": window.runtimeValue});</script>"
        let withRuntimeConfig = try YouTubePageParser.initial(data: Data(runtimeConfig.utf8), isSearch: true)
        precondition(withRuntimeConfig.videos.map(\.id) == [firstID] &&
                     withRuntimeConfig.videos[0].title == escapedTitle)

        let response: [String: Any] = ["onResponseReceivedCommands": [
            ["appendContinuationItemsAction": ["targetId": "sidebar", "continuationItems": [legacy, cursor("sidebar-next")]]],
            ["appendContinuationItemsAction": ["targetId": "search-feed", "continuationItems": [
                ["itemSectionRenderer": ["contents": [modern]]], cursor("second-page")
            ]]]
        ]]
        let next = try YouTubePageParser.continuation(data: JSONSerialization.data(withJSONObject: response), previous: result.continuation!)
        precondition(next.videos.map(\.id) == [secondID] && next.continuation != nil)
        let terminal = try YouTubePageParser.continuation(data: JSONSerialization.data(withJSONObject: [
            "onResponseReceivedActions": [["appendContinuationItemsAction": ["targetId": "search-feed", "continuationItems": []]]]
        ]), previous: next.continuation!)
        precondition(terminal.videos.isEmpty && terminal.continuation == nil)
        let withoutCursor = try YouTubePageParser.initial(data: html(search([legacy])), isSearch: true)
        precondition(withoutCursor.continuation == nil)
        let wrongRouteCursor = try YouTubePageParser.initial(data: html(search([cursor("wrong-route", request: "CONTINUATION_REQUEST_TYPE_BROWSE")])), isSearch: true)
        precondition(wrongRouteCursor.continuation == nil)

        let homeRoot: [String: Any] = ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [
            ["tabRenderer": ["selected": false, "content": ["richGridRenderer": ["contents": [legacy, cursor("wrong-tab")]]]]],
            ["tabRenderer": ["selected": true, "content": ["richGridRenderer": ["contents": [
                ["richItemRenderer": ["content": modern]],
                ["richSectionRenderer": ["content": ["feedNudgeRenderer": ["title": ["runs": [["text": "Try searching to get started"]]], "subtitle": ["simpleText": "Search guidance"]]]]]
            ]]]]]
        ]]]]
        let home = try YouTubePageParser.initial(data: html(homeRoot), isSearch: false)
        precondition(home.videos.map(\.id) == [secondID] && home.continuation == nil)
        precondition(home.message == "Try searching to get started\nSearch guidance")
        let empty = try YouTubePageParser.initial(data: html(search([])), isSearch: true)
        precondition(empty.videos.isEmpty && empty.message != nil)
        let emptyHome: [String: Any] = ["contents": ["twoColumnBrowseResultsRenderer": ["tabs": [
            ["tabRenderer": ["selected": true, "content": ["richGridRenderer": ["contents": []]]]]
        ]]]]
        let guestHome = try YouTubePageParser.initial(data: html(emptyHome), isSearch: false)
        precondition(guestHome.videos.isEmpty && guestHome.continuation == nil && guestHome.message != nil)

        for id in ["short", "abcdefghijk/", "abcdefghij?", "abcdefghijé", "https://bad"] { precondition(!YouTubePageParser.validVideoID(id)) }
        precondition(YouTubePageParser.validVideoID(secondID))
        for url in ["http://i.ytimg.com/image.jpg", "https://ytimg.com.evil.test/image.jpg", "https://evil.test/image.jpg", "https://name@i.ytimg.com/image.jpg", "https://i.ytimg.com:8443/image.jpg", "file:///image.jpg"] {
            precondition(YouTubePageParser.thumbnailURL(url) == nil)
        }
        precondition(YouTubePageParser.thumbnailURL("https://yt3.ggpht.com/image.jpg") != nil)
        for item in [
            ["adSlotRenderer": ["content": legacy]], ["inFeedAdLayoutRenderer": ["content": modern]],
            ["promotedVideoRenderer": legacy["videoRenderer"]!], ["channelRenderer": ["channelId": firstID]],
            ["reelItemRenderer": ["videoId": firstID]], ["lockupViewModel": ["contentType": "LOCKUP_CONTENT_TYPE_PLAYLIST", "contentId": firstID]],
            ["videoRenderer": ["videoId": "invalid", "title": ["simpleText": "Invalid"]]],
            ["videoRenderer": ["videoId": firstID, "title": ["simpleText": "Ad"], "adInfo": [:]]]
        ] { precondition(YouTubePageParser.video(item) == nil) }
        let adsOnly = try YouTubePageParser.initial(data: html(search([["adSlotRenderer": ["content": legacy]]])), isSearch: true)
        precondition(adsOnly.videos.isEmpty)
        precondition(YouTubePageParser.loggedIn(config: ["LOGGED_IN": true], initialData: [:]) == true)
        precondition(YouTubePageParser.loggedIn(config: ["LOGGED_IN": false], initialData: [:]) == false)
        precondition(YouTubePageParser.loggedIn(config: [:], initialData: ["responseContext": ["mainAppWebResponseContext": ["loggedOut": false]]]) == true)
        precondition(YouTubePageParser.loggedIn(config: [:], initialData: [:]) == nil)
        do {
            _ = try YouTubePageParser.initial(data: html(search([])), isSearch: true, accountID: UUID())
            fatalError("Server-reported signed-out account accepted")
        } catch SiteAccountError.expired {}
        for malformed in ["", "<html>not a YouTube bootstrap</html>", "var ytInitialData = {\"contents\": []", "var ytInitialData = {broken};", "var ytInitialData = {\"x\": [}};"] {
            do {
                _ = try YouTubePageParser.document(data: Data(malformed.utf8))
                fatalError("Malformed HTML accepted")
            } catch YouTubeBrowseError.malformedPage {}
        }
        do {
            _ = try YouTubePageParser.initial(data: html(["contents": [:]]), isSearch: true)
            fatalError("Unsupported feed silently accepted")
        } catch YouTubeBrowseError.malformedPage {}
        do {
            _ = try YouTubePageParser.document(data: Data("<form action=\"https://consent.youtube.com/save\"></form>".utf8))
            fatalError("Consent page accepted")
        } catch YouTubeBrowseError.consentRequired {}
        do {
            _ = try YouTubePageParser.document(data: Data("<html>recaptcha unusual traffic</html>".utf8))
            fatalError("Challenge page accepted")
        } catch YouTubeBrowseError.challengeRequired {}
        do {
            _ = try YouTubePageParser.continuation(data: Data("{}".utf8), previous: result.continuation!)
            fatalError("Missing continuation shape accepted")
        } catch YouTubeBrowseError.malformedPage {}
        do {
            _ = try YouTubePageParser.continuation(data: Data("{\"error\":{\"code\":403}}".utf8), previous: result.continuation!)
            fatalError("Expired continuation accepted")
        } catch SiteAccountError.expired {}
        print("YouTube parsing regression passed: bootstrap escaping, legacy/context/lockup videos, scoped continuations, guest guidance, ad and URL filtering, server login, malformed/consent/challenge pages")
    }
}
