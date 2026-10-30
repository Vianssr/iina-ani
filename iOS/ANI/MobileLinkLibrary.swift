import Foundation
import Observation

/// Public source pages, not Bangumi subjects, resolved media, or account-bearing URLs.
struct MobileLinkFavorite: Codable, Identifiable, Equatable {
    let id: UUID
    var title: String
    var item: SourceItemRef
    let createdAt: Date
}

@MainActor @Observable
final class MobileLinkLibrary {
    enum Failure: Error { case unreadable, invalidPage, duplicate, missing, invalidData }
    private(set) var links: [MobileLinkFavorite] = []
    private(set) var isReadable = false
    private(set) var storageError = false
    private let file: URL
    private var authorityBytes: Data?

    init(file: URL = URL.applicationSupportDirectory.appendingPathComponent("ANI/link-favorites.json")) {
        self.file = file
        reload()
    }

    func reload() {
        do {
            let bytes = try readAuthority()
            let loaded = try bytes.map { try Self.decode($0).links } ?? []
            authorityBytes = bytes
            links = loaded
            isReadable = true
            storageError = false
        } catch {
            isReadable = false
            storageError = true
        }
    }

    /// Preserve the public page's query identity; reject rather than silently truncate ambiguous URLs.
    nonisolated static func page(_ input: String) throws -> SourceItemRef {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.utf8.count <= 4096, var url = URLComponents(string: raw),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil else { throw Failure.invalidPage }
        url.scheme = "https"
        url.host = host.lowercased()
        url.fragment = nil
        if url.path.isEmpty { url.path = "/" }
        guard let normalized = url.string, ConfirmedSourceMapping.isCanonicalPublicPage(normalized) else {
            throw Failure.invalidPage
        }
        return SourceItemRef(sourceID: "web:" + host.lowercased(), pageURL: normalized, kind: .work)
    }

    @discardableResult
    func save(id: UUID? = nil, title: String, address: String) throws -> MobileLinkFavorite {
        guard isReadable else { throw Failure.unreadable }
        let item = try Self.page(address)
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, label.utf8.count <= 512,
              !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw Failure.invalidData }
        if let duplicate = links.first(where: { $0.item == item && $0.id != id }) {
            if id == nil { return duplicate }
            throw Failure.duplicate
        }
        var updated = links
        let result: MobileLinkFavorite
        if let id {
            guard let index = updated.firstIndex(where: { $0.id == id }) else { throw Failure.missing }
            updated[index].title = label
            updated[index].item = item
            result = updated[index]
        } else {
            result = MobileLinkFavorite(id: UUID(), title: label, item: item, createdAt: .now)
            updated.insert(result, at: 0)
        }
        try commit(updated)
        return result
    }

    func remove(_ id: UUID) throws {
        guard isReadable else { throw Failure.unreadable }
        guard links.contains(where: { $0.id == id }) else { throw Failure.missing }
        try commit(links.filter { $0.id != id })
    }

    func matching(_ query: String) -> [MobileLinkFavorite] {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? links : links.filter {
            $0.title.localizedCaseInsensitiveContains(value) || $0.item.pageURL.localizedCaseInsensitiveContains(value)
        }
    }

    private func commit(_ updated: [MobileLinkFavorite]) throws {
        do {
            guard try readAuthority() == authorityBytes else {
                isReadable = false
                throw Failure.unreadable
            }
            let bytes = try JSONEncoder().encode(Document(version: 1, links: updated))
            _ = try Self.decode(bytes)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: file, options: .atomic)
            authorityBytes = bytes
            links = updated
            storageError = false
        } catch {
            storageError = true
            throw error
        }
    }

    private func readAuthority() throws -> Data? {
        do { return try Data(contentsOf: file) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain &&
            [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(error.code) { return nil }
    }

    private struct Document: Codable { let version: Int; let links: [MobileLinkFavorite] }
    private static func decode(_ bytes: Data) throws -> Document {
        let document = try JSONDecoder().decode(Document.self, from: bytes)
        guard document.version == 1, Set(document.links.map(\.id)).count == document.links.count,
              Set(document.links.map(\.item)).count == document.links.count else { throw Failure.invalidData }
        for link in document.links {
            guard try page(link.item.pageURL) == link.item, !link.title.isEmpty, link.title.utf8.count <= 512,
                  !link.title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  link.createdAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidData }
        }
        return document
    }
}
