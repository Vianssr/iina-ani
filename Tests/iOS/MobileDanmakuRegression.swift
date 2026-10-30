import Foundation

@main
struct MobileDanmakuRegression {
    @MainActor static func main() throws {
        let xml = Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <i>
              <d p="12,5,25,65280,0,0,0,0">Top &amp; green</d>
              <d p="10,1,25,16777215,0,0,0,0">Hello 世界</d>
              <d p="10,4,25,16711680,0,0,0,0"><![CDATA[Bottom <text>]]></d>
              <d p="10,7,25,16777215,0,0,0,0">Unsupported script</d>
              <d p="nan,1,25,16777215,0,0,0,0">Bad time</d>
            </i>
            """.utf8)
        let parsed = try MobileDanmakuParser.parse(data: xml)
        precondition(parsed.count == 3)
        precondition(parsed.map(\.time) == [10, 10, 12])
        precondition(parsed[0].mode == .scrolling && parsed[1].mode == .bottom)
        precondition(parsed[2].text == "Top & green" && parsed[2].color == 65_280)
        precondition(parsed[1].text == "Bottom <text>")

        let json = Data(#"[{"stime":1500,"mode":1,"text":"CDF"},{"time":2.5,"mode":5,"text":"Seconds"},{"c":"3.5,16711680,4,25","m":"AcFun"},{"time":"inf","text":"Invalid"},{"time":true,"text":"Boolean"}]"#.utf8)
        let jsonEntries = try MobileDanmakuParser.parse(data: json)
        precondition(jsonEntries.map(\.time) == [1.5, 2.5, 3.5])
        precondition(jsonEntries.map(\.mode) == [.scrolling, .top, .bottom])
        precondition(jsonEntries[2].color == 0xFF0000)
        let wrapped = try MobileDanmakuParser.parse(data: Data(#"{"comments":[{"time":0,"text":"Valid"}]}"#.utf8))
        precondition(wrapped.count == 1)

        for bad in [
            "<i><d p=\"0,1,25,0\">broken",
            "<!DOCTYPE i [<!ENTITY x 'bad'>]><i><d p=\"0,1,25,0\">&x;</d></i>",
            "<!DOCTYPE i SYSTEM 'file:///etc/passwd'><i/>",
            "{\"text\":\"No timestamped array\"}",
            "[{\"time\":-1,\"text\":\"negative\"}]",
            "[{\"time\":9999999999,\"text\":\"out of range\"}]",
            "<i/>"
        ] {
            precondition((try? MobileDanmakuParser.parse(data: Data(bad.utf8))) == nil, "Malformed import accepted")
        }
        precondition((try? MobileDanmakuParser.parse(data: Data(repeating: 65, count: MobileDanmakuParser.maximumBytes + 1))) == nil)
        let excessive = "[" + Array(repeating: #"{"time":0,"text":"x"}"#, count: MobileDanmakuParser.maximumComments + 1).joined(separator: ",") + "]"
        precondition((try? MobileDanmakuParser.parse(data: Data(excessive.utf8))) == nil)

        let suiteName = "MobileDanmakuRegression." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = MobileDanmakuStore(defaults: defaults)
        precondition(store.enabled && store.blockedWords.isEmpty)
        precondition(!store.hideScrolling && !store.hideTop && !store.hideBottom, "Fresh preferences must preserve existing defaults")
        try store.parse(data: xml)
        precondition(store.filteredCount == 3)
        precondition(store.activeEntries(at: 9).isEmpty)
        let paused = store.activeEntries(at: 12)
        precondition(paused.count == 3)
        precondition(store.activeEntries(at: 12) == paused, "Pause must be deterministic")
        precondition(store.activeEntries(at: 100).isEmpty, "Seeking forward must not replay accumulated comments")
        precondition(store.activeEntries(at: 12) == paused, "Backward seek must reproduce only comments active at destination")
        precondition(store.activeEntries(at: 14).count == 2)
        precondition(store.activeEntries(at: 18).isEmpty)
        precondition(store.activeEntries(at: .nan).isEmpty)
        store.enabled = false
        precondition(store.activeEntries(at: 12).isEmpty)
        precondition(store.filteredCount == 0)
        store.enabled = true
        store.hideScrolling = true
        precondition(store.activeEntries(at: 12).count == 2)
        precondition(store.filteredCount == 2)
        store.hideTop = true
        precondition(store.activeEntries(at: 12).map(\.entry.mode) == [.bottom])
        store.hideBottom = true
        precondition(store.activeEntries(at: 12).isEmpty)
        store.hideScrolling = false
        store.hideTop = false
        store.hideBottom = false
        store.blockedWords = "HELLO，green\nunused"
        precondition(store.activeEntries(at: 12).map(\.entry.mode) == [.bottom])
        precondition(store.filteredCount == 1)
        store.blockedWords = ""
        let retainedTimeline = store.activeEntries(at: 12)
        for invalid in ["broken", "<i/>", #"[{"time":-1,"text":"invalid"}]"#] {
            do { try store.parse(data: Data(invalid.utf8)); preconditionFailure("Invalid import succeeded") }
            catch {
                precondition(store.entries == parsed, "Failed imports must preserve previous comments")
                precondition(store.activeEntries(at: 12) == retainedTimeline, "Failed imports must preserve the scheduled timeline")
            }
        }
        do {
            try store.load(url: URL(string: "https://example.invalid/comments.xml")!)
            preconditionFailure("Nonlocal import succeeded")
        } catch { precondition(store.entries == parsed, "Failed file imports must preserve previous comments") }

        let dense = "[" + (0..<20).map { #"{"time":0,"text":"Comment \#($0)"}"# }.joined(separator: ",") + "]"
        try store.parse(data: Data(dense.utf8))
        precondition(store.entries.count == 20)
        precondition(store.filteredCount == 20, "Visible count must count matches before lane thinning")
        precondition(store.activeEntries(at: 2).count == 6, "Density must be bounded without overlapping lanes")
        precondition(Set(store.activeEntries(at: 2).map(\.lane)).count == 6)
        store.clear()
        precondition(store.entries.isEmpty && store.activeEntries(at: 2).isEmpty, "Episode changes must clear the timeline")
        precondition(store.filteredCount == 0)
        let fixtureURL = URL(fileURLWithPath: "Tests/iOS/Fixtures/player-fixture.xml")
        try store.load(url: fixtureURL)
        precondition(store.entries.count == 6 && store.filteredCount == 6)
        store.blockedWords = "spoiler"
        store.hideTop = true
        precondition(store.filteredCount == 4, "The UI fixture must reflect keyword and mode filters")
        store.enabled = false
        store.hideScrolling = true
        store.hideBottom = true
        store.clear()
        precondition(store.entries.isEmpty && store.filteredCount == 0)
        precondition(!store.enabled && store.blockedWords == "spoiler")
        precondition(store.hideScrolling && store.hideTop && store.hideBottom, "Clearing an episode must not reset preferences")
        let restored = MobileDanmakuStore(defaults: defaults)
        precondition(!restored.enabled && restored.blockedWords == "spoiler")
        precondition(restored.hideScrolling && restored.hideTop && restored.hideBottom, "A new store must restore every saved filter")
        precondition(restored.entries.isEmpty, "Episode content must not be persisted as a global preference")
        restored.enabled = true
        restored.blockedWords = ""
        restored.hideScrolling = false
        restored.hideTop = false
        restored.hideBottom = false
        let reset = MobileDanmakuStore(defaults: defaults)
        precondition(reset.enabled && reset.blockedWords.isEmpty)
        precondition(!reset.hideScrolling && !reset.hideTop && !reset.hideBottom, "Explicitly reset preferences must persist, including false values")
        print("PASS: danmaku XML/CDF/AcFun parsing, import limits, failed-import preservation, persistent isolated preferences, filters, density, pause and bidirectional seeking")
    }
}
