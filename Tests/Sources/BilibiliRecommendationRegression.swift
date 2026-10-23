import Foundation
@testable import IINA_ANI

@main
struct BilibiliRecommendationRegression {
    static func main() throws {
        let video: [String: Any] = [
            "goto": "av", "id": 1354614895, "bvid": "BV1Dz42117GZ",
            "title": "Recommended video", "pic": "http://example.com/recommendation.jpg",
            "duration": 882, "owner": ["name": "Uploader"], "stat": ["view": 48250],
            "business_info": NSNull()
        ]
        func page(_ items: [[String: Any]]) throws -> BilibiliRecommendationPage {
            try BilibiliRecommendationPage(data: JSONSerialization.data(withJSONObject: [
                "code": 0, "data": ["item": items]
            ]))
        }
        let first = try page([video])
        precondition(first.cards.count == 1)
        let card = first.cards[0]
        precondition(card.bvid == "BV1Dz42117GZ" && card.dynamicId == nil)
        precondition(card.title == "Recommended video" && card.name == "Uploader")
        precondition(card.duration == 882 && card.views == "48250")
        precondition(card.picUrl == "https://example.com/recommendation.jpg")

        var promoted = video
        promoted["business_info"] = ["creative_id": 123]
        let nonVideos: [[String: Any]] = [
            ["goto": "ad", "bvid": "BV1Dz42117GZ"],
            ["goto": "live", "id": 123],
            ["goto": "bangumi", "uri": "https://www.bilibili.com/bangumi/play/ep123"],
            promoted
        ]
        let mixed = try page(nonVideos + [video])
        precondition(mixed.cards == first.cards)
        let filtered = try page(nonVideos)
        precondition(filtered.cards.isEmpty)
        let empty = try page([])
        precondition(empty.cards.isEmpty)

        var withoutBusiness = video
        withoutBusiness.removeValue(forKey: "business_info")
        withoutBusiness["duration"] = 0
        withoutBusiness["stat"] = ["view": 0]
        let zero = try page([withoutBusiness]).cards[0]
        precondition(zero.duration == 0 && zero.views == "0")

        for code in [-101, 4100000] {
            do {
                _ = try BilibiliRecommendationPage(data: JSONSerialization.data(withJSONObject: [
                    "code": code, "message": "not logged in"
                ]))
                fatalError("Expired session accepted")
            } catch SiteAccountError.expired {}
        }
        do {
            _ = try BilibiliRecommendationPage(data: Data(#"{"code":-352,"message":"request rejected"}"#.utf8))
            fatalError("API error accepted as empty recommendations")
        } catch {
            let failure = error as NSError
            precondition(failure.domain == "BilibiliRecommendations" && failure.code == -352)
            precondition(failure.localizedDescription.contains("request rejected"))
        }
        do {
            _ = try BilibiliRecommendationPage(data: Data(#"{"code":-500}"#.utf8))
            fatalError("Server error without a message accepted")
        } catch {
            precondition((error as NSError).code == -500)
        }
        for response in ["", "not JSON", #"{"code":0}"#, #"{"code":0,"data":{"item":null}}"#] {
            do {
                _ = try BilibiliRecommendationPage(data: Data(response.utf8))
                fatalError("Malformed response accepted as empty recommendations")
            } catch {}
        }
        for field in ["bvid", "duration", "owner", "stat"] {
            var malformed = video
            malformed.removeValue(forKey: field)
            do {
                _ = try page([malformed])
                fatalError("Malformed video silently dropped")
            } catch {}
        }
        var missingVideoID = video
        missingVideoID["bvid"] = ""
        do {
            _ = try page([missingVideoID])
            fatalError("Video without a playable ID accepted")
        } catch {}
        print("Bilibili recommendation regression passed: video mapping, advertisement filtering, empty pages, API errors, malformed responses")
    }
}
