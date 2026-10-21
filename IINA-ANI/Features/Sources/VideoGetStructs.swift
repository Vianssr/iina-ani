//
//  VideoGetStructs.swift
//  iina+
//
//  Created by xjbeta on 2018/11/1.
//  Copyright © 2018 xjbeta. All rights reserved.
//

import Cocoa
import Marshal
import UniformTypeIdentifiers

protocol LiveInfo: Sendable {
    var title: String { get }
    var name: String { get }
    var avatar: String { get }
    var cover: String { get }
    var isLiving: Bool { get }
    
    var site: SupportSites { get }
}

final class VideoTreeNode: Sendable, Hashable {
    let title: String
    let isLeaf: Bool
    let children: [VideoTreeNode]
    
    // Common leaf properties
    let site: SupportSites
    let index: Int
    let id: String
    let url: String
    let isLiving: Bool
    let coverUrl: URL?
    
    // Bilibili-specific
    let bvid: String
    let duration: Int
    let isCollection: Bool
    let longTitle: String

    var selectionURL: String {
        guard isLeaf else { return "" }
        switch site {
        case .bilibili:
            return "https://www.bilibili.com/video/\(bvid)" + (isCollection ? "" : "?p=\(index)")
        case .bangumi:
            return "https://www.bilibili.com/bangumi/play/ep\(id)"
        default:
            return url
        }
    }

    var displayTitle: String {
        switch site {
        case .bilibili:
            return isCollection ? title : "\(index)  \(title)"
        case .douyu, .huya, .biliLive, .cc163:
            return (isLiving ? "🔥" : "") + title
        default:
            return title + (longTitle.isEmpty ? "" : "  " + longTitle)
        }
    }

    
    init(site: SupportSites = .unsupported,
         index: Int = 0,
         title: String,
         id: String,
         url: String = "",
         isLiving: Bool = false,
         coverUrl: URL? = nil,
         bvid: String = "",
         duration: Int = 0,
         isCollection: Bool = false,
         longTitle: String = "") {
        self.title = title
        self.isLeaf = true
        self.children = []
        self.site = site
        self.index = index
        self.id = id
        self.url = url
        self.isLiving = isLiving
        self.coverUrl = coverUrl
        self.bvid = bvid
        self.duration = duration
        self.isCollection = isCollection
        self.longTitle = longTitle
    }
    
    init(title: String, children: [VideoTreeNode]) {
        self.title = title
        self.isLeaf = false
        self.children = children
        self.site = .unsupported
        self.index = 0
        self.id = ""
        self.url = ""
        self.isLiving = false
        self.coverUrl = nil
        self.bvid = ""
        self.duration = 0
        self.isCollection = false
        self.longTitle = ""
    }
    
    static func == (lhs: VideoTreeNode, rhs: VideoTreeNode) -> Bool {
        lhs === rhs
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self))
    }
}

extension [VideoTreeNode] {
    var flattened: [VideoTreeNode] {
        filter { !$0.isLeaf && !$0.children.filter(\.isLeaf).isEmpty }
    }
}

struct VideoSelectionCatalog: Sendable {
    let nodes: [VideoTreeNode]
    let current: Int
    let selection: PlayableSelection
}

/// Plans only within the immediate leaf group containing one exact durable page identity.
/// Catalog indices and episode labels are presentation, never fallback identities.
enum AutoplaySelection {
    private static func group(after selection: PlayableSelection, in nodes: [VideoTreeNode],
                              registry: SourceRegistry) -> (siblings: [VideoTreeNode], index: Int)? {
        let current = selection.episode ?? selection.item
        guard selection.torrent == nil, selection.item.sourceID != "torrent",
              current.sourceID == selection.item.sourceID,
              selection.classification.kind != .live, current.kind != .live,
              let identity = try? registry.item(for: current.pageURL),
              identity.sourceID == current.sourceID else { return nil }
        var match: ([VideoTreeNode], Int)?
        var matchCount = 0
        func visit(_ siblings: [VideoTreeNode]) {
            for (index, node) in siblings.enumerated() {
                if node.isLeaf {
                    if node.site.sourceID == current.sourceID,
                       let ref = try? registry.item(for: node.selectionURL), ref == identity {
                        match = (siblings, index)
                        matchCount += 1
                    }
                } else {
                    visit(node.children)
                }
            }
        }
        visit(nodes)
        return matchCount == 1 ? match : nil
    }

    static func completedItems(after selection: PlayableSelection, in nodes: [VideoTreeNode],
                               registry: SourceRegistry) -> [SourceItemRef]? {
        guard let (siblings, index) = group(after: selection, in: nodes, registry: registry),
              index == siblings.count - 1 else { return nil }
        var items: [SourceItemRef] = []
        var identities = Set<SourceItemRef>()
        for leaf in siblings {
            guard leaf.isLeaf, !leaf.isLiving, leaf.site.sourceID == selection.item.sourceID,
                  let item = try? registry.item(for: leaf.selectionURL),
                  item.sourceID == selection.item.sourceID, item.kind != .live, item.kind != .work,
                  identities.insert(item).inserted else { return nil }
            items.append(item)
        }
        return items
    }

