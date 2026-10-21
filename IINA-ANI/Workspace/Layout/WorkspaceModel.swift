import Foundation

public struct WorkspaceComponentID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
}
public enum WorkspaceJSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: WorkspaceJSONValue])
    case array([WorkspaceJSONValue])
    case null
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let x = try? c.decode(Bool.self) {
            self = .bool(x)
        } else if let x = try? c.decode(Double.self) {
            self = .number(x)
        } else if let x = try? c.decode(String.self) {
            self = .string(x)
        } else if let x = try? c.decode([String: WorkspaceJSONValue].self) {
            self = .object(x)
        } else {
            self = .array(try c.decode([WorkspaceJSONValue].self))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let x): try c.encode(x)
        case .number(let x): try c.encode(x)
        case .bool(let x): try c.encode(x)
        case .object(let x): try c.encode(x)
        case .array(let x): try c.encode(x)
        case .null: try c.encodeNil()
        }
    }
}
public struct WorkspaceSize: Codable, Equatable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
    private enum Keys: String, CodingKey { case width, height }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try rejectUnknown(c, decoder: decoder)
        width = try c.decode(Double.self, forKey: .width)
        height = try c.decode(Double.self, forKey: .height)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(width, forKey: .width)
        try c.encode(height, forKey: .height)
    }
}
public struct WorkspaceBreakpoint: Codable, Hashable, Comparable, Sendable {
    public var minimumWidth: Double
    public init(minimumWidth: Double) { self.minimumWidth = minimumWidth }
    public static func < (a: Self, b: Self) -> Bool { a.minimumWidth < b.minimumWidth }
    private enum Keys: String, CodingKey { case minimumWidth }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try rejectUnknown(c, decoder: decoder)
        minimumWidth = try c.decode(Double.self, forKey: .minimumWidth)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(minimumWidth, forKey: .minimumWidth)
    }
}
private struct WorkspaceDynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
private func rejectUnknown<K: CodingKey>(_ c: KeyedDecodingContainer<K>, decoder: Decoder, allowed: Set<String>? = nil)
    throws
{
    let dynamic = try decoder.container(keyedBy: WorkspaceDynamicKey.self)
    let keys = allowed ?? Set(c.allKeys.map(\.stringValue))
    guard dynamic.allKeys.allSatisfy({ keys.contains($0.stringValue) }) else {
        throw DecodingError.dataCorrupted(
            .init(codingPath: decoder.codingPath, debugDescription: "Unknown or inapplicable workspace field"))
    }
}
public enum WorkspacePageMotionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case invalidValue(String), invalidXML, tooLarge, notLocalFile
    public var errorDescription: String? {
        switch self {
        case .invalidValue(let field): String(localized: "Invalid page motion \(field)")
        case .invalidXML: String(localized: "Invalid page motion XML; expected one version 1 pageMotion element with only motion attributes")
        case .tooLarge: String(localized: "Page motion XML exceeds the 16 KiB limit")
        case .notLocalFile: String(localized: "Page motion XML must be a regular local file")
        }
    }
    public var description: String {
        switch self {
        case .invalidValue(let field): "Invalid page motion \(field)"
        case .invalidXML: "Invalid page motion XML; expected one version 1 pageMotion element with only motion attributes"
        case .tooLarge: "Page motion XML exceeds the 16 KiB limit"
        case .notLocalFile: "Page motion XML must be a regular local file"
        }
    }
}
public struct WorkspacePageMotion: Codable, Equatable, Sendable {
    public enum Curve: String, Codable, CaseIterable, Sendable {
        case linear, easeIn, easeOut, easeInOut
    }
    public var duration: Double
    public var opacity: Double
    public var offsetX: Double
    public var offsetY: Double
    public var scale: Double
    public var curve: Curve
    public init(
        duration: Double = 0, opacity: Double = 1, offsetX: Double = 0, offsetY: Double = 0,
        scale: Double = 1, curve: Curve = .easeOut
    ) {
        self.duration = duration
        self.opacity = opacity
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.scale = scale
        self.curve = curve
    }
    public static let none = Self()
    public static let fade = Self(duration: 0.2, opacity: 0)
    public static let slide = Self(duration: 0.25, opacity: 0, offsetY: 16)
    public static let zoom = Self(duration: 0.25, opacity: 0, scale: 0.96)
    public static let presets: [(title: String, motion: Self)] = [
        (String(localized: "無"), .none), (String(localized: "淡入"), .fade),
        (String(localized: "滑入"), .slide), (String(localized: "縮放"), .zoom)
    ]
    public static let maximumXMLBytes = 16_384
    public func validate() throws {
        guard duration.isFinite, (0...5).contains(duration) else {
            throw WorkspacePageMotionError.invalidValue("duration")
        }
        guard opacity.isFinite, (0...1).contains(opacity) else {
            throw WorkspacePageMotionError.invalidValue("opacity")
        }
        guard offsetX.isFinite, (-2048...2048).contains(offsetX) else {
            throw WorkspacePageMotionError.invalidValue("offsetX")
        }
        guard offsetY.isFinite, (-2048...2048).contains(offsetY) else {
            throw WorkspacePageMotionError.invalidValue("offsetY")
        }
        guard scale.isFinite, (0.1...4).contains(scale) else {
            throw WorkspacePageMotionError.invalidValue("scale")
        }
    }
    private enum Keys: String, CodingKey { case duration, opacity, offsetX, offsetY, scale, curve }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try rejectUnknown(c, decoder: decoder)
        duration = try c.decode(Double.self, forKey: .duration)
        opacity = try c.decode(Double.self, forKey: .opacity)
        offsetX = try c.decode(Double.self, forKey: .offsetX)
        offsetY = try c.decode(Double.self, forKey: .offsetY)
        scale = try c.decode(Double.self, forKey: .scale)
        curve = try c.decode(Curve.self, forKey: .curve)
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: String(describing: error)))
        }
    }
    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(duration, forKey: .duration)
        try c.encode(opacity, forKey: .opacity)
        try c.encode(offsetX, forKey: .offsetX)
        try c.encode(offsetY, forKey: .offsetY)
        try c.encode(scale, forKey: .scale)
        try c.encode(curve, forKey: .curve)
    }
    public static func loadXML(from url: URL) throws -> Self {
        guard url.isFileURL, try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw WorkspacePageMotionError.notLocalFile
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximumXMLBytes + 1) ?? Data()
        return try decodeXML(data)
    }
    public static func decodeXML(_ data: Data) throws -> Self {
        guard data.count <= maximumXMLBytes else { throw WorkspacePageMotionError.tooLarge }
        // Only UTF-8 is supported. Reject declarations and references before invoking XMLParser,
        // so neither external resources nor internal entity expansion can ever be evaluated.
        guard let source = String(data: data, encoding: .utf8), !source.contains("<!"), !source.contains("&") else {
            throw WorkspacePageMotionError.invalidXML
        }
        let delegate = WorkspacePageMotionXMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, delegate.finished, let motion = delegate.motion else {
            throw WorkspacePageMotionError.invalidXML
        }
        try motion.validate()
        return motion
    }
}
private final class WorkspacePageMotionXMLDelegate: NSObject, XMLParserDelegate {
    var motion: WorkspacePageMotion?
    var finished = false
    var invalid = false
    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes: [String: String]
    ) {
        guard !invalid, motion == nil, !finished, elementName == "pageMotion", attributes.count == 7,
            attributes["version"] == "1",
            let durationText = attributes["duration"], let duration = Double(durationText),
            let opacityText = attributes["opacity"], let opacity = Double(opacityText),
            let offsetXText = attributes["offsetX"], let offsetX = Double(offsetXText),
            let offsetYText = attributes["offsetY"], let offsetY = Double(offsetYText),
            let scaleText = attributes["scale"], let scale = Double(scaleText),
            let curveText = attributes["curve"], let curve = WorkspacePageMotion.Curve(rawValue: curveText)
        else {
            reject(parser)
            return
        }
        motion = WorkspacePageMotion(
            duration: duration, opacity: opacity, offsetX: offsetX, offsetY: offsetY, scale: scale, curve: curve)
    }
    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard !invalid, motion != nil, !finished, elementName == "pageMotion" else {
            reject(parser)
            return
        }
        finished = true
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if !string.unicodeScalars.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }) {
            reject(parser)
        }
    }
    func parser(_ parser: XMLParser, foundProcessingInstructionWithTarget target: String, data: String?) {
        reject(parser)
    }
    private func reject(_ parser: XMLParser) {
        invalid = true
        parser.abortParsing()
    }
}
public struct WorkspacePage: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var title: String
    public var root: WorkspaceNode
    public var motion: WorkspacePageMotion
    /// Localize only unchanged built-in names; authored and renamed titles remain verbatim.
    public var displayTitle: String { displayTitle(bundle: .main) }
    func displayTitle(bundle: Bundle) -> String {
        switch (id, title) {
        case (WorkspacePageID.discover, "發現"): return String(localized: "發現", bundle: bundle)
        case (WorkspacePageID.search, "搜尋"): return String(localized: "搜尋", bundle: bundle)
        case (WorkspacePageID.favorites, "收藏"): return String(localized: "收藏", bundle: bundle)
        case (WorkspacePageID.downloads, "下載"): return String(localized: "下載", bundle: bundle)
        case (WorkspacePageID.detail, "詳情"): return String(localized: "詳情", bundle: bundle)
        case (WorkspacePageID.settings, "設定"): return String(localized: "設定", bundle: bundle)
        case (WorkspacePageID.torrent, "Torrent"): return String(localized: "Torrent", bundle: bundle)
        default: return title
        }
    }
    public init(id: UUID = UUID(), title: String, root: WorkspaceNode, motion: WorkspacePageMotion = .none) {
        self.id = id
        self.title = title
        self.root = root
        self.motion = motion
    }
    private enum Keys: String, CodingKey { case id, title, root, motion }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try rejectUnknown(c, decoder: decoder)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        root = try c.decode(WorkspaceNode.self, forKey: .root)
        if c.contains(.motion) {
            motion = try c.decode(WorkspacePageMotion.self, forKey: .motion)
        } else {
            motion = .none
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(root, forKey: .root)
        try c.encode(motion, forKey: .motion)
    }
}
public indirect enum WorkspaceNode: Codable, Equatable, Sendable {
    case empty(id: UUID)
    case grid(id: UUID, columns: [WorkspaceNode])
    case horizontalStack(id: UUID, children: [WorkspaceNode])
    case verticalStack(id: UUID, children: [WorkspaceNode])
    case split(id: UUID, first: WorkspaceNode, second: WorkspaceNode, ratio: Double)
    case group(id: UUID, children: [WorkspaceNode])
    case tabs(id: UUID, selectedPageID: UUID, pages: [WorkspacePage])
    case component(
        id: UUID, componentID: WorkspaceComponentID, contractVersion: Int, parameters: [String: WorkspaceJSONValue],
        size: WorkspaceSize)
    private enum Keys: String, CodingKey {
        case kind, id, columns, children, first, second, ratio, selectedPageID, pages, componentID, contractVersion,
            parameters, size
    }
    private enum Kind: String, Codable {
        case empty, grid, horizontalStack, verticalStack, split, group, tabs, component
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        let fields: Set<String>
        switch kind {
        case .empty: fields = ["kind", "id"]
        case .grid: fields = ["kind", "id", "columns"]
        case .horizontalStack, .verticalStack, .group: fields = ["kind", "id", "children"]
        case .split: fields = ["kind", "id", "first", "second", "ratio"]
        case .tabs: fields = ["kind", "id", "selectedPageID", "pages"]
        case .component: fields = ["kind", "id", "componentID", "contractVersion", "parameters", "size"]
        }
        try rejectUnknown(c, decoder: decoder, allowed: fields)
        let id = try c.decode(UUID.self, forKey: .id)
        switch kind {
        case .empty: self = .empty(id: id)
        case .grid: self = .grid(id: id, columns: try c.decode([WorkspaceNode].self, forKey: .columns))
        case .horizontalStack:
            self = .horizontalStack(id: id, children: try c.decode([WorkspaceNode].self, forKey: .children))
        case .verticalStack:
            self = .verticalStack(id: id, children: try c.decode([WorkspaceNode].self, forKey: .children))
        case .group: self = .group(id: id, children: try c.decode([WorkspaceNode].self, forKey: .children))
        case .split:
            self = .split(
                id: id, first: try c.decode(WorkspaceNode.self, forKey: .first),
                second: try c.decode(WorkspaceNode.self, forKey: .second),
                ratio: try c.decode(Double.self, forKey: .ratio))
        case .tabs:
            self = .tabs(
                id: id, selectedPageID: try c.decode(UUID.self, forKey: .selectedPageID),
                pages: try c.decode([WorkspacePage].self, forKey: .pages))
        case .component:
            self = .component(
                id: id, componentID: try c.decode(WorkspaceComponentID.self, forKey: .componentID),
                contractVersion: try c.decode(Int.self, forKey: .contractVersion),
                parameters: try c.decode([String: WorkspaceJSONValue].self, forKey: .parameters),
                size: try c.decode(WorkspaceSize.self, forKey: .size))
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .empty(let id):
            try c.encode(Kind.empty, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .grid(let id, let xs):
            try c.encode(Kind.grid, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(xs, forKey: .columns)
        case .horizontalStack(let id, let xs):
            try c.encode(Kind.horizontalStack, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(xs, forKey: .children)
        case .verticalStack(let id, let xs):
            try c.encode(Kind.verticalStack, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(xs, forKey: .children)
        case .group(let id, let xs):
            try c.encode(Kind.group, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(xs, forKey: .children)
        case .split(let id, let a, let b, let r):
            try c.encode(Kind.split, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(a, forKey: .first)
            try c.encode(b, forKey: .second)
            try c.encode(r, forKey: .ratio)
        case .tabs(let id, let selected, let pages):
            try c.encode(Kind.tabs, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(selected, forKey: .selectedPageID)
            try c.encode(pages, forKey: .pages)
        case .component(let id, let type, let version, let params, let size):
            try c.encode(Kind.component, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(type, forKey: .componentID)
            try c.encode(version, forKey: .contractVersion)
            try c.encode(params, forKey: .parameters)
            try c.encode(size, forKey: .size)
        }
    }
    public var id: UUID {
        switch self {
        case .empty(let id), .grid(let id, _), .horizontalStack(let id, _), .verticalStack(let id, _),
            .split(let id, _, _, _), .group(let id, _), .tabs(let id, _, _), .component(let id, _, _, _, _):
            return id
        }
    }
}
public struct WorkspaceLayout: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var pages: [WorkspacePage]
    public var breakpointLayouts: [WorkspaceBreakpoint: [WorkspacePage]]
    public var homePageID: UUID? = nil
    public var hiddenPageIDs: Set<UUID> = []
    public var collapsedInstanceIDs: Set<UUID> = []
    public init(
        schemaVersion: Int = currentSchemaVersion, pages: [WorkspacePage],
        breakpointLayouts: [WorkspaceBreakpoint: [WorkspacePage]] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.pages = pages
        self.breakpointLayouts = breakpointLayouts
    }
    private enum Keys: String, CodingKey {
        case schemaVersion, pages, breakpointLayouts, homePageID, hiddenPageIDs, collapsedInstanceIDs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        try rejectUnknown(c, decoder: decoder)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        pages = try c.decode([WorkspacePage].self, forKey: .pages)
        breakpointLayouts =
            try c.decodeIfPresent([WorkspaceBreakpoint: [WorkspacePage]].self, forKey: .breakpointLayouts) ?? [:]
        homePageID = try c.decodeIfPresent(UUID.self, forKey: .homePageID)
        hiddenPageIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .hiddenPageIDs) ?? []
        collapsedInstanceIDs = try c.decodeIfPresent(Set<UUID>.self, forKey: .collapsedInstanceIDs) ?? []
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(pages, forKey: .pages)
        // Non-string-key dictionaries and Sets otherwise encode in hash iteration order.
        // Keep schema 1's alternating key/value array, but give equal layouts stable bytes.
        var breakpoints = c.nestedUnkeyedContainer(forKey: .breakpointLayouts)
        for key in breakpointLayouts.keys.sorted() {
            try breakpoints.encode(key)
            try breakpoints.encode(breakpointLayouts[key]!)
        }
        try c.encodeIfPresent(homePageID, forKey: .homePageID)
        if !hiddenPageIDs.isEmpty {
            try c.encode(hiddenPageIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .hiddenPageIDs)
        }
        if !collapsedInstanceIDs.isEmpty {
            try c.encode(collapsedInstanceIDs.sorted { $0.uuidString < $1.uuidString }, forKey: .collapsedInstanceIDs)
        }
    }
}
public enum WorkspacePageID {
    public static let discover = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    public static let search = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    public static let favorites = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    public static let downloads = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    public static let detail = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
    public static let settings = UUID(uuidString: "00000000-0000-4000-8000-000000000006")!
    public static let torrent = UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
}
public enum WorkspaceBuiltinLayouts {
    public static func makeDefault() -> WorkspaceLayout {
        func panel(_ id: String, width: Double = 760, height: Double = 320) -> WorkspaceNode {
            .component(
                id: UUID(), componentID: WorkspaceComponentID(rawValue: id), contractVersion: 1, parameters: [:],
                size: WorkspaceSize(width: width, height: height))
        }
        let discover = WorkspacePage(
            id: WorkspacePageID.discover, title: "發現",
            root: .verticalStack(
                id: UUID(),
                children: [
                    panel("discovery.recommendations", height: 210),
                    panel("playback.continue", height: 164),
                    panel("discovery.feed", height: 640),
                ]))
        let search = WorkspacePage(id: WorkspacePageID.search, title: "搜尋", root: panel("search.results", height: 640))
        let favorites = WorkspacePage(
            id: WorkspacePageID.favorites, title: "收藏",
            root: .verticalStack(
                id: UUID(), children: [
                    panel("discovery.updates", height: 240),
                    .split(
                        id: UUID(), first: panel("favorites.works", width: 420, height: 480),
                        second: panel("favorites.links", width: 420, height: 480), ratio: 0.5),
                ]))
        let downloads = WorkspacePage(
            id: WorkspacePageID.downloads, title: "下載", root: panel("downloads.tasks", height: 640))
        let detail = WorkspacePage(id: WorkspacePageID.detail, title: "詳情", root: panel("detail.media", height: 680))
        let settings = WorkspacePage(id: WorkspacePageID.settings, title: "設定", root: panel("settings.preferences", height: 680))
        let torrent = WorkspacePage(id: WorkspacePageID.torrent, title: "Torrent", root: panel("torrent.import", height: 640))
        let pages = [discover, search, downloads, detail, torrent, settings, favorites]
        var layout = WorkspaceLayout(pages: pages, breakpointLayouts: [WorkspaceBreakpoint(minimumWidth: 960): pages])
        layout.hiddenPageIDs = [WorkspacePageID.detail, WorkspacePageID.torrent]
        return layout
    }
}
