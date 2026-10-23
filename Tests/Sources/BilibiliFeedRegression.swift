import Foundation
@testable import IINA_ANI

@main
struct BilibiliFeedRegression {
    static func main() throws {
        let video: [String: Any] = [
            "type": "DYNAMIC_TYPE_AV", "id_str": "1262372497004691508",
            "modules": [
                "module_author": ["name": "Uploader"],
                "module_dynamic": ["major": ["type": "MAJOR_TYPE_ARCHIVE", "archive": [
                    "bvid": "BV1xx411c7mi", "title": "Video", "cover": "http://example.com/cover.jpg",
                    "stat": ["play": "1.2万"], "duration_text": "01:02:03"
                ]]]
            ]
        ]
        func page(_ items: [[String: Any]], offset: String, more: Bool) throws -> BilibiliDynamicPage {
            try BilibiliDynamicPage(data: JSONSerialization.data(withJSONObject: [
                "code": 0, "data": ["items": items, "offset": offset, "has_more": more]
            ]))
        }
        let first = try page([video, ["type": "DYNAMIC_TYPE_WORD"],
                              ["type": "DYNAMIC_TYPE_AV", "modules": ["module_dynamic": ["major": ["type": "MAJOR_TYPE_NONE"]]]]],
                             offset: "opaque-next-page", more: true)
        precondition(first.cards.map(\.bvid) == ["BV1xx411c7mi"])
        precondition(first.offset == "opaque-next-page" && first.hasMore)
        let card = first.cards[0]
        precondition(card.dynamicId == 1262372497004691508 && card.duration == 3723)
        precondition(card.views == "1.2万" && card.name == "Uploader")
        precondition(card.picUrl == "https://example.com/cover.jpg")
        let filtered = try page([["type": "DYNAMIC_TYPE_WORD"]], offset: "next-even-without-videos", more: true)
        precondition(filtered.cards.isEmpty && filtered.hasMore && filtered.offset == "next-even-without-videos")
        let last = try page([], offset: "", more: false)
        precondition(last.cards.isEmpty && !last.hasMore)
        do {
            _ = try BilibiliDynamicPage(data: Data(#"{"code":-101,"message":"not logged in"}"#.utf8))
            fatalError("Expired session accepted")
        } catch SiteAccountError.expired {}
        do {
            _ = try BilibiliDynamicPage(data: Data(#"{"code":-352,"message":"request rejected"}"#.utf8))
            fatalError("API error accepted as empty page")
        } catch {
            precondition((error as NSError).code == -352)
        }
        var malformed = video
        malformed["modules"] = ["module_dynamic": ["major": ["type": "MAJOR_TYPE_ARCHIVE"]]]
        do {
            _ = try page([malformed], offset: "next", more: true)
            fatalError("Malformed video silently dropped")
        } catch {}
        print("Bilibili feed regression passed: archive mapping, opaque cursors, filtered pages, end of feed, API errors")
    }
}