    static func next(after selection: PlayableSelection, in nodes: [VideoTreeNode],
                     registry: SourceRegistry) -> PlayableSelection? {
        guard let (siblings, index) = group(after: selection, in: nodes, registry: registry),
              siblings.indices.contains(index + 1),
              let identity = try? registry.item(for: (selection.episode ?? selection.item).pageURL) else { return nil }
        let current = selection.episode ?? selection.item
        let leaf = siblings[index + 1]
        guard leaf.isLeaf, !leaf.isLiving, leaf.site.sourceID == current.sourceID,
              let next = try? registry.item(for: leaf.selectionURL),
              next.sourceID == current.sourceID, next != identity,
              next.kind != .live, next.kind != .work else { return nil }
        // An ambiguous repeated target must not create an autoplay loop.
        func count(_ nodes: [VideoTreeNode]) -> Int {
            nodes.reduce(0) { total, node in
                total + (node.isLeaf ? ((try? registry.item(for: node.selectionURL)) == next ? 1 : 0) : count(node.children))
            }
        }
        guard count(nodes) == 1 else { return nil }
        var result = selection
        if selection.episode != nil || selection.item.kind == .work { result.episode = next }
        else { result.item = next }
        return result
    }

    private static func localGroup(after selection: PlayableSelection) throws -> (files: [URL], index: Int, directory: URL)? {
        let current = selection.episode ?? selection.item
        guard selection.torrent == nil, selection.item.sourceID == "local",
              current.sourceID == "local", current.kind == .local,
              selection.classification.kind != .live, selection.accountID == nil,
              let file = URL(string: current.pageURL), file.isFileURL else { return nil }
        let directory = file.standardizedFileURL.deletingLastPathComponent()
        let videos = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
            .filter {
                guard TorrentSelection.isPlayablePath($0.path) ||
                        UTType(filenameExtension: $0.pathExtension)?.conforms(to: .movie) == true,
                      let values = try? $0.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return false }
                return values.isRegularFile == true && values.isSymbolicLink != true
            }.sorted {
                let order = $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                return order == .orderedSame ? $0.lastPathComponent < $1.lastPathComponent : order == .orderedAscending
            }
        // Directory enumeration canonicalizes /var to /private/var on macOS.
        // Compare exact sibling names, retaining the caller's directory URL identity.
        guard let index = videos.firstIndex(where: { $0.lastPathComponent == file.lastPathComponent }) else { return nil }
        return (videos, index, directory)
    }

    /// The whole sibling group, including episodes before the selected file.
    static func localQueue(for selection: PlayableSelection) throws -> [PlayableSelection] {
        guard let (videos, _, directory) = try localGroup(after: selection) else { return [] }
        return videos.map { video in
            var item = selection
            item.item = SourceItemRef(sourceID: "local",
                pageURL: directory.appendingPathComponent(video.lastPathComponent).absoluteString, kind: .local)
            item.episode = nil
            return item
        }
    }

    static func localCompletedItems(after selection: PlayableSelection) throws -> [SourceItemRef]? {
        guard let (videos, index, directory) = try localGroup(after: selection),
              index == videos.count - 1 else { return nil }
        return videos.map {
            SourceItemRef(sourceID: "local", pageURL: directory.appendingPathComponent($0.lastPathComponent).absoluteString, kind: .local)
        }
    }

    static func localNext(after selection: PlayableSelection) throws -> PlayableSelection? {
        guard let (videos, index, directory) = try localGroup(after: selection),
              videos.indices.contains(index + 1) else { return nil }
        var result = selection
        let next = directory.appendingPathComponent(videos[index + 1].lastPathComponent)
        result.item = SourceItemRef(sourceID: "local", pageURL: next.absoluteString, kind: .local)
        result.episode = nil
        return result
    }

    static func localDanmakuURL(for selection: PlayableSelection) -> URL? {
        let ref = selection.episode ?? selection.item
        guard ref.sourceID == "local", ref.kind == .local,
              let file = URL(string: ref.pageURL), file.isFileURL else { return nil }
        let xml = file.deletingPathExtension().appendingPathExtension("xml")
        guard let values = try? xml.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return xml
    }
}

enum VideoInspection: Sendable {
    case selection(VideoSelectionCatalog)
    case playable(YouGetJSON)
}

struct BilibiliInfo: Unmarshaling, LiveInfo {
    var title: String = ""
    var name: String = ""
    var avatar: String = ""
    var isLiving = false
    var cover: String = ""
    
    var site: SupportSites = .bilibili
    
    init() {
    }
    
    init(object: MarshaledObject) throws {
        title = try object.value(for: "title")
        name = try object.value(for: "info.uname")
        avatar = try object.value(for: "info.face")
        isLiving = "\(try object.any(for: "live_status"))" == "1"
    }
}
