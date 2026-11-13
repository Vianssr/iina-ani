import Foundation
import SwiftSoup

/// Pairs selectors by node identity or their nearest unambiguous common container.
/// Independently filtered or reordered lists must never be zipped by position.
public enum SelectorPairing {
    public enum Failure: Error { case invalidSelector, ambiguousStructure, tooManyResults }

    public static func validate(_ selector: String) throws {
        guard !selector.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              selector.utf8.count <= 1024,
              !selector.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw Failure.invalidSelector
        }
        do { _ = try SwiftSoup.parse("").select(selector) }
        catch { throw Failure.invalidSelector }
    }

    public static func pairs(in root: Element, names: String, links: String) throws -> [(name: Element, link: Element)] {
        try validate(names); try validate(links)
        let nameNodes = try root.select(names).array()
        let linkNodes = try root.select(links).array()
        guard nameNodes.count <= 10_000, linkNodes.count <= 10_000 else { throw Failure.tooManyResults }
        guard nameNodes.count == linkNodes.count else { throw Failure.ambiguousStructure }
        guard !nameNodes.isEmpty else { return [] }

        func chain(_ element: Element) throws -> [Element] {
            var result: [Element] = [], current: Element? = element
            while let value = current {
                guard result.count < 128 else { throw Failure.tooManyResults }
                result.append(value)
                if value === root { return result }
                current = value.parent()
            }
            throw Failure.ambiguousStructure
        }
        var nameCounts: [ObjectIdentifier: Int] = [:]
        var linksByContainer: [ObjectIdentifier: [Element]] = [:]
        var chains: [[Element]] = []
        for name in nameNodes {
            let ancestors = try chain(name); chains.append(ancestors)
            for parent in ancestors { nameCounts[ObjectIdentifier(parent), default: 0] += 1 }
        }
        for link in linkNodes {
            for parent in try chain(link) {
                // Two candidates are sufficient to mark ambiguity; do not grow quadratic lists.
                let key = ObjectIdentifier(parent)
                if linksByContainer[key, default: []].count < 2 { linksByContainer[key, default: []].append(link) }
            }
        }
        var used = Set<ObjectIdentifier>()
        return try zip(nameNodes, chains).map { name, ancestors in
            for parent in ancestors {
                let tag = parent.tagName().lowercased()
                guard tag != "#root", tag != "html", tag != "body" else { continue }
                let key = ObjectIdentifier(parent)
                if nameCounts[key] == 1, let candidates = linksByContainer[key], candidates.count == 1 {
                    let link = candidates[0]
                    guard used.insert(ObjectIdentifier(link)).inserted else { throw Failure.ambiguousStructure }
                    return (name: name, link: link)
                }
            }
            throw Failure.ambiguousStructure
        }
    }
}

/// A JSONPath subset that names exactly one array and fields within each row.
/// No filtering, recursion, indices, expression evaluation or cross-array zipping.
public enum SearchJSONPath {
    public struct Projection: Equatable, Sendable {
        public let rowsPath: String
        public let valuePaths: [String]
    }
    public enum Failure: Error { case unsupported }

    public static func compile(_ path: String) throws -> Projection {
        guard path.utf8.count <= 1024, path.hasPrefix("$"),
              path.components(separatedBy: "[*]").count == 2 else { throw Failure.unsupported }
        let sections = path.dropFirst().components(separatedBy: "[*]")
        func components(_ raw: String, unions: Bool) throws -> [[String]] {
            var remaining = raw[...], result: [[String]] = []
            func key(_ raw: Substring) -> Bool {
                !raw.isEmpty && raw.utf8.count <= 128 && raw.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
            }
            while !remaining.isEmpty {
                guard result.count < 16 else { throw Failure.unsupported }
                if remaining.first == "." {
                    remaining = remaining.dropFirst()
                    let end = remaining.firstIndex(where: { $0 == "." || $0 == "[" }) ?? remaining.endIndex
                    let value = remaining[..<end]
                    guard key(value) else { throw Failure.unsupported }
                    result.append([String(value)]); remaining = remaining[end...]
                } else if remaining.first == "[", let end = remaining.firstIndex(of: "]") {
                    let content = remaining[remaining.index(after: remaining.startIndex)..<end]
                    let values = content.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                    guard !values.isEmpty, values.count <= (unions ? 8 : 1) else { throw Failure.unsupported }
                    let keys = try values.map { value -> String in
                        guard value.count >= 3, let quote = value.first, quote == "'" || quote == "\"",
                              value.last == quote, key(value.dropFirst().dropLast()) else { throw Failure.unsupported }
                        return String(value.dropFirst().dropLast())
                    }
                    result.append(keys); remaining = remaining[remaining.index(after: end)...]
                    if keys.count > 1 && !remaining.isEmpty { throw Failure.unsupported }
                } else { throw Failure.unsupported }
            }
            return result
        }
        let rows = try components(sections[0], unions: false).map { $0[0] }
        let values = try components(sections[1], unions: true)
        guard let last = values.last else { throw Failure.unsupported }
        let prefix = values.dropLast().map { $0[0] }
        return Projection(rowsPath: rows.isEmpty ? "$" : rows.joined(separator: "."),
                          valuePaths: last.map { (prefix + [$0]).joined(separator: ".") })
    }
}
