import Foundation
@testable import IINA_ANI

@main enum TorrentHTTPRangeRegression {
    struct Failure: Error { let message: String }

    static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    static func main() throws {
        let cases: [(String?, UInt64, TorrentHTTPHandler.RequestedRange)] = [
            (nil, 10, .absent),
            ("bytes=0-9", 10, .range(0, 9)),
            ("bytes=3-", 10, .range(3, 9)),
            ("bytes=-3", 10, .range(7, 9)),
            ("bytes=-30", 10, .range(0, 9)),
            ("bytes=4-30", 10, .range(4, 9)),
            ("bytes=10-", 10, .unsatisfiable),
            ("bytes=5-4", 10, .unsatisfiable),
            ("bytes=-0", 10, .unsatisfiable),
            ("bytes=-1", 0, .unsatisfiable),
            ("bytes=0-1,4-5", 10, .absent),
            ("items=0-1", 10, .absent),
            ("bytes=invalid", 10, .absent),
            ("bytes=18446744073709551616-", 10, .unsatisfiable),
            ("bytes=-18446744073709551616", 10, .range(0, 9)),
            ("bytes=1-18446744073709551616", 10, .range(1, 9)),
            ("bytes=+1-2", 10, .absent)
        ]
        for (header, size, expected) in cases {
            try require(TorrentHTTPHandler.parseRange(header, size: size) == expected,
                        "unexpected result for Range header \(header ?? "<none>")")
        }
        try require(TorrentHTTPHandler.matchesPath("/torrent/token/media"), "torrent route was not recognized")
        try require(!TorrentHTTPHandler.matchesPath("/video"), "unrelated route was intercepted")
        print("W11.3 Range parser regression passed (\(cases.count) range cases)")
    }
}
