import Foundation

@main struct LinkFavoritesRegression {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ani-links-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("links.json")
        let library = MobileLinkLibrary(file: file)
        let first = try library.save(title: "First", address: "https://EXAMPLE.com/series/42#episodes")
        precondition(first.item == SourceItemRef(sourceID: "web:example.com", pageURL: "https://example.com/series/42", kind: .work))
        let duplicate = try library.save(title: "Duplicate", address: "https://example.com/series/42")
        precondition(duplicate.id == first.id && library.links == [first])
        let second = try library.save(title: "Second", address: "https://example.com/catalog?id=43")
        let reopened = MobileLinkLibrary(file: file)
        precondition(reopened.links == [second, first])
        precondition(reopened.matching("FIRST") == [first])
        precondition(reopened.matching("id=43") == [second])
        let renamed = try reopened.save(id: first.id, title: "Renamed", address: first.item.pageURL)
        precondition(renamed.id == first.id && renamed.createdAt == first.createdAt)
        do {
            try reopened.save(id: first.id, title: "Collision", address: second.item.pageURL)
            fatalError("Accepted duplicate edit")
        } catch MobileLinkLibrary.Failure.duplicate {}
        precondition(reopened.links == [second, renamed])
        for invalid in ["http://example.com/series/42", "https://u:p@example.com/a", "https://example.com/a?token=private",
                        "https://example.com/movie.m3u8", "https://example.com/a?utm_source=tracking",
                        "https://example.com/a?id=1&id=2", "file:///tmp/movie.mp4", "https://example.com/a?file=https://other.example/media"] {
            do { _ = try MobileLinkLibrary.page(invalid); fatalError("Accepted nonpublic page") }
            catch MobileLinkLibrary.Failure.invalidPage {}
        }
        try reopened.remove(second.id)
        precondition(MobileLinkLibrary(file: file).links == [renamed])

        let unknown = Data("{\"version\":99,\"links\":[]}".utf8)
        try unknown.write(to: file)
        do { try reopened.remove(first.id); fatalError("Overwrote externally replaced authority") }
        catch MobileLinkLibrary.Failure.unreadable {}
        reopened.reload()
        precondition(!reopened.isReadable && reopened.links == [renamed])
        do { try reopened.remove(first.id); fatalError("Overwrote future file") }
        catch MobileLinkLibrary.Failure.unreadable {}
        let preserved = try Data(contentsOf: file)
        precondition(preserved == unknown)
        try Data("broken".utf8).write(to: file)
        reopened.reload()
        precondition(!reopened.isReadable && reopened.links == [renamed])
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        do { try library.remove(first.id); fatalError("Committed failed write") } catch {}
        precondition(library.links == [second, first] && library.storageError)
        print("PASS link favorites: public identity, restart, duplicates, edit, independent deletion, corrupt/future and write failure protection")
    }
}
